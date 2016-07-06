local Arguments = require "argparse"
local Editor    = require "cosy.editor"
local Url       = require "socket.url"

local parser = Arguments () {
  name        = "cosy-editor",
  description = "collaborative editor for cosy models",
}
parser:option "--port" {
  description = "port",
  default     = "0",
  convert     = tonumber,
}
parser:option "--port" {
  description = "port",
  default     = "0",
  convert     = tonumber,
}
parser:option "--timeout" {
  description = "timeout before closing the editor (in seconds)",
  default     = "60",
  convert     = tonumber,
}
parser:argument "resource" {
  description = "resource URL",
  convert     = function (x)
    local parsed = Url.parse (x)
    return parsed.host and x or nil, x .. "is not a valid URL"
  end,
}
parser:argument "token" {
  description = "resource token",
}

local arguments = parser:parse ()
local editor    = Editor.create (arguments)
editor:start ()
