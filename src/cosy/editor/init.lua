local Colors    = require "ansicolors"
local Copas     = require "copas"
local Et        = require "etlua"
local Json      = require "cjson"
local Layer     = require "layeredata"
local Websocket = require "websocket"
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
    running   = false,
    count     = 0,
    api       = api,
    port      = assert (options.port),
    resource  = resource,
    token     = assert (options.token),
    clients   = setmetatable ({}, { __mode = "k" }),
    connected = setmetatable ({}, { __mode = "k" }),
    queue     = {},
    Layer     = Layer,
    data      = nil,
    base      = nil,
    current   = nil,
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
  assert (getmetatable (editor) == Editor)
  local copas_addserver = Copas.addserver
  local addserver       = function (socket, f)
    editor.socket = socket
    editor.host, editor.port = socket:getsockname ()
    copas_addserver (socket, f)
    print (Colors (Et.render ("%{blue}[<%= time %>]%{reset} Start editor for %{green}<%= resource %>%{reset} at %{green}<%= url %>%{reset}.", {
      resource = editor.resource.url,
      time     = os.date "%c",
      url      = "ws://" .. editor.host .. ":" .. tostring (editor.port),
    })))
  end
  local resource, status = Http.json {
    url     = editor.resource.url,
    method  = "GET",
    headers = { Authorization = "Bearer " .. editor.token},
  }
  if resource then
    assert (status == 200, status)
    local layer, ref = editor:load (resource.data)
    local current    = Layer.new { temporary = true }
    current [Layer.key.refines] = { layer }
    editor.data    = resource.data
    editor.base    = {
      layer = layer,
      ref   = ref,
    }
    editor.current = {
      layer = current,
      ref   = ref,
    }
  end
  editor.count    = 0
  editor.running  = true
  Copas.addserver = addserver
  editor.server   = Websocket.server.copas.listen {
    port      = editor.port,
    default   = function () end,
    protocols = {
      cosy = function (ws)
        editor.count = editor.count + 1
        print (Colors (Et.render ("%{blue}[<%= time %>]%{reset} New connection for %{green}<%= resource %>%{reset}.", {
          resource = editor.resource.url,
          time     = os.date "%c",
        })))
        editor.connected [ws] = true
        while editor.running and ws.state == "OPEN" do
          editor:dispatch (ws)
          editor:check  ()
        end
        editor.connected [ws] = nil
      end,
    },
  }
  Copas.addserver = copas_addserver
  editor.worker   = Copas.addthread (function ()
    while editor.running do
      editor:answer ()
      editor:check  ()
    end
  end)
  editor.stopper  = Copas.addthread (function ()
    while editor.running do
      Copas.sleep (-math.huge)
      editor:stop ()
    end
  end)
end

function Editor.dispatch (editor, ws)
  assert (getmetatable (editor) == Editor)
  local ok
  local message = ws:receive ()
  if not message then
    ws:close ()
    return
  end
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
    local result, status = Http.json {
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
        reason  = {
          result = result,
          status = status,
          token  = message.token,
          url    = editor.resource.url,
        },
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

function Editor.answer (editor)
  assert (getmetatable (editor) == Editor)
  local message = editor.queue [1]
  if not message then
    return Copas.sleep (1)
  end
  table.remove (editor.queue, 1)
  assert (message.type == "patch")
  local layer   = editor:load (message.patch, editor.current)
  local refines = editor.current.layer [Layer.key.refines]
  refines [2]   = nil
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
    Layer.merge (layer, editor.base.layer)
    editor.data = Layer.dump (editor.base.layer)
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
end

function Editor.check (editor)
  assert (getmetatable (editor) == Editor)
  if  next (editor.connected) == nil
  and #editor.queue == 0
  and editor.count  > 0
  then
    Copas.wakeup (editor.stopper)
  end
end

function Editor.stop (editor)
  assert (getmetatable (editor) == Editor)
  print (Colors (Et.render ("%{blue}[<%= time %>]%{reset} Stop editor for %{green}<%= resource %>.", {
    resource = editor.resource.url,
    time     = os.date "%c",
  })))
  editor.running = false
  editor.server:close ()
  Http.json {
    copas   = true,
    url     = editor.resource.url .. "/editor",
    method  = "DELETE",
    headers = { Authorization = "Bearer " .. editor.token }
  }
  Copas.wakeup (editor.worker)
end

function Editor.load (editor, patch, within)
  assert (getmetatable (editor) == Editor)
  assert (within == nil or type (within) == "table")
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
  local layer, ref
  if within then
    layer, ref = Layer.new {
      temporary = true
    }, within.ref
    local refines = within.layer [Layer.key.refines]
    refines [Layer.len (refines)+1] = layer
    local old = Layer.write_to (within.layer, layer)
    ok, err = pcall (loaded, editor.Layer, within.layer, within.ref)
    Layer.write_to (within.layer, old)
  else
    layer, ref = Layer.new {}
    ok, err = pcall (loaded, editor.Layer, layer, ref)
  end
  if not ok then
    return nil, err
  end
  return layer, ref
end

return Editor
