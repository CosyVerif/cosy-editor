local assert = require "luassert"
local Copas  = require "copas"

describe ("editor", function ()

  it ("can be required", function ()
    assert.has.no.errors (function ()
      require "cosy.editor"
    end)
  end)

  it ("can be instantiated", function ()
    assert.has.no.errors (function ()
      local Editor = require "cosy.editor"
      Editor.create {
        port     = 0,
        token    = "...",
        timeout  = 10,
        resource = "...",
      }
    end)
  end)

  it ("cannot start without resource", function ()
    local Editor = require "cosy.editor"
    local editor = Editor.create {
      port     = 0,
      token    = "...",
      timeout  = 10,
      resource = "...",
    }
    assert.has.errors (function ()
      editor:start ()
    end)
  end)

  it ("can be started and stopped", function ()
    local Editor = require "cosy.editor"
    local editor = Editor.create {
      port     = 0,
      token    = "...",
      timeout  = 10,
      resource = "...",
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
