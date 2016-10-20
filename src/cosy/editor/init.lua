local Colors    = require "ansicolors"
local Copas     = require "copas"
local Et        = require "etlua"
local Json      = require "cjson"
local Layer     = require "layeredata"
local Websocket = require "websocket"
local Time      = require "socket".gettime
local Http      = require "cosy.editor.http"

-- Messages:
-- { id = ..., type = "authenticate", token = "...", user = "..." }
-- { id = ..., type = "patch"       , patch = "..." }
-- { id = ..., type = "answer"      , success = true|false, reason = "..." }
-- { id = ..., type = "update"      , patch = "...", origin = "user" }

local Editor = {}
Editor.__index = Editor

function Editor.create (options)
  local editor = setmetatable ({
    running  = true,
    api      = options.api or false,
    port     = assert (options.port),
    project  = assert (options.project),
    resource = assert (options.resource),
    timeout  = assert (options.timeout),
    token    = assert (options.token),
    clients  = setmetatable ({}, { __mode = "k" }),
    queue    = {},
    Layer    = Layer,
    data     = nil,
    layer    = nil,
  }, Editor)
  if editor.api then
    editor.url = Et.render ("<%- api %>/projects/<%- project %>/resources/<%- resource %>", editor)
    Layer.require = function (name)
      local loaded = Layer.loaded [name]
      if loaded then
        return loaded, Layer.Reference.new (loaded)
      else
        local result, status = Http.json {
          copas   = true,
          url     = editor.api .. "/" .. name,
          method  = "GET",
          headers = { Authorization = "Bearer " .. tostring (editor.token) },
        }
        if status == 204 then
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
    local url = "ws://" .. editor.host .. ":" .. tostring (editor.port)
    Copas.addthread (function ()
      while editor.running do
        if editor.last_access + editor.timeout <= Time () then
          editor:stop ()
          return
        end
        Copas.sleep (1)
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
        local _, status = Http.json {
          copas   = true,
          url     = editor.url,
          method  = "HEAD",
          headers = { Authorization = "Bearer " .. tostring (message.token) },
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
            origin = editor.url,
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
        if editor.clients [ws] then
          message.client = ws
          editor.queue [#editor.queue+1] = message
          Copas.wakeup (editor.worker)
        else
          ws:send (Json.encode {
            id      = message.id,
            type    = "answer",
            success = false,
            reason  = "authentication failure",
          })
        end
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
          if layer then
            local info = editor.clients [message.client]
            local _, status = Http.json {
              copas   = true,
              url     = editor.url,
              method  = "PATCH",
              body    = {
                patches = { message.patch },
                data    = editor.data,
                editor  = editor.token,
              },
              headers = { Authorization = "Bearer " .. tostring (info.token) },
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
                    origin = info.user,
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
            message.client:send (Json.encode {
              id      = message.id,
              type    = "answer",
              success = false,
              reason  = "invalid layer",
            })
          end
        else
          Copas.sleep (-math.huge)
        end
      end, function (err)
        print (err, debug.traceback ())
      end)
    end
  end)
  if editor.url then
    local resource, status = Http.json {
      url     = editor.url,
      method  = "GET",
      headers = { Authorization = "Bearer " .. editor.token},
    }
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
      cosy = handler,
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
      if editor.url then
        local _, status = Http.json {
          copas   = true,
          url     = editor.url .. "/editor",
          method  = "DELETE",
          headers = { Authorization = "Bearer " .. editor.token }
        }
        assert (status == 202)
      end
      Copas.wakeup (editor.worker)
    end)
end

function Editor.load (editor, patch)
  local loaded, ok, err
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
