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
-- { id = ..., type = "update"      , layer = "...", patch = "...", origin = "user" }
-- { id = ..., type = "require"     , module = "..." }
-- { id = ..., type = "answer"      , success = true|false, reason = "..." }
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
    timeout   = assert (options.timeout),
    api       = api,
    port      = assert (options.port),
    resource  = resource,
    token     = assert (options.token),
    clients   = setmetatable ({}, { __mode = "k" }),
    connected = setmetatable ({}, { __mode = "k" }),
    requests  = {},
    queue     = {},
    layers    = {},
    Layer     = setmetatable ({}, { __index = Layer }),
  }, Editor)
  editor.Layer.require = function (name)
    local result, err = editor:require (name)
    if not result then
      error (err)
    end
    return result.layer, result.ref
  end
  return editor
end

function Editor.start (editor)
  assert (getmetatable (editor) == Editor)
  local layer = editor:require (editor.resource.url)
  if not layer then
    print (Colors (Et.render ("%{blue}[<%- time %>]%{reset} Cannot find resource %{red}<%- resource %>%{reset}.", {
      resource = editor.resource.url,
      time     = os.date "%c",
    })))
  end
  editor.last     = os.time ()
  editor.count    = 0
  editor.running  = true
  local copas_addserver = Copas.addserver
  local addserver       = function (socket, f)
    editor.socket = socket
    editor.host, editor.port = socket:getsockname ()
    copas_addserver (socket, f)
    print (Colors (Et.render ("%{blue}[<%- time %>]%{reset} Start editor for %{green}<%- resource %>%{reset} at %{green}<%- url %>%{reset}.", {
      resource = editor.resource.url,
      time     = os.date "%c",
      url      = "ws://" .. editor.host .. ":" .. tostring (editor.port),
    })))
  end
  Copas.addserver = addserver
  editor.server   = Websocket.server.copas.listen {
    port      = editor.port,
    default   = function () end,
    protocols = {
      cosy = function (ws)
        editor.count = editor.count + 1
        editor.last  = os.time ()
        print (Colors (Et.render ("%{blue}[<%- time %>]%{reset} New connection for %{green}<%- resource %>%{reset}.", {
          resource = editor.resource.url,
          time     = os.date "%c",
        })))
        editor.connected [ws] = true
        while editor.running and ws.state == "OPEN" do
          editor:dispatch (ws)
        end
        editor.connected [ws] = nil
      end,
    },
  }
  Copas.addserver = copas_addserver
  editor.worker   = Copas.addthread (function ()
    while editor.running do
      editor:answer ()
    end
  end)
  editor.stopper   = Copas.addthread (function ()
    while editor.running do
      if  next (editor.connected) == nil
      and #editor.queue == 0
      and editor.count  > 0
      and editor.last + editor.timeout < os.time ()
      then
        editor:stop ()
      else
        Copas.sleep (editor.timeout / 2)
      end
    end
  end)
end

function Editor.connect (editor, url)
  local wsurl
  local info = editor.layers [url]
  for _ = 1, 60 do
    local _, status, headers = Http.json {
      redirect = false,
      url      = editor.api.url .. info.path .. "/editor",
      method   = "GET",
      headers  = {
        Authorization = "Bearer " .. tostring (editor.token),
      },
    }
    if status == 302 then
      wsurl = headers.location:gsub ("^http", "ws")
      break
    end
    Copas.sleep (1)
  end
  assert (wsurl)
  local client = Websocket.client.copas ()
  assert (client:connect (wsurl, "cosy"))
  info.ws = client
  client:send (Json.encode {
    id    = 1,
    type  = "authenticate",
    token = editor.token,
    user  = editor.resource.url,
  })
  local answer = client:receive ()
  answer = Json.decode (answer)
  assert (answer.success, answer.reason)
  while editor.running do
    local message = client:receive ()
    if not message then
      client:close ()
      info.receiver = nil
      return
    end
    message = Json.decode (message)
    if message.type == "update" then
      editor.queue [#editor.queue+1] = message
      Copas.wakeup (editor.worker)
    else
      assert (false)
    end
  end
end

function Editor.dispatch (editor, ws)
  assert (getmetatable (editor) == Editor)
  local ok
  local message = ws:receive ()
  if not message then
    ws:close ()
    return
  end
  editor.last = os.time ()
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
        layer  = editor.resource.url,
        patch  = editor.layers [editor.resource.url].data,
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
  elseif message.type == "require" then
    if editor.clients [ws] then
      local result = editor:require (message.module)
      if result then
        ws:send (Json.encode {
          id      = message.id,
          type    = "answer",
          success = true,
          module  = result.data,
        })
      else
        ws:send (Json.encode {
          id      = message.id,
          type    = "answer",
          success = false,
          reason  = "not found",
        })
      end
    else
      ws:send (Json.encode {
        id      = message.id,
        type    = "answer",
        success = false,
        reason  = "forbidden",
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

function Editor.answer (editor)
  assert (getmetatable (editor) == Editor)
  local message = editor.queue [1]
  if not message then
    return Copas.sleep (-math.huge)
  end
  editor.last = os.time ()
  local layer = editor.layers [editor.resource.url]
  table.remove (editor.queue, 1)
  if message.type == "update" then
    local change, err = editor:patch (message.patch, message.layer)
    if not change then
      return print (Colors (Et.render ("%{red}[<%- time %>]%{reset} Cannot apply patch to %{blue}<%- layer %>%{reset}: %{red}<%- error %>%{reset}.", {
        time  = os.date "%c",
        layer = message.layer,
        error = err,
      })))
    end
    Layer.merge (change, layer.remote)
    for client in pairs (editor.clients) do
      client:send (Json.encode {
        type    = "update",
        layer   = message.layer,
        patch   = message.patch,
        origin  = message.origin,
      })
    end
  elseif message.type == "patch" then
    if not message.info then
      message.client:send (Json.encode {
        id      = message.id,
        type    = "answer",
        success = false,
        reason  = "not authentified",
      })
      return
    end
    local change, err = editor:patch (message.patch)
    if not change then
      print (Colors (Et.render ("%{red}[<%- time %>]%{reset} Cannot apply patch: %{red}<%- error %>%{reset}.", {
        time  = os.date "%c",
        error = Json.encode (err),
      })))
      return message.client:send (Json.encode {
        id      = message.id,
        type    = "answer",
        success = false,
        reason  = err,
      })
    end
    local _, status = Http.json {
      url     = editor.resource.url,
      method  = "PATCH",
      body    = {
        patches = { message.patch },
        editor  = editor.token,
      },
      headers = { Authorization = message.info.token and "Bearer " .. tostring (message.info.token) },
    }
    if status ~= 204 then
      return message.client:send (Json.encode {
        id      = message.id,
        type    = "answer",
        success = false,
        reason  = { status = status },
      })
    end
    Layer.merge (change, layer.remote)
    layer.data = Layer.dump (layer.remote)
    _, status = Http.json {
      url     = editor.resource.url,
      method  = "PATCH",
      body    = {
        data    = layer.data,
        editor  = editor.token,
      },
      headers = { Authorization = "Bearer " .. tostring (editor.token) },
    }
    assert (status == 204)
    message.client:send (Json.encode {
      id      = message.id,
      type    = "answer",
      success = true,
    })
    for client in pairs (editor.clients) do
      if client ~= message.client then
        client:send (Json.encode {
          type   = "update",
          layer  = editor.resource.url,
          patch  = message.patch,
          origin = message.info.user,
        })
      end
    end
  end
end

function Editor.stop (editor)
  assert (getmetatable (editor) == Editor)
  print (Colors (Et.render ("%{blue}[<%- time %>]%{reset} Stop editor for %{green}<%- resource %>.", {
    resource = editor.resource.url,
    time     = os.date "%c",
  })))
  editor.running = false
  editor.server:close ()
  Http.json {
    url     = editor.resource.url .. "/editor",
    method  = "DELETE",
    headers = { Authorization = "Bearer " .. editor.token }
  }
  Copas.wakeup (editor.worker)
  Copas.wakeup (editor.stopper)
  for _, info in pairs (editor.layers) do
    if info.receiver then
      Copas.wakeup (info.receiver)
    end
  end
end

function Editor.require (editor, module)
  assert (getmetatable (editor) == Editor)
  if editor.layers [module] then
    return editor.layers [module]
  end
  local aliases = {}
  local url
  local project_name, resource_name = module:match "^(%w+)/(%w+)$"
  if project_name then
    url = Et.render ("<%- api %>/projects/<%- project %>/resources/<%- resource %>", {
      api      = editor.api.url,
      project  = project_name,
      resource = resource_name,
    })
  elseif not module:match "^https?://" then
    url      = Et.render ("<%- api %>/aliases/<%- alias %>", {
      api   = editor.api.url,
      alias = module,
    })
  else
    url = module
  end
  local contents, status, headers
  repeat
    aliases [#aliases+1] = url
    if editor.layers [url] then
      local result = editor.layers [url]
      for _, alias in ipairs (aliases) do
        editor.layers [alias] = result
      end
      return result
    end
    contents, status, headers = Http.json {
      url      = url,
      method   = "GET",
      redirect = false,
      headers  = { Authorization = "Bearer " .. tostring (editor.token) },
    }
    if status == 302 then
      url = headers.location
    elseif status ~= 200 then
      return nil, { status = status }
    end
  until status == 200
  local loaded, ok, err
  if _G.loadstring then
    loaded, err = _G.loadstring (contents.data)
  else
    loaded, err = _G.load (contents.data, nil, "t")
  end
  if not loaded then
    return nil, { error = err }
  end
  ok, loaded = pcall (loaded)
  if not ok then
    return nil, { error = loaded }
  end
  for _, name in ipairs (aliases) do
    editor.layers [name] = contents
  end
  if url == editor.resource.url then
    local remote, ref = Layer.new {
      name = module,
    }
    ok, err = pcall (loaded, editor.Layer, remote, ref)
    if not ok then
      return nil, err
    end
    local layer = Layer.new {
      temporary = true,
    }
    layer [Layer.key.refines] = { remote }
    contents.layer  = layer
    contents.remote = remote
    contents.ref    = ref
  else
    local remote, ref = Layer.new {
      name = module,
    }
    ok, err = pcall (loaded, editor.Layer, remote, ref)
    if not ok then
      return nil, err
    end
    contents.layer  = remote
    contents.remote = remote
    contents.ref    = ref
    Layer.write_to (remote, false) -- read-only
    contents.receiver = Copas.addthread (function ()
      editor:connect (url)
    end)
  end
  return contents
end

function Editor.patch (editor, patch, what)
  assert (getmetatable (editor) == Editor)
  -- load patch:
  local ok, loaded, error
  if type (patch) == "string" then
    if _G.loadstring then
      loaded, error = _G.loadstring (patch)
    else
      loaded, error = _G.load (patch, nil, "t")
    end
    if loaded then
      ok, loaded = pcall (loaded)
    else
      return nil, error
    end
    if not ok then
      return nil, loaded
    end
  elseif type (patch) == "function" then
    loaded = patch
  end
  -- apply patch:
  local fresh
  if what then
    local where   = editor:require (what)
    local layer   = Layer.new {
      temporary = true,
    }
    fresh = Layer.new {
      temporary = true,
    }
    layer [Layer.key.refines] = { where.layer, fresh }
    Layer.write_to (layer, fresh)
    ok, error = pcall (loaded, editor.Layer, layer, where.ref)
    Layer.write_to (layer, nil)
  else
    local where   = editor:require (editor.resource.url)
    local refines = where.layer [Layer.key.refines]
    fresh = Layer.new {
      temporary = true,
    }
    refines [Layer.len (refines)+1] = fresh
    Layer.write_to (where.layer, fresh)
    ok, error = pcall (loaded, editor.Layer, where.layer, where.ref)
    Layer.write_to (where.layer, nil)
    refines [Layer.len (refines)] = nil
  end
  if not ok then
    return nil, error
  end
  return fresh
end

return Editor
