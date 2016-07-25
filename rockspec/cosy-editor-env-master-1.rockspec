package = "cosy-editor-env"
version = "master-1"
source  = {
  url = "git+https://github.com/cosyverif/editor.git",
}

description = {
  summary    = "Development environment for cosy-editor",
  detailed   = [[]],
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
  "hashids",
  "jwt",
  "luacheck",
  "luacov",
  "luacov-coveralls",
  "luafilesystem",
  "luasocket",
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
