local assert  = require "luassert"
local Copas   = require "copas"
local Mime    = require "mime"
local Http    = require "cosy.editor.http"
local Et      = require "etlua"
local Hashids = require "hashids"
local Json    = require "cjson"
local Jwt     = require "jwt"
local Time    = require "socket".gettime

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


local branch
do
  local file = assert (io.popen ("git rev-parse --abbrev-ref HEAD", "r"))
  branch = assert (file:read "*line")
  file:close ()
end

describe ("editor", function ()

  local server_url, docker_url
  local headers = {
    ["Authorization"] = "Basic " .. Mime.b64 (Config.docker.username .. ":" .. Config.docker.api_key),
    ["Accept"       ] = "application/json",
    ["Content-type" ] = "application/json",
  }

  setup (function ()
    local url = "https://cloud.docker.com"
    local api = url .. "/api/app/v1"
    -- Create service:
    local id  = Hashids.new (tostring (os.time ())):encode (666)
    local stack, stack_status = Http.request {
      url     = api .. "/stack/",
      method  = "POST",
      headers = headers,
      body    = {
        name     = id,
        services = {
          { name  = "database",
            image = "postgres",
          },
          { name  = "api",
            image = Et.render ("cosyverif/server:<%- branch %>", {
              branch = branch,
            }),
            ports = {
              "8080",
            },
            links = {
              "database",
            },
            environment = {
              COSY_PREFIX       = "/usr/local",
              COSY_HOST         = "api:8080",
              POSTGRES_HOST     = "database",
              POSTGRES_USER     = "postgres",
              POSTGRES_PASSWORD = "",
              POSTGRES_DATABASE = "postgres",
              AUTH0_DOMAIN      = Config.auth0.domain,
              AUTH0_ID          = Config.auth0.client_id,
              AUTH0_SECRET      = Config.auth0.client_secret,
              AUTH0_TOKEN       = Config.auth0.api_token,
              DOCKER_USER       = Config.docker.username,
              DOCKER_SECRET     = Config.docker.api_key,
            },
          },
        },
      },
    }
    assert (stack_status == 201)
    -- Start service:
    local resource = url .. stack.resource_uri
    local _, started_status = Http.request {
      url        = resource .. "start/",
      method     = "POST",
      headers    = headers,
      timeout    = 5, -- seconds
    }
    assert (started_status == 202)
    local services
    repeat -- wait until it started
      if _G.ngx and _G.ngx.sleep then
        _G.ngx.sleep (1)
      else
        os.execute "sleep 1"
      end
      local result, status = Http.request {
        url     = resource,
        method  = "GET",
        headers = headers,
      }
      assert (status == 200)
      services = result.services
    until result.state:lower () == "running"
    for _, path in ipairs (services) do
      local service, service_status = Http.request {
        url     = url .. path,
        method  = "GET",
        headers = headers,
      }
      assert (service_status == 200)
      if service.name == "api" then
        local container, container_status = Http.request {
          url     = url .. service.containers [1],
          method  = "GET",
          headers = headers,
        }
        assert (container_status == 200)
        docker_url = resource
        for _, port in ipairs (container.container_ports) do
          local endpoint = port.endpoint_uri
          if endpoint and endpoint ~= Json.null then
            server_url = endpoint
            print ("server url", server_url)
            print ("docker url", docker_url)
            return
          end
        end
      end
    end
    assert (false)
  end)

  teardown (function ()
    local _, stopped_status = Http.request {
      url     = docker_url .. "/stop",
      method  = "POST",
      headers = headers,
    }
    assert (stopped_status == 202)
    local _, deleted_status = Http.request {
      url     = docker_url,
      method  = "DELETE",
      headers = headers,
    }
    assert (deleted_status == 202)
  end)

  local project, resource, project_url, resource_url

  before_each (function ()
    local token = make_token (identities.rahan)
    local status, result = Http.request {
      url     = server_url .. "/projects",
      method  = "POST",
      headers = {
        Authorization = "Bearer " .. token,
      },
    }
    assert.are.same (status, 201)
    project = result.id
    project_url = server_url .. "/projects/" .. project
    status, result = Http.request {
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
