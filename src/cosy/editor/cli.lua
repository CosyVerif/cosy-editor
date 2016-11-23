local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local Arguments = require "argparse"
local Copas     = require "copas"
local Url       = require "socket.url"
local Editor    = require "cosy.editor"

local parser = Arguments () {
  name        = "cosy-editor",
  description = "collaborative editor for cosy models",
}
parser:option "--resource" {
  description = "resource url",
  convert     = function (x)
    local url = Url.parse (x)
    if not url.scheme or not url.host then
      error "invalid url"
    end
    return x
  end,
}
parser:option "--token" {
  description = "project token",
}
parser:option "--port" {
  description = "port",
  default     = "8080",
  convert     = tonumber,
}
parser:option "--timeout" {
  description = "timeout before stopping (in seconds)",
  default     = "1",
  convert     = tonumber,
}

local arguments = parser:parse ()
if not arguments.resource
or not arguments.token
or not arguments.port
or not arguments.timeout then
  print (parser:get_help ())
  return 1
end
local editor    = Editor.create (arguments)
editor:start ()
Copas.loop ()
