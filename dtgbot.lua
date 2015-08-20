-- ~/tg/scripts/generic/domoticz2telegram.lua
-- Version 0.2 150816
-- Automation bot framework for telegram to control Domoticz
-- domoticz2telegram.lua does not require any customisation (see below)
-- and does not require any telegram client to be installed
-- all communication is via authenticated https
-- Extra functions can be added by replicating list.lua,
-- replacing list with the name of your new command see list.lua
-- Based on test.lua from telegram-cli from
-- Adapted to abstract functions into external files using
-- the framework of the XMPP bot, so allowing functions to
-- shared between the two bots.
-- -------------------------------------------------------

function print_to_log(logmessage,lm2,lm3,lm4,lm5,lm6,lm7,lm8,lm9)
  logmessage=tostring(logmessage)..' 2: '..tostring(lm2)..' 3: '..tostring(lm3)..' 4: '..tostring(lm4)..' 5: '..tostring(lm5)..' 6: '..tostring(lm6)..' 7: '..tostring(lm7)..' 8: '..tostring(lm8)..' 9: '..tostring(lm9)
  logmessage=tostring(logmessage):gsub(" .: nil","")
  print(os.date("%Y-%m-%d %H:%M:%S")..' - '..logmessage)
end

print_to_log ("-----------------------------------------")
print_to_log ("Starting Telegram api Bot message handler")
print_to_log ("-----------------------------------------")

function domoticzdata(envvar)
  -- loads get environment variable and prints in log
  localvar = os.getenv(envvar)
  if localvar ~= nil then
    print_to_log(envvar..": "..localvar)
  else
    print_to_log(envvar.." not found check /etc/profile.d/DomoticzData.sh")
  end
  return localvar
end

function checkpath(envpath)
  if string.sub(envpath,-2,-1) ~= "/" then
    envpath = envpath .. "/"
  end
  return envpath
end

-- All these values are set in /etc/profile.d/DomoticzData.sh
DomoticzIP = domoticzdata("DomoticzIP")
DomoticzPort = domoticzdata("DomoticzPort")
BotHomePath = domoticzdata("BotHomePath")
BotLuaScriptPath = domoticzdata("BotLuaScriptPath")
BotBashScriptPath = domoticzdata("BotBashScriptPath")
TelegramBotToken = domoticzdata("TelegramBotToken")
TBOName = domoticzdata("TelegramBotOffset")
-- -------------------------------------------------------

-- Constants derived from environment variables
server_url = "http://"..DomoticzIP..":"..DomoticzPort
telegram_url = "https://api.telegram.org/bot"..TelegramBotToken.."/"
UserScriptPath = BotBashScriptPath

-- Check paths end in / and add if not present
BotHomePath=checkpath(BotHomePath)
BotLuaScriptPath=checkpath(BotLuaScriptPath)
BotBashScriptPath=checkpath(BotBashScriptPath)

-- Array to store device list rapid access via index number
StoredType = "None"
StoredList = {}

-- Table to store functions for commands plus descriptions used by help function
commands = {};

-- Load necessary Lua libraries
http = require "socket.http";
socket = require "socket";
https = require "ssl.https";
JSON = require "JSON";

-- Load the configuration file this file contains the list of commands
-- used to define the external files with the command function to load.
local config = assert(loadfile(BotHomePath.."dtgbot.cfg"))();

--Not quite sure what this is here for
started = 1

function ok_cb(extra, success, result)
end

function vardump(value, depth, key)
  local linePrefix = ""
  local spaces = ""

  if key ~= nil then
    linePrefix = "["..key.."] = "
  end

  if depth == nil then
    depth = 0
  else
    depth = depth + 1
    for i=1, depth do spaces = spaces .. "  " end
  end

  if type(value) == 'table' then
    mTable = getmetatable(value)
    if mTable == nil then
      print_to_log(spaces ..linePrefix.."(table) ")
    else
      print_to_log(spaces .."(metatable) ")
      value = mTable
    end
    for tableKey, tableValue in pairs(value) do
      vardump(tableValue, depth, tableKey)
    end
  elseif type(value)	== 'function' or
  type(value)	== 'thread' or
  type(value)	== 'userdata' or
  value		== nil
  then
    print_to_log(spaces..tostring(value))
  else
    print_to_log(spaces..linePrefix.."("..type(value)..") "..tostring(value))
  end
end

-- Original XMPP function to list device properties
function list_device_attr(dev, mode)
  local result = "";
  local exclude_flag;
  -- Don't dump these fields as they are boring. Name data and idx appear anyway to exclude them
  local exclude_fields = {"Name", "Data", "idx", "SignalLevel", "CustomImage", "Favorite", "HardwareID", "HardwareName", "HaveDimmer", "HaveGroupCmd", "HaveTimeout", "Image", "IsSubDevice", "Notifications", "PlanID", "Protected", "ShowNotifications", "StrParam1", "StrParam2", "SubType", "SwitchType", "SwitchTypeVal", "Timers", "TypeImg", "Unit", "Used", "UsedByCamera", "XOffset", "YOffset"};
  result = "<"..dev.Name..">, Data: "..dev.Data..", Idx: ".. dev.idx;
  if mode == "full" then
    for k,v in pairs(dev) do
      exclude_flag = 0;
      for i, k1 in ipairs(exclude_fields) do
        if k1 == k then
          exclude_flag = 1;
          break;
        end
      end
      if exclude_flag == 0 then
        result = result..k.."="..tostring(v)..", ";
      else
        exclude_flag = 0;
      end
    end
  end
  return result;
end


function form_device_name(parsed_cli)
-- joins together parameters after the command name to form the full "device name"
  command = parsed_cli[2]
  DeviceName = parsed_cli[3]
  len_parsed_cli = #parsed_cli
  if len_parsed_cli > 3 then
    for i = 4, len_parsed_cli do
      DeviceName = DeviceName..' '..parsed_cli[i]
    end
  end
  return DeviceName
end

function variable_list()
  local t, jresponse, status, decoded_response
  t = server_url.."/json.htm?type=command&param=getuservariables"
  jresponse = nil
  domoticz_tries = 1
  -- Domoticz seems to take a while to respond to getuservariables after start-up
  -- So just keep trying after 1 second sleep
  while (jresponse == nil) do
    print_to_log ("JSON request <"..t..">");
    jresponse, status = http.request(t)
    if (jresponse == nil) then
      socket.sleep(1)
      domoticz_tries = domoticz_tries + 1
      if domoticz_tries > 100 then
        print_to_log('Domoticz not sending back user variable list')
        break
      end
    end
  end
  print_to_log('Domoticz returned getuservariables after '..domoticz_tries..' attempts')
  decoded_response = JSON:decode(jresponse)
  return decoded_response
end

function idx_from_variable_name(DeviceName)
  local idx, k, record, decoded_response
  decoded_response = variable_list()
  result = decoded_response["result"]
  for k,record in pairs(result) do
    if type(record) == "table" then
      if string.lower(record['Name']) == string.lower(DeviceName) then
        print_to_log(record['idx'])
        idx = record['idx']
      end
    end
  end
  return idx
end

function get_variable_value(idx)
  local t, jresponse, decoded_response
  if idx == nill then
      return ""
    end
    t = server_url.."/json.htm?type=command&param=getuservariable&idx="..tostring(idx)
  print_to_log ("JSON request <"..t..">");
  jresponse, status = http.request(t)
  decoded_response = JSON:decode(jresponse)
  print_to_log('Decoded '..decoded_response["result"][1]["Value"])
  return decoded_response["result"][1]["Value"]
end

function set_variable_value(idx,name,type,value)
  local t, jresponse, decoded_response
  t = server_url.."/json.htm?type=command&param=updateuservariable&idx="..idx.."&vname="..name.."&vtype="..type.."&vvalue="..tostring(value)
  print_to_log ("JSON request <"..t..">");
  jresponse, status = http.request(t)
  return
end

function create_variable(name,type,value)
  local t, jresponse, decoded_response
  t = server_url.."/json.htm?type=command&param=saveuservariable&vname="..name.."&vtype="..type.."&vvalue="..tostring(value)
  print_to_log ("JSON request <"..t..">");
  jresponse, status = http.request(t)
  return
end

function device_list(DeviceType)
  local t, jresponse, status, decoded_response
  t = server_url.."/json.htm?type="..DeviceType.."&order=name"
  print_to_log ("JSON request <"..t..">");
  jresponse, status = http.request(t)
  decoded_response = JSON:decode(jresponse)
  return decoded_response
end

function idx_from_name(DeviceName,DeviceType)
  local idx, k, record, decoded_response
  decoded_response = device_list(DeviceType)
  result = decoded_response["result"]
  for k,record in pairs(result) do
    if type(record) == "table" then
      if string.lower(record['Name']) == string.lower(DeviceName) then
        print_to_log(record['idx'])
        idx = record['idx']
      end
    end
  end
  return idx
end

function file_exists(name)
  local f=io.open(name,"r")
  if f~=nil then io.close(f) return true else return false end
end

print_to_log("Loading command modules...")
for i, m in ipairs(command_modules) do
  print_to_log("Loading module <"..m..">");
  t = assert(loadfile(BotLuaScriptPath..m..".lua"))();
  cl = t:get_commands();
  for c, r in pairs(cl) do
    print_to_log("found command <"..c..">");
    commands[c] = r;
    print_to_log(commands[c].handler);
  end
end

function timedifference(s)
  year = string.sub(s, 1, 4)
  month = string.sub(s, 6, 7)
  day = string.sub(s, 9, 10)
  hour = string.sub(s, 12, 13)
  minutes = string.sub(s, 15, 16)
  seconds = string.sub(s, 18, 19)
  t1 = os.time()
  t2 = os.time{year=year, month=month, day=day, hour=hour, min=minutes, sec=seconds}
  difference = os.difftime (t1, t2)
  return difference
end

function HandleCommand(cmd, SendTo, MessageId)
  print_to_log("Handle command function started with " .. cmd .. " and " .. SendTo)
  --- parse the command
  if command_prefix == "" then
    -- Command prefix is not needed, as can be enforced by Telegram api directly
    parsed_command = {"Stuff"}  -- to make compatible with Hangbot with password
  else
    parsed_command = {}
  end
  -- strip the beginning / from any command
  cmd = cmd:gsub("/","")
  local found=0

  ---------------------------------------------------------------------------
  -- Change for menu.lua option
  -- When LastCommand starts with menu then assume the rest is for menu.lua
  ---------------------------------------------------------------------------
  -- ensure the Array is initialised for this SendTo to keep track of the commands and other info
  Menuidx = idx_from_variable_name("DTGMENU")
  if Menuidx ~= nil then
    Menuval = get_variable_value(Menuidx)
    if Menuval == "On" then
      print_to_log("dtgbot: Start DTGMENU ...", cmd)
      local menu_cli = {}
      table.insert(menu_cli, "")  -- make it compatible
      table.insert(menu_cli, cmd)
      -- send whole cmd line instead of first word
      command_dispatch = commands["dtgmenu"];
      status, text, replymarkup, cmd = command_dispatch.handler(menu_cli,SendTo);
      if status ~= 0 then
        -- stop the process when status is not 0
        if text ~= "" then
          while string.len(text)>0 do
            send_msg(SendTo,string.sub(text,1,4000),MessageId,replymarkup)
            text = string.sub(text,4000,-1)
          end
        end
        print_to_log("dtgbot: dtgmenu ended and text send ...return:"..status)
        -- no need to process anything further
        return 1
      end
      print_to_log("dtgbot:continue regular processing. cmd =>",cmd)
    end
  end
  ---------------------------------------------------------------------------
  -- End change for menu.lua option
  ---------------------------------------------------------------------------

  --~	added "-_"to allowed characters a command/word
  for w in string.gmatch(cmd, "([%w-_]+)") do
    table.insert(parsed_command, w)
  end
  if command_prefix ~= "" then
    if parsed_command[1] ~= command_prefix then -- command prefix has not been found so ignore message
      return 1 -- not a command so successful but nothing done
    end
  end

  --? if(parsed_command[2]~=nil) then
  command_dispatch = commands[string.lower(parsed_command[2])];
--~ change to allow for replymarkup.
  local savereplymarkup = replymarkup
--~ 	print("debug1." ,replymarkup)
  if command_dispatch then
--?      status, text = command_dispatch.handler(parsed_command);
--~ change to allow for replymarkup.
    status, text, replymarkup = command_dispatch.handler(parsed_command,SendTo);
    found=1
  else
    text = ""
    local f = io.popen("ls " .. BotBashScriptPath)
--?      cmda = string.lower(parsed_command[2])
--~ change to avoid nil error
    cmda = string.lower(tostring(parsed_command[2]))
    len_parsed_command = #parsed_command
    stuff = ""
    for i = 3, len_parsed_command do
      stuff = stuff..parsed_command[i]
    end
    for line in f:lines() do
      print_to_log("checking line ".. line)
      if(line:match(cmda)) then
        print_to_log(line)
        os.execute(BotBashScriptPath  .. line .. ' ' .. SendTo .. ' ' .. stuff)
        found=1
      end
    end
  end
--~ replymarkup
  if replymarkup == nil or replymarkup == "" then
    -- restore the menu supplied replymarkup in case the shelled LUA didn't provide one
    replymarkup = savereplymarkup
  end
--~ 	print("debug2." ,replymarkup)
  if found==0 then
--?      text = "command <"..parsed_command[2].."> not found";
--~ change to avoid nil error
    text = "command <"..tostring(parsed_command[2]).."> not found";
  end
--?else
--?  text ='No command found'
--?end
  if text ~= "" then
    while string.len(text)>0 do
--?      send_msg(SendTo,string.sub(text,1,4000),MessageId)

--~         added replymarkup to allow for custom keyboard
      send_msg(SendTo,string.sub(text,1,4000),MessageId,replymarkup)
      text = string.sub(text,4000,-1)
    end
  elseif replymarkup ~= "" then
--~     added replymarkup to allow for custom keyboard reset also in case there is no text to send.
--~     This could happen after running a bash file.
    send_msg(SendTo,"done",MessageId,replymarkup)
  end
  return found
end

function url_encode(str)
  if (str) then
    str = string.gsub (str, "\n", "\r\n")
    str = string.gsub (str, "([^%w %-%_%.%~])",
      function (c) return string.format ("%%%02X", string.byte(c)) end)
      str = string.gsub (str, " ", "+")
  end
  return str
end

--~ added replymarkup to allow for custom keyboard
function send_msg(SendTo, Message, MessageId, replymarkup)
  if replymarkup == nil or replymarkup == "" then
    print_to_log(telegram_url..'sendMessage?timeout=60&chat_id='..SendTo..'&reply_to_message_id='..MessageId..'&text='..url_encode(Message))
    response, status = https.request(telegram_url..'sendMessage?chat_id='..SendTo..'&reply_to_message_id='..MessageId..'&text='..url_encode(Message))
  else
    print_to_log(telegram_url..'sendMessage?timeout=60&chat_id='..SendTo..'&reply_to_message_id='..MessageId..'&text='..url_encode(Message)..'&reply_markup='..url_encode(replymarkup))
    response, status = https.request(telegram_url..'sendMessage?chat_id='..SendTo..'&reply_to_message_id='..MessageId..'&text='..url_encode(Message)..'&reply_markup='..url_encode(replymarkup))
  end
--  response, status = https.request(telegram_url..'sendMessage?chat_id='..SendTo..'&text=hjk')
  print_to_log(status)
  return
end

--?function send_msg(SendTo, Message,MessageId)
--?  print_to_log(telegram_url..'sendMessage?timeout=60&chat_id='..SendTo..'&reply_to_message_id='..MessageId..'&text='..url_encode(Message))
--?  response, status = --?https.request(telegram_url..'sendMessage?chat_id='..SendTo..'&reply_to_message_id='..MessageId..'&text='..url_encode(Message))
--  response, status = https.request(telegram_url..'sendMessage?chat_id='..SendTo..'&text=hjk')
--?  print_to_log(status)
--?  return
--?end



--Commands.Smiliesoverview = "Smiliesoverview - sends a range of smilies"

--function Smiliesoverview(SendTo)
--  smilies = {"smiley 😀", "crying smiley 😢", "sleeping smiley 😴", "beer 🍺", "double beer 🍻",
--    "wine 🍷", "double red excam ‼️", "yellow sign exclamation mark ⚠️ ", "camera 📷", "light(on) 💡",
--    "open sun 🔆", "battery 🔋", "plug 🔌", "film 🎬", "music 🎶", "moon 🌙", "sun ☀️", "sun behind some clouds ⛅️",
--    "clouds ☁️", "lightning ⚡️", "umbrella ☔️", "snowflake ❄️"}
--  for i,smiley in ipairs(smilies) do
--    send_msg(SendTo,smiley,ok_cb,false)
--  end
--  return
--end

function id_check(SendTo)
  --Check if whitelist empty then let any message through
  if WhiteList == nil then
    return true
  else
    SendTo = tostring(SendTo)
    --Check id against whitelist
    print_to_log('No on WhiteList: '..#WhiteList)
    for i = 1, #WhiteList do
      print_to_log('WhiteList: '..WhiteList[i])
      if SendTo == WhiteList[i] then
        return true
      end
    end
    -- Checked WhiteList no match
    return false
  end
end

function on_msg_receive (msg)
  if started == 0 then
    return
  end
  if msg.out then
    return
  end

  if msg.text then   -- check if message is text
    --  ReceivedText = string.lower(msg.text)
    ReceivedText = msg.text

--    if msg.to.type == "chat" then -- check if the command was given in a group chat
--      msg_from = msg.to.print_name -- if yes, take the group name as a destination for the reply
--    else
--      msg_from = msg.from.print_name -- if no, take the users name as destination for the reply
--    end
--    msg_from = msg.from.id
--  Changed from from.id to chat.id to allow group chats to work as expected.
    msg_from = msg.chat.id
    msg_id =msg.message_id
--Check to see if id is whitelisted, if not record in log and exit
    if id_check(msg_from) then
      if HandleCommand(ReceivedText, tostring(msg_from),msg_id) == 1 then
        print_to_log "Succesfully handled incoming request"
      else
        print_to_log "Invalid command received"
        print_to_log(msg_from)
        send_msg(msg_from,'⚡️ INVALID COMMAND ⚡️',msg_id)
        --      os.execute("sleep 5")
        --      Help(tostring (msg_from))
      end
    else
      print_to_log('id '..msg_from..' not on white list, command ignored')
      send_msg(msg_from,'⚡️ ID Not Recognised - Command Ignored ⚡️',msg_id)
    end
  end
--  mark_read(msg_from)
end

--function on_our_id (id)
--  our_id = id
--end

function on_secret_chat_created (peer)
  --vardump (peer)
end

function on_user_update (user)
  --vardump (user)
end

function on_chat_update (user)
  --vardump (user)
end

function on_get_difference_end ()
end

function on_binlog_replay_end ()
  started = 1
end

function get_names_from_variable(DividedString)
  Names = {}
  for Name in string.gmatch(DividedString, "[^|]+") do
    Names[#Names + 1] = Name
    print_to_log('Name :'..Name)
  end
  if Names == {} then
    Names = nil
  end
  return Names
end

-- Retrieve id white list
WLidx = idx_from_variable_name(WLName)
if WLidx == nil then
  print_to_log(WLName..' user variable does not exist in Domoticz')
  print_to_log('So will allow any id to use the bot')
else
  print_to_log('WLidx '..WLidx)
  WLString = get_variable_value(WLidx)
  print_to_log('WLString: '..WLString)
  WhiteList = get_names_from_variable(WLString)
end

-- Get the updates
print_to_log('Getting '..TBOName..' the previous Telegram bot message offset from Domoticz')
TBOidx = idx_from_variable_name(TBOName)
if TBOidx == nil then
  print_to_log(TBOName..' user variable does not exist in Domoticz')
  os.exit()
else
  print_to_log('TBOidx '..TBOidx)
end
TelegramBotOffset=get_variable_value(TBOidx)
print_to_log('TBO '..TelegramBotOffset)
print_to_log(telegram_url)
--while TelegramBotOffset do
while file_exists(dtgbot_pid) do
  response, status = https.request(telegram_url..'getUpdates?timeout=60&offset='..TelegramBotOffset)
  if status == 200 then
    if response ~= nil then
      io.write('.')
      print_to_log(response)
      decoded_response = JSON:decode(response)
      result_table = decoded_response['result']
      tc = #result_table
      for i = 1, tc do
        print_to_log('Message: '..i)
        tt = table.remove(result_table,1)
        msg = tt['message']
        print_to_log('update_id ',tt.update_id)
        print_to_log(msg.text)
        TelegramBotOffset = tt.update_id + 1
        on_msg_receive(msg)
        print_to_log('TelegramBotOffset '..TelegramBotOffset)
        set_variable_value(TBOidx,TBOName,0,TelegramBotOffset)
      end
    else
      print_to_log(status)
    end
  end
end
print_to_log(dtgbot_pid..' does not exist, so exiting')
