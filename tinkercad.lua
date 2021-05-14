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

local user_suffixes = {} -- Append these to the user ID (item value) to get one form of URL. May be empty.
local user_last_activity_time = {} -- Timestamps of last user activity. user IDs -> timestamps

io.stdout:setvbuf("no") -- So prints are not buffered - http://lua.2524044.n2.nabble.com/print-stdout-and-flush-td6406981.html

do_debug = true
print_debug = function(a)
  if do_debug then
    print(a)
  end
end
print_debug("This grab script is running in debug mode. You should not see this in production.")

set_new_item = function(url)
  -- 3 stages to my version of this:
  -- - url_sources (shows whence URLs were derived)
  -- - Explicit set based on URL
  -- - Else nil (i.e. unknown or do not care)

  print_debug("Trying to set item on " .. url)

  -- Previous
  if url_sources[url] ~= nil then
    current_item_type = url_sources[url]["type"]
    current_item_value = url_sources[url]["value"]
    print_debug("Setting current item to " .. current_item_type .. ":" .. current_item_value .. " based on sources table")
    return
  end

  if url_sources[urlparse.unescape(url)] ~= nil then
    current_item_type = url_sources[urlparse.unescape(url)]["type"]
    current_item_value = url_sources[urlparse.unescape(url)]["value"]
    print_debug("Used unescaped form to set item")
    print_debug("Setting current item to " .. current_item_type .. ":" .. current_item_value .. " based on sources table")
    return
  end

  -- Explicitly setting
  local user = string.match(url, "^https?://www%.tinkercad%.com/users/([^/%?#%-]+)$")
  if user == nil then
    user = string.match(url, "^https?://api%-reader%.tinkercad%.com/users/([^/%?#%-]+)$")
  end
  if user ~= nil then
    current_item_type = "user"
    current_item_value = user
    print_debug("Setting current item to user:" .. user .. " based on URL inference")
    return
  end

  -- Else
  print_debug("Current item fell through")
  current_item_value = nil
  current_item_type = nil
  assert(false, "This should not happen")
end

set_derived_url = function(dest)
  if url_sources[dest] == nil then
    --print_debug("Derived " .. dest)
    url_sources[dest] = {type=current_item_type, value=current_item_value}
    if urlparse.unescape(dest) ~= dest then
      set_derived_url(urlparse.unescape(dest))
    end
    -- Wget adds a "/" to the end of param- and fragment-less paths that don't already have one
    local withsl = string.match(dest, '^([^%?#]+[^/])$')
    if withsl ~= nil and withsl .. "/" ~= dest then
      set_derived_url(withsl .. "/")
    end
  else
    if url_sources[dest]["type"] ~= current_item_type
      or url_sources[dest]["value"] ~= current_item_value then
      print(current_item_type .. ":" .. current_item_value .. " wants " .. dest)
      print("but it is already claimed by " .. url_sources[dest]["type"] .. ":" .. url_sources[dest]["value"])
      assert(false)
    end
  end
end

discover_item = function(item_type, item_name)
  assert(item_type)
  assert(item_name)
  discovered_items[item_type .. ":" .. item_name] = true
end


if urlparse == nil or http == nil then
  io.stdout:write("socket not corrently installed.\n")
  io.stdout:flush()
  abortgrab = true
end

add_ignore = function(url)
  if url == nil then -- For recursion
    return
  end
  if downloaded[url] ~= true then
    downloaded[url] = true
  else
    return
  end
  add_ignore(string.gsub(url, '^https', 'http', 1))
  add_ignore(string.gsub(url, '^http:', 'https:', 1))
  local nosl = string.match(url, '^([^%?#]+[^/])$')
  if nosl then
    add_ignore(nosl .. '/')
  end
  add_ignore(string.match(url, '^(.+)/$'))
end

for ignore in io.open("ignore-list", "r"):lines() do
  add_ignore(ignore)
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


allowed = function(url, parenturl)
  assert(parenturl ~= nil)

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

  -- 3rd party sites, unnecess
  if string.match(url, '^https?://cdn%.jsdelivr%.net/')
    or string.match(url, '^https?://[^/]%.twitter%.com/')
    or string.match(url, '^https?://[^/]%.facebook%.net/')
    or string.match(url, '^https?://[^/]%.pinterest%.com/')
    or string.match(url, '^https?://[^/]%.launchdarkly%.com/')then
    return false
  end

  -- Static
  if string.match(url, '^https?://www%.tinkercad%.com/js/')
    or string.match(url, '^https?://editor%.tinkercad%.com/assets_[a-z0-9]+/') -- TODO queue these to backfeed? Change frequently
    or string.match(url, '^https?://editor%.tinkercad%.com/assets_[a-z0-9]+$') then
    return false
  end

  -- Etc
  if string.match(url, '^https?://accounts%.autodesk%.com/') then
    return false
  end

  --print_debug("Allowed true on " .. url)
  return true -- DEBUG

  --assert(false, "This segment should not be reachable")
end


wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  print_debug("DCP on " .. url)
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

  local function absolute(url, newurl)
    if string.match(url, "^https?://api%-reader%.tinkercad%.com/users/([^/%?#%-]+)$") then
      return urlparse.absolute(url, "/api" .. newurl)
    else
      return urlparse.absolute(url, newurl)
    end
  end

  local function check(urla, force)
    assert((not force) or (force == true)) -- Don't accidentally put something else for force
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
      check(absolute(url, newurl))
    elseif string.match(newurl, "^/") then
      check(absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if string.match(newurl, "^%?") then
      check(absolute(url, newurl))
    elseif not (string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^%${")) then
      check(absolute(url, "/" .. newurl))
    end
  end

  local function load_html()
    if html == nil then
      html = read_file(file)
    end
  end

  local function get_slug_version(name)
    name = string.gsub(name, ' ','-')
    name = string.gsub(name, '[^%w%-]','')
    local prev = nil
    while prev ~= name do
      prev = name
      name = string.gsub(name, '%-%-','-')
    end
    name = string.sub(name, 1, 64)
    name = string.lower(name)
    return name
  end

  if (current_item_type == "user") and string.match(url, "https?://www%.tinkercad%.com/users/" .. current_item_value) and (status_code == 200) then
    check("https://www.tinkercad.com/users/" .. current_item_value .. "?category=tinkercad&sort=likes&view_mode=default", true)
    check("https://api-reader.tinkercad.com/users/" .. current_item_value)
  end

  if (current_item_type == "user") and string.match(url, "^https?://api%-reader%.tinkercad%.com/users/([^/%?#%-]+)$") and status_code == 200 then
    load_html()
    local json = JSON:decode(html)
    if json["screen_name"] ~= nil then
      local filtered_name = get_slug_version(json["screen_name"])
      assert(filtered_name)
      user_suffixes[current_item_value] = "-" .. filtered_name
    else
      user_suffixes[current_item_value] = ""
    end
    check("https://www.tinkercad.com/users/" .. current_item_value ..user_suffixes[current_item_value], true)

    assert(json["mtime"])
    user_last_activity_time[current_item_value] = tonumber(json["mtime"])
  end

  if (current_item_type == "user")
     and string.match(url, "https?://www%.tinkercad%.com/users/" .. current_item_value .. "%?category=")
     and (status_code == 200) then
    local base = "https://www.tinkercad.com/users/" .. current_item_value
    assert(user_suffixes[current_item_value])
    local extended = base .. user_suffixes[current_item_value]
    local duel = function(suffix)
      check(base .. suffix, true)
      check(extended .. suffix, true)
    end

    for _, type in pairs({"tinkercad", "circuits", "codeblocks"}) do
      for _, sort in pairs({"likes", "popular", "latest"}) do
        local suffix = "?category=" .. type .. "&sort=" .. sort .. "&view_mode=default"
        check(base .. suffix, true)
        check(extended .. suffix, true)
        sort = ({latest="newest", popular="hot", likes="likes"})[sort] -- Different names in the API vs. the human URL
        local endpoint = ({tinkercad="designs", circuits="designs", codeblocks="blocks"})[type]
        check("https://api-reader.tinkercad.com/api/search/" .. endpoint .. "?offset=0&limit=24&type=" .. type .. "&sort=" .. sort .. "&userid=" .. current_item_value)
      end
    end
  end

  -- Queue next pages of the list XHR for user submissions list, if they exist
  if (current_item_type == "user")
    and string.match(url, "^https?://api%-reader%.tinkercad%.com/api/search/")
    and status_code == 200 then
    load_html()
    local json = JSON:decode(html)

    -- Queue a next page if necessary
    print_debug("Have recognized")
    print_debug(json["limit"])
    print_debug(json["offset"])
    print_debug(json["totalCount"])
    if json["limit"] + json["offset"] < json["totalCount"] then
      print_debug("Am queuing more")
      check((string.gsub(url, "offset=" .. tostring(json["offset"]), "offset=" .. tostring(json["offset"] + json["limit"]))))
    end

    -- Discover items
    local list = json["designs"]
    if list == nil then
      list = json["blocks"]
    end
    if list ~= nil then
      assert(user_last_activity_time[current_item_value])
      for _, design in pairs(list) do
        -- If later than (a date slightly before) January 1, 2000 (the cutoff), queue as low-priority
        -- Nanoseconds
        if user_last_activity_time[current_item_value] > 1577000000000000000 then
          discover_item("submission-lp", design["id"])
        else
          discover_item("submission", design["id"])
        end
        -- Extra images that may or may not exist
        if (design["default_image_id"] ~= "-1") then
          check("https://api-reader.tinkercad.com/api/images/" .. design["default_image_id"] .. "/t300.jpg")
          check("https://api-reader.tinkercad.com/api/images/" .. design["default_image_id"] .. "/t75.jpg")
          check("https://api-reader.tinkercad.com/api/images/" .. design["default_image_id"] .. "/t725.jpg")
          check("https://api-reader.tinkercad.com/api/images/" .. design["profile_image_id"] .. "/t40.jpg?t=0")
        end
      end
    end
  end





  

  if status_code == 200 and not (string.match(url, "jpe?g$") or string.match(url, "png$"))
    and not (string.match(url, "^https?://csg%.tinkercad%.com/")) then
    load_html()
    print_debug("Len of html is " .. tostring(#html))
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
    print("Server returned " .. http_stat.statcode .. " (" .. err .. "). Sleeping.\n")
    do_retry = true
  end

  url_is_essential = true
  maxtries = 12


  if do_retry then
    if tries >= maxtries then
      print("I give up...\n")
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
    local to_send = nil
    for item, _ in pairs(discovered_items) do
      assert(string.match(item, ":")) -- Message from EggplantN, #binnedtray (search "colon"?)
      if to_send == nil then
        to_send = item
      else
        to_send = to_send .. "\0" .. item
      end
      print("Queued " .. item)
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
  return true
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if abortgrab == true then
    return wget.exits.IO_FAIL
  end
  return exit_status
end

