dofile("table_show.lua")
dofile("urlcode.lua")
dofile("strict.lua")
local urlparse = require("socket.url")
local luasocket = require("socket") -- Used to get sub-second time
local http = require("socket.http")
JSON = assert(loadfile "JSON.lua")()

local item_name_newline = os.getenv("item_name_newline")
local item_dir = os.getenv('item_dir')
local warc_file_base = os.getenv('warc_file_base')

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false


discovered_items = {}
local last_main_site_time = 0
local url_sources = {}
local current_item_type = nil
local current_item_value = nil

set_new_item = function(url)
  -- 3 stages to my version of this:
  -- - url_sources (shows whence URLs were derived)
  -- - Explicit set based on URL
  -- - Else nil (i.e. unknown or do not care)

  -- Previous
  if url_sources[url] ~= nil then
    current_item_type = url_sources[url]["type"]
    current_item_value = url_sources[url]["value"]
    print_debug("Setting current item to " .. current_item_type .. ":" .. current_item_value .. " based on sources table")
    return
  end

  -- Explicitly setting
  local user = string.match(url, "^https?://bintray%.com/([^/%?#]+)")
  if user ~= nil and user ~= "user" then -- There is a pseudo-user called user, which owns repos, but is also used
    -- as a path component of UI endpoints.
    current_item_type = "user"
    current_item_value = user
    print_debug("Setting current item to user:" .. user .. " based on URL inference")
    return
  end

  -- Else
  print_debug("Current item fell through")
  current_item_value = nil
  current_item_type = nil
end

set_derived_url = function(dest)
  if url_sources[dest] == nil then
    print_debug("Derived " .. dest)
    url_sources[dest] = {type=current_item_type, value=current_item_value}
  else
    if url_sources[dest]["type"] ~= current_item_type
      or url_sources[dest]["value"] ~= current_item_value then
      print(current_item_type .. ":" .. current_item_value .. " wants " .. dest)
      print("but it is already claimed by " .. url_sources[dest]["type"] .. ":" .. url_sources[dest]["value"])
      assert(false)
    end
  end
end


if urlparse == nil or http == nil then
  io.stdout:write("socket not corrently installed.\n")
  io.stdout:flush()
  abortgrab = true
end

for ignore in io.open("ignore-list", "r"):lines() do
  downloaded[ignore] = true
  if string.match(ignore, '^https:') then
    downloaded[string.gsub(ignore, '^https', 'http', 1)] = true
  elseif string.match(ignore, '^http:') then
    downloaded[string.gsub(ignore, '^http:', 'https:', 1)] = true
  end
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

io.stdout:setvbuf("no") -- So prints are not buffered - http://lua.2524044.n2.nabble.com/print-stdout-and-flush-td6406981.html

p_assert = function(v)
  if not v then
    print("Assertion failed - aborting item")
    print(debug.traceback())
    abortgrab = true
  end
end

do_debug = true
print_debug = function(a)
    if do_debug then
        print(a)
    end
end
print_debug("This grab script is running in debug mode. You should not see this in production.")


allowed = function(url, parenturl)
  assert(parenturl ~= nil)

  -- For speed/my sanity during testing, don't get alternative sorted orders
  if string.match(url, "^https?://[^/]*%.?bintray%.com/.+order=asc&")
    or string.match(url, "^https?://[^/]*%.?bintray%.com/.+order=desc&") then
    --print_debug("Rejected sorted index " .. url)
    return false
  end

  -- Reject colon URLs on dl.
  if string.match(url, "^https?://dl%.bintray%.com/.+/%:[^/]+/?$") then
    --print_debug("Rejecting for colon " .. url)
    return false
  end

  -- Other
  if string.match(url, "^https?://[^/]*%.?bintray%.com/.*/reportLicense") -- Redirects to login
    or string.match(url, "^https?://[^/]*%.?bintray%.com/.*/edit") -- Redirects to login
    or string.match(url, "^https?://[^/]*%.?bintray%.com/.*/%?versionPath=") -- TODO remove for production? Seems harmless besides taking time
    or string.match(url, "^https?://[^/]*%.?bintray%.com/login%?")
  then
    --print_debug("Rejected for other " .. url)
    return false
  end



  if (string.match(url, "^https?://[^/]+%.bintray%.com/") or string.match(url, "^https?://bintray%.com/"))
          and current_item_type == "user" then
    --print_debug("User path match on " .. url)
    -- Experimental: More lenient (i.e. arkiver-style) URL-matching; leave rest in for discovery
    for test in string.gmatch(url, "[^/]+") do
      if test == current_item_value then
        --print_debug("Lenient true " .. url)
        return true
      end
    end

    local user = string.match(url, "^https?://bintray%.com/([^/%?#]+)")
    if user == nil then
      user = string.match(url, "^https?://bintray%.com/package/[^/]+/([^/%?#]+)")
    end
    if user == nil then
      user = string.match(url, "^https?://[^/]+%.bintray%.com/([^/%?#]+)") -- will also catch dl.
    end
    if user == nil then
      user = string.match(url, "^https?://[^/]+%.bintray%.com/package/[^/]+/([^/%?#]+)")
    end

    if user == current_item_value then
      --print_debug("Strict CIV match " .. url)
      return true
    else
      if user ~= nil and string.match(user, "^[a-zA-Z0-9%-_]+$")
              and user ~= "assets" and user ~= "payment" and user ~= "login"
              and user ~= "signup" and user ~= "package" and user ~= "docs"
              and user ~= "account" and user ~= "search" and user ~= "bintray-views" and user ~= "repo" then
        local item = "user:" .. user
        if discovered_items[item] == nil then
          print_debug("Add " .. item .. " for discovery")
          discovered_items[item] = true
        end
      end
      --print_debug("Strict CIV mismatch " .. url)
      return false
    end
  end

  -- TODO to prevent user:account, make sure general comes before backfeed intake

  local tested = {}
  for s in string.gmatch(url, "([^/]+)") do
    if tested[s] == nil then
      tested[s] = 0
    end
    if tested[s] == 6 then
      return false
    end
    tested[s] = tested[s] + 1
  end

    if string.match(url, "^https?://[^/]+%.bintray%.com/")
            or string.match(url, "^https?://bintray%.com/")
            or string.match(url, "https?://secure%.gravatar%.com/avatar/")
            or string.match(url, "https?://bintray[^/]+%.amazonaws%.com/") then
      return true
    else
      return false
    end
  --[[
    if current_item_type == "user" then
      return string.match(url, "^https?://bintray%.com/([^/]+)") == current_item_value
    elseif current_item_type == nil then
      return false
    else
      assert(false, "Bad item type in match(???)")
    end
  end]]

  assert(false, "This segment should not be reachable")
end


wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  if downloaded[url] == true or addedtolist[url] == true then
    return false
  end
  if allowed(url, parent["url"]) then
    addedtolist[url] = true
    set_derived_url(url)
    return true
  end

  return false
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil

  downloaded[url] = true

  local function check(urla, force)
    p_assert((not force) or (force == true)) -- Don't accidentally put something else for force
    local origurl = url
    local url = string.match(urla, "^([^#]+)")
    local url_ = string.match(url, "^(.-)%.?$")
    url_ = string.gsub(url_, "&amp;", "&")
    url_ = string.match(url_, "^(.-)%s*$")
    url_ = string.match(url_, "^(.-)%??$")
    url_ = string.match(url_, "^(.-)&?$")
    -- url_ = string.match(url_, "^(.-)/?$") # Breaks dl.
    if (downloaded[url_] ~= true and addedtolist[url_] ~= true)
      and (allowed(url_, origurl) or force) then
      table.insert(urls, { url=url_ })
      set_derived_url(url_)
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    -- Being caused to fail by a recursive call on "../"
    if not newurl then
      return
    end
    if string.match(newurl, "\\[uU]002[fF]") then
      return checknewurl(string.gsub(newurl, "\\[uU]002[fF]", "/"))
    end
    if string.match(newurl, "^https?:////") then
      check((string.gsub(newurl, ":////", "://")))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check((string.gsub(newurl, "\\", "")))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^%${")) then
      check(urlparse.absolute(url, "/" .. newurl))
    end
  end

  html = nil
  local function load_html()
    if html == nil then
      html = read_file(file)
    end
  end

  -- Extract nothing from the files themselves on the download site
  if current_item_type == "user" and string.match(url, "^https?://dl%.bintray%.com/.*[^/]$") then
    return {}
  end


  if current_item_type == "user" then
    check("https://bintray.com/user/subjectNotificationsJson?username=" .. current_item_value, true)
    check("https://bintray.com/" .. current_item_value .. "/repositoriesTemplate", true)
    check("https://bintray.com/" .. current_item_value .. "/repositoriesTemplate?iterator=true", true)

    if string.match(url, "^https?://dl%.bintray%.com/.*/$") then
      load_html()
      -- Queue URLs without :
      print_debug("Queueing dl urls")
      for newurl in string.gmatch(html, 'href=":?([^:"][^"]+)"') do
        newurl = urlparse.absolute(url, newurl)
        print_debug("Newurl is " .. newurl)
        check(newurl)
        print_debug("Queue " .. newurl)
      end
    end
  end
  

  if status_code == 200 and not (string.match(url, "jpe?g$") or string.match(url, "png$")) then
    load_html()
    for newurl in string.gmatch(string.gsub(html, "&quot;", '"'), '([^"]+)') do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      checknewurl(newurl)
    end
  end

  return urls
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]

  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. "  \n")
  io.stdout:flush()


  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if string.match(newloc, "https?://[a-z0-9]+%.cloudfront%.net") then -- TODO file should pass
      discovered_items["file:" .. url["url"]] = true
      return wget.actions.EXIT
    end
    if downloaded[newloc] == true or addedtolist[newloc] == true
            or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    else
      set_derived_url(newloc)
    end
  end

  if status_code >= 200 and status_code <= 399 then
    downloaded[url["url"]] = true
  end

  if abortgrab == true then
    io.stdout:write("ABORTING...\n")
    io.stdout:flush()
    return wget.actions.ABORT
  end

  --

  
  local do_retry = false
  local maxtries = 12
  local url_is_essential = false

  -- Whitelist instead of blacklist status codes
  if status_code ~= 200 and status_code ~= 404 and not (status_code >= 300 and status_code <= 399) then
    io.stdout:write("Server returned " .. http_stat.statcode .. " (" .. err .. "). Sleeping.\n")
    io.stdout:flush()
    do_retry = true
  end

  url_is_essential = true
  maxtries = 12


  if do_retry then
    if tries >= maxtries then
      io.stdout:write("I give up...\n")
      io.stdout:flush()
      tries = 0
      if not url_is_essential then
        return wget.actions.EXIT
      else
        print("Failed on an essential URL, aborting...")
        return wget.actions.ABORT
      end
    else
      sleep_time = math.floor(math.pow(2, tries))
      tries = tries + 1
    end
  end


  if do_retry and sleep_time > 0.001 then
    print("Sleeping " .. sleep_time .. "s")
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  end

  tries = 0
  return wget.actions.NOTHING
end


wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  if do_debug then
    for item, _ in pairs(discovered_items) do
      print("Would have sent discovered item " .. item)
    end
  else
    to_send = nil
    for item, _ in pairs(discovered_items) do
      if to_send == nil then
        to_send = url
      else
        to_send = to_send .. "\0" .. item
      end
    end

    if to_send ~= nil then
      local tries = 0
      while tries < 10 do
        local body, code, headers, status = http.request(
          --"http://blackbird.arpa.li:23038/whatever/" -- New address - #noanswers 2021-04-20Z
                "http://example.com",
          to_send
        )
        if code == 200 or code == 409 then
          break
        end
        os.execute("sleep " .. math.floor(math.pow(2, tries)))
        tries = tries + 1
      end
      if tries == 10 then
        abortgrab = true
      end
    end
  end
end

wget.callbacks.write_to_warc = function(url, http_stat)
  set_new_item(url["url"])
  if string.match(url["url"], "^https?://dl%.bintray%.com/.*[^/]$")
    and http_stat["statcode"] >= 300 and http_stat["statcode"] <= 399
    and string.match(http_stat["newloc"], "https?://[a-z0-9]+%.cloudfront%.net") then
    print_debug("Not writing to warc")
    return false
  end
  return true
  end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if abortgrab == true then
    return wget.exits.IO_FAIL
  end
  return exit_status
end

