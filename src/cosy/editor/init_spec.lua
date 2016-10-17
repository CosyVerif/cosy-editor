local assert   = require "luassert"
local Copas    = require "copas"
local Et       = require "etlua"
local Jwt      = require "jwt"
local Time     = require "socket".gettime
local Http     = require "cosy.editor.http"
local Instance = require "cosy.server.instance"

local Config = {
  auth0       = {
    domain        = assert (os.getenv "AUTH0_DOMAIN"),
    client_id     = assert (os.getenv "AUTH0_ID"    ),
    client_secret = assert (os.getenv "AUTH0_SECRET"),
    api_token     = assert (os.getenv "AUTH0_TOKEN" ),
  },
  docker      = {
    username = assert (os.getenv "DOCKER_USER"  ),
    api_key  = assert (os.getenv "DOCKER_SECRET"),
  },
}

local identities = {
  rahan  = "github|1818862",
  crao   = "google-oauth2|103410538451613086005",
  naouna = "twitter|2572672862",
}

local function make_token (subject, contents, duration)
  local claims = {
    iss = Config.auth0.domain,
    aud = Config.auth0.client_id,
    sub = subject,
    exp = duration and duration ~= math.huge and Time () + duration,
    iat = Time (),
    contents = contents,
  }
  return Jwt.encode (claims, {
    alg = "HS256",
    keys = { private = Config.auth0.client_secret },
  })
end

describe ("editor", function ()

  local instance, server_url

  setup (function ()
    instance   = Instance.create ()
    server_url = instance.server
  end)

  teardown (function ()
    while true do
      local info, status = Http.json {
        url    = server_url,
        method = "GET",
      }
      assert.are.equal (status, 200)
      if info.stats.services == 0 then
        break
      end
      os.execute [[ sleep 1 ]]
    end
  end)

  teardown (function ()
    instance:delete ()
  end)

  local project, resource, project_url, resource_url

  before_each (function ()
    local token = make_token (identities.rahan)
    local result, status = Http.json {
      url     = server_url .. "/projects",
      method  = "POST",
      headers = {
        Authorization = "Bearer " .. token,
      },
    }
    assert.are.same (status, 201)
    project = result.id
    project_url = server_url .. "/projects/" .. project
    result, status = Http.json {
      url     = project_url .. "/resources",
      method  = "POST",
      headers = {
        Authorization = "Bearer " .. token,
      },
    }
    assert.are.same (status, 201)
    resource = result.id
    resource_url = project_url .. "/resources/" .. resource
  end)

  it ("can be required", function ()
    assert.has.no.errors (function ()
      require "cosy.editor"
    end)
  end)

  it ("can be instantiated", function ()
    assert.has.no.errors (function ()
      local Editor = require "cosy.editor"
      Editor.create {
        api      = server_url,
        port     = 0,
        project  = project,
        resource = resource,
        timeout  = 60,
        token    = make_token (Et.render ("/projects/<%- project %>", {
          project  = project,
        }), {}, math.huge),
      }
    end)
  end)

  it ("cannot start without resource", function ()
    local Editor = require "cosy.editor"
    local token  = make_token (identities.rahan)
    local _, status = Http.json {
      url     = resource_url,
      method  = "DELETE",
      headers = {
        Authorization = "Bearer " .. token,
      },
    }
    assert.are.same (status, 204)
    local editor = Editor.create {
      api      = server_url,
      port     = 0,
      project  = project,
      resource = resource,
      timeout  = 60,
      token    = make_token (Et.render ("/projects/<%- project %>", {
        project  = project,
      }), {}, math.huge),
    }
    assert.has.errors (function ()
      editor:start ()
    end)
  end)

  it ("can be started and stopped", function ()
    local Editor = require "cosy.editor"
    local editor = Editor.create {
      api      = server_url,
      port     = 0,
      project  = project,
      resource = resource,
      timeout  = 60,
      token    = make_token (Et.render ("/projects/<%- project %>", {
        project  = project,
      }), {}, math.huge),
    }
    editor:start ()
    Copas.addthread (function ()
      Copas.sleep (1)
      assert (editor.host)
      assert (editor.port)
      editor:stop ()
    end)
    Copas.loop ()
  end)

end)
