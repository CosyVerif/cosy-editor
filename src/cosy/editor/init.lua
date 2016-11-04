local Colors    = require "ansicolors"
local Copas     = require "copas"
local Et        = require "etlua"
local Json      = require "cjson"
local Layer     = require "layeredata"
local Websocket = require "websocket"
local Time      = require "socket".gettime
local Url       = require "socket.url"
local Http      = require "cosy.editor.http"

-- Messages:
-- { id = ..., type = "authenticate", token = "...", user = "..." }
-- { id = ..., type = "patch"       , patch = "..." }
-- { id = ..., type = "answer"      , success = true|false, reason = "..." }
-- { id = ..., type = "update"      , patch = "...", origin = "user" }
-- { id = ..., type = "execute" }

local Editor = {}
Editor.__index = Editor

function Editor.create (options)
  local resource = Url.parse (options.resource)
  resource.url   = options.resource
  local api = {
    scheme = resource.scheme,
    host   = resource.host,
    port   = resource.port,
    path   = "/",
  }
  api.url = Url.build (api)
  local editor = setmetatable ({
    running   = true,
    connected = 0,
    api       = api,
    port      = assert (options.port),
    resource  = resource,
    token     = assert (options.token),
    clients   = setmetatable ({}, { __mode = "k" }),
    queue     = {},
    Layer     = Layer,
    data      = nil,
    layer     = nil,
  }, Editor)
  Layer.require = function (name)
    local loaded = Layer.loaded [name]
    if loaded then
      return loaded, Layer.Reference.new (loaded)
    elseif pcall (require, name) then
      local layer, ref = editor:load (require (name))
      Layer.loaded [name] = layer
      return layer, ref
    else
      local project_name, resource_name = name:match "^(%w+)/(%w+)$"
      local url
      if project_name then
        url = Et.render ("<%- api %>/projects/<%- project %>/resources/<%- resource %>", {
          api      = editor.api.url,
          project  = project_name,
          resource = resource_name,
        })
      else
        local _, status, headers = Http.json {
          copas    = true,
          url      = Et.render ("<%- api %>/aliases/<%- alias %>", {
            api   = editor.api.url,
            alias = name,
          }),
          method   = "GET",
          redirect = false,
          headers  = { Authorization = "Bearer " .. tostring (editor.token) },
        }
        if status == 302 then
          url = headers.location
        else
          error (status)
        end
      end
      local result, status = Http.json {
        copas   = true,
        url     = url,
        method  = "GET",
        headers = { Authorization = "Bearer " .. tostring (editor.token) },
      }
      if status == 200 then
        local layer, ref = editor:load (result.data)
        Layer.loaded [name] = layer
        return layer, ref
      elseif status == 404 then
        error "not found"
      elseif status == 403 then
        error "forbidden"
      else
        error (status)
      end
    end
  end
  return editor
end

function Editor.start (editor)
  editor.last_access = Time ()
  local copas_addserver = Copas.addserver
  local addserver       = function (socket, f)
    editor.socket = socket
    editor.host, editor.port = socket:getsockname ()
    copas_addserver (socket, f)
    print (Colors (Et.render ("%{blue}[<%= time %>]%{reset} Start editor for %{green}<%= resource %>%{reset} at %{green}<%= url %>%{reset}.", {
      resource = editor.resource,
      time     = os.date "%c",
      url      = "ws://" .. editor.host .. ":" .. tostring (editor.port),
    })))
  end
  local function handler (ws)
    print (Colors (Et.render ("%{blue}[<%= time %>]%{reset} New connection for %{green}<%= resource %>%{reset}.", {
      resource = editor.resource,
      time     = os.date "%c",
    })))
    while editor.running do
      local ok
      local message = ws:receive ()
      if not message then
        ws:close ()
        return
      end
      editor.last_access = Time ()
      ok, message = pcall (Json.decode, message)
      if not ok then
        ws:send (Json.encode {
          type    = "answer",
          success = false,
          reason  = "invalid JSON",
        })
      elseif type (message) ~= "table" then
        ws:send (Json.encode {
          type    = "answer",
          success = false,
          reason  = "invalid message",
        })
      elseif not message.id or not message.type then
        ws:send (Json.encode {
          id      = message.id,
          type    = "answer",
          success = false,
          reason  = "invalid message",
        })
      elseif message.type == "authenticate" then
      local   _, status = Http.json {
          copas   = true,
          url     = editor.resource.url,
          method  = "HEAD",
          headers = { Authorization = message.token and "Bearer " .. tostring (message.token) },
        }
        if status == 204 then
          ws:send (Json.encode {
            id      = message.id,
            type    = "answer",
            success = true,
          })
          editor.clients [ws] = {
            user  = message.user,
            token = message.token,
          }
          ws:send (Json.encode {
            type   = "update",
            patch  = editor.data,
            origin = editor.resource.url,
          })
        else
          editor.clients [ws] = nil
          ws:send (Json.encode {
            id      = message.id,
            type    = "answer",
            success = false,
            reason  = "authentication failure",
          })
        end
      elseif message.type == "patch" then
        message.client = ws
        message.info   = editor.clients [ws]
        editor.queue [#editor.queue+1] = message
        Copas.wakeup (editor.worker)
      else
        ws:send (Json.encode {
          id      = message.id,
          type    = "answer",
          success = false,
          reason  = "invalid message",
        })
      end
    end
  end
  editor.worker = Copas.addthread (function ()
    while editor.running do
      xpcall (function ()
        local message = editor.queue [1]
        if message then
          table.remove (editor.queue, 1)
          assert (message.type == "patch")
          local layer = editor:load (message.patch)
          if not layer then
            message.client:send (Json.encode {
              id      = message.id,
              type    = "answer",
              success = false,
              reason  = "invalid layer",
            })
            return
          end
          if not message.info then
            message.client:send (Json.encode {
              id      = message.id,
              type    = "answer",
              success = false,
              reason  = "not authentified",
            })
            return
          end
          local _, status = Http.json {
            copas   = true,
            url     = editor.resource.url,
            method  = "PATCH",
            body    = {
              patches = { message.patch },
              data    = editor.data,
              editor  = editor.token,
            },
            headers = { Authorization = message.info.token and "Bearer " .. tostring (message.info.token) },
          }
          if status == 204 then
            editor.Layer.merge (layer, editor.layer)
            editor.data = editor.Layer.dump (editor.layer)
            message.client:send (Json.encode {
              id      = message.id,
              type    = "answer",
              success = true,
            })
            for client in pairs (editor.clients) do
              if client ~= message.client then
                client:send (Json.encode {
                  type   = "update",
                  patch  = message.patch,
                  origin = message.info.user,
                })
              end
            end
          elseif status == 403 then
            message.client:send (Json.encode {
              id      = message.id,
              type    = "answer",
              success = false,
              reason  = "forbidden",
            })
          else
            message.client:send (Json.encode {
              id      = message.id,
              type    = "answer",
              success = false,
              reason  = status,
            })
          end
        else
          Copas.sleep (-math.huge)
        end
      end, function (err)
        print (err, debug.traceback ())
      end)
      if editor.connected == 0 and #editor.queue == 0 then
        editor:stop ()
      end
    end
  end)
  local ok, resource, status = pcall (Http.json, {
    url     = editor.resource.url,
    method  = "GET",
    headers = { Authorization = "Bearer " .. editor.token},
  })
  if ok then
    assert (status == 200, status)
    local loaded
    if _G.loadstring then
      loaded = assert (_G.loadstring (resource.data))
    else
      loaded = assert (_G.load (resource.data, nil, "t"))
    end
    local layer, ref = editor.Layer.new {}
    loaded (editor.Layer, layer, ref)
    editor.data  = resource.data
    editor.layer = layer
  end
  Copas.addserver = addserver
  editor.server   = Websocket.server.copas.listen {
    port      = editor.port,
    default   = handler,
    protocols = {
      cosy = function (ws)
        editor.connected = editor.connected + 1
        xpcall (function ()
          handler (ws)
        end, function (err)
          print (err, debug.traceback ())
        end)
        editor.connected = editor.connected - 1
        if editor.connected == 0 and #editor.queue == 0 then
          editor:stop ()
        end
      end,
    },
  }
  Copas.addserver = copas_addserver
end

function Editor.stop (editor)
  editor.stopper = editor.stopper or
    Copas.addthread (function ()
      editor.running = false
      print (Colors (Et.render ("%{blue}[<%= time %>]%{reset} Stop editor for %{green}<%= resource %>.", {
        resource = editor.resource,
        time     = os.date "%c",
      })))
      editor.server:close ()
      pcall (Http.json, {
        copas   = true,
        url     = editor.resource.url .. "/editor",
        method  = "DELETE",
        headers = { Authorization = "Bearer " .. editor.token }
      })
      Copas.wakeup (editor.worker)
    end)
end

function Editor.load (editor, patch)
  local loaded, ok, err
  if type (patch) == "string" then
    if _G.loadstring then
      loaded, err = _G.loadstring (patch)
    else
      loaded, err = _G.load (patch, nil, "t")
    end
    if not loaded then
      return nil, err
    end
    ok, loaded = pcall (loaded)
    if not ok then
      return nil, loaded
    end
  elseif type (patch) == "function" then
    loaded = patch
  end
  if not loaded then
    return nil, "no patch"
  end
  local current, ref = editor.Layer.new {
    [editor.Layer.key.refines] = {
      editor.layer,
    }
  }
  ok, err = pcall (loaded, editor.Layer, current, ref)
  if not ok then
    return nil, err
  end
  return current, ref
end

return Editor
