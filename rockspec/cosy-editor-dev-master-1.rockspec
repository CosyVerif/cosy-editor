package = "cosy-editor-dev"
version = "master-1"
source  = {
  url = "git://github.com/saucisson/cosy-editor",
}

description = {
  summary    = "CosyVerif: editor (dev dependencies)",
  detailed   = [[
    Development dependencies for cosy-editor.
  ]],
  homepage   = "http://www.cosyverif.org/",
  license    = "MIT/X11",
  maintainer = "Alban Linard <alban@linard.fr>",
}

dependencies = {
  "lua >= 5.1",
  "argparse",
  "ansicolors",
  "busted",
  "copas",
  "cluacov",
  "etlua",
  "lua-websockets",
  "luacheck",
  "luacov",
  "luacov-coveralls",
  "luafilesystem",
}

build = {
  type    = "builtin",
  modules = {
    ["cosy.editor.check.cli"] = "src/cosy/editor/check/cli.lua",
  },
  install = {
    bin = {
      ["cosy-check-editor" ] = "src/cosy/editor/check/bin.lua",
    },
  },
}
