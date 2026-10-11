---@module 'luassert'

local Config = require("sidekick.config")
local Procs = require("sidekick.cli.procs")
local Session = require("sidekick.cli.session")
local Util = require("sidekick.util")

describe("CLI discovery", function()
  local original = {}

  before_each(function()
    original = {
      exec = Util.exec,
      system = vim.system,
      new = Procs.new,
      tools = Config.tools,
      backends = Session.backends,
      did_setup = Session.did_setup,
      setup = Session.setup,
      attached = Session._attached,
      backend_methods = {},
    }
  end)

  after_each(function()
    Util.exec = original.exec
    vim.system = original.system
    Procs.new = original.new
    Config.tools = original.tools
    Session.backends = original.backends
    Session.did_setup = original.did_setup
    Session.setup = original.setup
    Session._attached = original.attached
    for backend, methods in pairs(original.backend_methods) do
      backend.panes, backend.clients = methods.panes, methods.clients
    end
  end)

  it("does not run ps when Linux process environment is readable", function()
    if not vim.uv.fs_stat("/proc/self/environ") then
      return
    end
    Util.exec = function()
      error("unexpected ps fallback")
    end
    assert.are.same("table", type(Procs.env(vim.fn.getpid())))
  end)

  it("batches WezTerm tty lookups and keeps panes with known PIDs", function()
    local calls = {}
    Util.exec = function(cmd)
      calls[#calls + 1] = cmd
      if cmd[1] == "wezterm" then
        return {},
          vim.json.encode({
            { pane_id = 1, tab_id = 1, window_id = 1, tty_name = "/dev/pts/1" },
            { pane_id = 2, tab_id = 1, window_id = 1, tty_name = "/dev/pts/2" },
            { pane_id = 3, tab_id = 1, window_id = 1, pid = 30, tty_name = "/dev/pts/3" },
          })
      end
      return { "p10", "n/dev/pts/1", "p20", "n/dev/pts/2", "p21", "n/dev/pts/2" }
    end
    local panes = require("sidekick.cli.session.wezterm").panes()
    assert.are.same({ "lsof", "-Fpn", "/dev/pts/1", "/dev/pts/2" }, calls[2])
    assert.are.same(2, #calls)
    assert.are.same({ 10, 20, 30 }, { panes[1].pid, panes[2].pid, panes[3].pid })
  end)

  it("keeps resolved WezTerm PIDs when lsof can't resolve every tty", function()
    vim.system = function(cmd)
      local result = { code = 1, stdout = "p10\nf0\nn/dev/pts/1\n", stderr = "lsof: status error on /dev/pts/2" }
      if cmd[1] == "wezterm" then
        result = {
          code = 0,
          stdout = vim.json.encode({
            { pane_id = 1, tab_id = 1, window_id = 1, tty_name = "/dev/pts/1" },
            { pane_id = 2, tab_id = 1, window_id = 1, tty_name = "/dev/pts/2" },
            { pane_id = 3, tab_id = 1, window_id = 1, tty_name = vim.NIL },
          }),
        }
      end
      return {
        wait = function()
          return result
        end,
      }
    end
    local panes = require("sidekick.cli.session.wezterm").panes()
    assert.are.same(3, #panes)
    assert.are.same(10, panes[1].pid)
    assert.are.same(nil, panes[2].pid)
    assert.are.same(nil, panes[3].pid)
  end)

  for _, name in ipairs({ "tmux", "wezterm", "herdr" }) do
    it("skips process discovery without " .. name .. " panes", function()
      Util.exec = function()
        return {}, name == "herdr" and '{"result":{"panes":[]}}' or "[]"
      end
      Procs.new = function()
        error("unexpected process scan")
      end
      assert.are.same({}, require("sidekick.cli.session." .. name).sessions())
    end)
  end

  for _, name in ipairs({ "tmux", "wezterm", "herdr" }) do
    it("passes the shared context to the " .. name .. " backend", function()
      local backend = require("sidekick.cli.session." .. name)
      original.backend_methods[backend] = { panes = backend.panes, clients = backend.clients }
      backend.panes = function()
        return { { pid = 1 } }
      end
      backend.clients = function()
        return {}
      end
      Procs.new = function()
        error("unexpected additional process scan")
      end
      local ctx = {
        tools = {},
        procs = {
          walk = function() end,
          list = function()
            return {}
          end,
        },
      }
      assert.are.same({}, backend:sessions(ctx))
    end)
  end

  it("shares process snapshots and tools within synchronous discovery", function()
    local scans, loads, snapshots = 0, 0, {}
    Procs.new = function()
      scans = scans + 1
      return {}
    end
    Config.tools = function()
      loads = loads + 1
      return {}
    end
    local backend = {
      sessions = function(_, ctx)
        snapshots[#snapshots + 1] = ctx.procs
        return {}
      end,
    }
    Session.did_setup, Session.backends, Session._attached = true, { a = backend, b = backend }, {}
    Session.sessions()
    assert.are.same(1, scans)
    assert.are.same(1, loads)
    assert.is_true(snapshots[1] == snapshots[2])
    Session.sessions()
    assert.are.same(2, scans) -- a new request must see new processes
  end)

  it("runs backend commands concurrently and coalesces pending requests", function()
    local pending, scans, callbacks = {}, 0, 0
    Procs.new = function()
      scans = scans + 1
      return {}
    end
    Config.tools = function()
      return {}
    end
    vim.system = function(cmd, opts, cb)
      assert.is_not_nil(cb)
      assert.are.same(3000, opts.timeout)
      pending[#pending + 1] = cb
      return {}
    end
    local backend = {
      sessions = function()
        Util.exec({ "discovery" }, { notify = false })
        return {}
      end,
    }
    Session.did_setup, Session.backends, Session._attached = true, { a = backend, b = backend }, {}
    local function done(sessions, err)
      assert.are.same(nil, err)
      assert.are.same({}, sessions)
      callbacks = callbacks + 1
    end
    Session.sessions_async(done)
    Session.sessions_async(done)
    assert.are.same(2, #pending) -- both commands started before either finished
    assert.are.same(0, callbacks)
    pending[2]({ code = 0, stdout = "" })
    pending[1]({ code = 0, stdout = "" })
    assert.is_true(vim.wait(1000, function()
      return callbacks == 2
    end))
    assert.are.same(1, scans)
  end)

  it("reports asynchronous backend errors and permits retry", function()
    Procs.new = function()
      return {}
    end
    Config.tools = function()
      return {}
    end
    Session.did_setup, Session.backends, Session._attached =
      true, {
        broken = {
          sessions = function()
            error("discovery failed")
          end,
        },
      }, {}
    local complete = false
    Session.sessions_async(function(sessions, err)
      assert.are.same(nil, sessions)
      assert.is_true(err:find("discovery failed", 1, true) ~= nil)
      complete = true
    end)
    assert.is_true(vim.wait(1000, function()
      return complete
    end))
    Session.backends = {}
    complete = false
    Session.sessions_async(function(sessions, err)
      assert.are.same({}, sessions)
      assert.are.same(nil, err)
      complete = true
    end)
    assert.is_true(vim.wait(1000, function()
      return complete
    end))
  end)

  ---@param id string
  ---@param detached string[]
  local function attached(id, detached)
    return {
      id = id,
      tool = { name = id },
      detach = function()
        detached[#detached + 1] = id
      end,
      is_running = function()
        return true
      end,
    }
  end

  -- a backend that finds no sessions, after running one command
  local function discover()
    Procs.new = function()
      return {}
    end
    Config.tools = function()
      return {}
    end
    Session.did_setup = true
    Session.backends = {
      a = {
        sessions = function()
          Util.exec({ "discovery" }, { notify = false })
          return {}
        end,
      },
    }
  end

  it("only detaches sessions that were attached when discovery started", function()
    local pending, detached = {}, {}
    discover()
    vim.system = function(_, _, cb)
      pending[#pending + 1] = cb
      return {}
    end
    Session._attached = { gone = attached("gone", detached) }
    local complete = false
    Session.sessions_async(function(_, err)
      assert.are.same(nil, err)
      complete = true
    end)
    Session._attached.new = attached("new", detached) -- started after the snapshot
    pending[1]({ code = 0, stdout = "" })
    assert.is_true(vim.wait(1000, function()
      return complete
    end))
    assert.are.same({ "gone" }, detached)
    assert.are.same({ "new" }, vim.tbl_keys(Session._attached))
  end)

  it("reports timed out commands instead of treating them as no sessions", function()
    local detached = {}
    discover()
    vim.system = function(_, _, cb)
      cb({ code = 124, signal = 15, stdout = "" })
      return {}
    end
    Session._attached = { running = attached("running", detached) }
    local complete = false
    Session.sessions_async(function(sessions, err)
      assert.are.same(nil, sessions)
      assert.is_true(err:find("Command timed out: `discovery`", 1, true) ~= nil)
      complete = true
    end)
    assert.is_true(vim.wait(1000, function()
      return complete
    end))
    assert.are.same({}, detached)
    assert.are.same({ "running" }, vim.tbl_keys(Session._attached))
  end)

  it("permits discovery after a failed setup", function()
    discover()
    Session._attached = {}
    Session.setup = function()
      error("setup failed")
    end
    assert.is_false(pcall(Session.sessions_async, function() end))
    Session.setup = original.setup
    vim.system = function(_, _, cb)
      cb({ code = 0, stdout = "" })
      return {}
    end
    local complete = false
    Session.sessions_async(function(sessions, err)
      assert.are.same({}, sessions)
      assert.are.same(nil, err)
      complete = true
    end)
    assert.is_true(vim.wait(1000, function()
      return complete
    end))
  end)
end)
