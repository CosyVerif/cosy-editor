local Colors    = require "ansicolors"
local Copas     = require "copas"
local Et        = require "etlua"
local Json      = require "cjson"
local Websocket = require "websocket"
local Time      = require "socket".gettime
local Ltn12     = require "ltn12"
local CHttp     = require "copas.http"
local Http      = require "socket.http"

local Editor = {}
Editor.__index = Editor

local function request (http, url, options)
  local result = {}
  local headers = options.headers or {}
  if options.json then
    options.json = Json.encode (options.json)
    headers ["Content-length"] = #options.json
    headers ["Content-type"  ] = "application/json"
  end
  local _, status = http.request {
    url      = url,
    source   = options.json and Ltn12.source.string (options.json),
    sink     = Ltn12.sink.table (result),
    method   = options.method,
    headers  = headers,
  }
  if status ~= 200 then
    return nil, status
  end
  return Json.decode (table.concat (result)), tonumber (status)
end

function Editor.create (options)
  local result = setmetatable ({
    api      = assert (options.api),
    port     = assert (options.port),
    project  = assert (options.project),
    resource = assert (options.resource),
    timeout  = assert (options.timeout),
    token    = assert (options.token),
  }, Editor)
  result.url = Et.render ("<%- api %>/projects/<%- project %>/resources/<%- resource %>", result)
  return result
end

function Editor.start (editor)
  editor.last_access = Time ()
  local copas_addserver = Copas.addserver
  local addserver       = function (socket, f)
    editor.socket = socket
    editor.host, editor.port = socket:getsockname ()
    copas_addserver (socket, f)
    local url = "ws://" .. editor.host .. ":" .. tostring (editor.port)
    Copas.addthread (function ()
      while true do
        Copas.sleep (1)
        if editor.last_access + editor.timeout <= Time () then
          editor:stop ()
          return
        end
      end
    end)
    print (Colors (Et.render ("%{blue}[<%= time %>]%{reset} Start editor for %{green}<%= resource %>%{reset} at %{green}<%= url %>%{reset}.", {
      resource = editor.resource,
      time     = os.date "%c",
      url      = url,
    })))
  end

  local function handler (ws)
    print (Colors (Et.render ("%{blue}[<%= time %>]%{reset} New connection for %{green}<%= resource %>%{reset}.", {
      resource = editor.resource,
      time     = os.date "%c",
    })))
    repeat
      local message = ws:receive ()
      if message then
        ws:send (message)
      end
    until not message
    -- last_access = Time ()
    -- local message   = ws:receive ()
    -- local greetings = message and Util.from_json (message)
    -- if not greetings then
    --   return
    -- end
    -- local token = greetings.token
    -- token = Jwt.decode (token, {
    --   keys = {
    --     public = Config.auth0.client_secret
    --   }
    -- })
    -- if not token
    -- or token.resource ~= data.resource
    -- or not token.user
    -- or not token.permissions
    -- or not token.permissions.read then
    --   return
    -- end
    --
    -- while true do
    --   local message = ws:receive ()
    --   if message then
    --      ws:send (message)
    --   else
    --      ws:close ()
    --      return
    --   end
    -- end
  end

  local _, status = request (Http, editor.url, {
    method  = "HEAD",
    headers = { Authorization = "Bearer " .. editor.token},
  })
  assert (status == 204, status)
  Copas.addserver = addserver
  editor.server = Websocket.server.copas.listen {
    port      = editor.port,
    default   = handler,
    protocols = {
      cosy = handler,
    },
  }
  Copas.addserver = copas_addserver
  Copas.loop ()
end

function Editor.stop (editor)
  Copas.addthread (function ()
    print (Colors (Et.render ("%{blue}[<%= time %>]%{reset} Stop editor for %{green}<%= resource %>.", {
      resource = editor.resource,
      time     = os.date "%c",
    })))
    editor.server:close ()
    local _, status = request (CHttp, editor.url .. "/editor", {
      method = "DELETE",
      headers = { Authorization = "Bearer " .. editor.token }
    })
    assert (status == 204)
  end)
end

return Editor
