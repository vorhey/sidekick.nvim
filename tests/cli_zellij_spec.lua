---@module 'luassert'

local Config = require("sidekick.config")
local Procs = require("sidekick.cli.procs")
local Util = require("sidekick.util")
local Zellij = require("sidekick.cli.session.zellij")

describe("Zellij tabs", function()
  local original, calls

  local function session(opts)
    return setmetatable(
      vim.tbl_extend("force", {
        sid = "test-session",
        cwd = "/project with spaces",
        tool = { name = "test", cmd = { "test-cli", "argument with spaces" } },
      }, opts or {}),
      Zellij
    )
  end

  before_each(function()
    original = {
      exec = Util.exec,
      info = Util.info,
      state = Util.get_state,
      tools = Config.tools,
      new = Procs.new,
      mux = vim.deepcopy(Config.cli.mux),
      zellij = vim.env.ZELLIJ,
      session = vim.env.ZELLIJ_SESSION_NAME,
      defer = vim.defer_fn,
    }
    calls = {}
    Util.info = function() end
    Util.get_state = function() end
    vim.env.ZELLIJ, vim.env.ZELLIJ_SESSION_NAME = "0", "work"
    Util.exec = function(cmd)
      calls[#calls + 1] = cmd
      if cmd[2] == "--version" then
        return { "zellij 0.45.1" }, "zellij 0.45.1\n"
      elseif cmd[5] == "new-tab" then
        return { "7" }, "7\n"
      elseif cmd[5] == "list-panes" then
        return {},
          vim.json.encode({
            { id = 1, tab_id = 0, is_plugin = false },
            { id = 2, tab_id = 7, is_plugin = true },
            { id = 3, tab_id = 7, is_plugin = false, pane_cwd = "/project" },
          })
      elseif cmd[2] == "list-sessions" then
        return { "work" }
      end
      return {}
    end
  end)

  after_each(function()
    Util.exec, Util.info, Util.get_state = original.exec, original.info, original.state
    Config.tools, Procs.new = original.tools, original.new
    Config.cli.mux = original.mux
    vim.env.ZELLIJ, vim.env.ZELLIJ_SESSION_NAME = original.zellij, original.session
    vim.defer_fn = original.defer
  end)

  it("creates a single-pane tab without stealing focus and targets its terminal", function()
    Config.cli.mux.create = "window"
    local s = session()
    s.tool.env = { REMOVE = false, SET = "value with spaces" }
    s:init()
    assert.is_true(s.external)
    assert.is_nil(s:start())
    assert.are.same({
      "zellij",
      "--session",
      "work",
      "action",
      "new-tab",
      "--name",
      "test",
      "--cwd",
      "/project with spaces",
      "--no-focus",
      "--close-on-exit",
      "--layout-string",
      "layout { pane; }",
      "--",
      "env",
      "-u",
      "REMOVE",
      "SET=value with spaces",
      "test-cli",
      "argument with spaces",
    }, calls[2])
    assert.are.same("terminal_3", s.zellij_pane_id)
    assert.are.same("zellij: work:terminal_3", s.id)
    assert.is_true(s:is_running())
    s:send("-context\nsecond line")
    s:submit()
    assert.are.same(
      { "zellij", "--session", "work", "action", "paste", "--pane-id", "terminal_3", "--", "-context\nsecond line" },
      calls[#calls - 1]
    )
    assert.are.same(
      { "zellij", "--session", "work", "action", "send-keys", "--pane-id", "terminal_3", "Enter" },
      calls[#calls]
    )
  end)

  it("waits for the terminal pane after Zellij returns the new tab ID", function()
    Config.cli.mux.create = "window"
    local exec, queries = Util.exec, 0
    Util.exec = function(cmd)
      if cmd[5] == "list-panes" then
        queries = queries + 1
        if queries == 1 then
          return {}, "[]"
        end
      end
      return exec(cmd)
    end
    local s = session()
    s:init()
    s:start()
    assert.are.same(2, queries)
    assert.are.same("terminal_3", s.zellij_pane_id)
  end)

  it("preserves embedded discovery without duplicating it as an external tab", function()
    Util.get_state = function(name)
      if name == "work" then
        return { tool = "test", cwd = "/project" }
      end
    end
    local found =
      Zellij.sessions(nil, { tools = {}, procs = {
        list = function()
          return {}
        end,
      } })
    assert.are.same(1, #found)
    assert.are.same("zellij: work", found[1].id)
    assert.are.same(nil, found[1].zellij_pane_id)
    local s = session(vim.tbl_extend("force", found[1], { started = true }))
    s:init()
    assert.is_false(s.external)
    assert.are.same(1, #calls) -- only list-sessions
  end)

  it("sends focus events before text for tools that need them", function()
    local s = session({ mux_session = "work", zellij_pane_id = "terminal_3" })
    s.tool.mux_focus = true
    local deferred
    vim.defer_fn = function(fn)
      deferred = fn
    end
    s:send("hello")
    assert.are.same(
      { "zellij", "--session", "work", "action", "write", "--pane-id", "terminal_3", "27", "91", "73" },
      calls[1]
    )
    assert.are.same(1, #calls)
    deferred()
    assert.are.same("paste", calls[2][5])
  end)

  for _, case in ipairs({
    { create = "terminal", inside = true },
    { create = "window", inside = false },
  }) do
    it("keeps embedded sessions for " .. case.create .. " inside=" .. tostring(case.inside), function()
      Config.cli.mux.create = case.create
      vim.env.ZELLIJ = case.inside and "0" or nil
      local s = session()
      s:init()
      assert.is_false(s.external)
      assert.are.same(s.sid, s.mux_session)
    end)
  end

  it("attaches to discovered tabs without spawning an embedded session", function()
    local s = session({ started = true, mux_session = "work", zellij_pane_id = "terminal_3" })
    s:init()
    assert.is_true(s.external)
    assert.is_nil(s:attach())
    assert.are.same({}, calls)
  end)

  it("discovers running tools once per live pane using the shared process snapshot", function()
    local tool = {
      is_proc = function(_, proc)
        return proc.cmd == "test-cli"
      end,
    }
    local processes = {
      { pid = 10, cmd = "test-cli", env = { ZELLIJ_SESSION_NAME = "work", ZELLIJ_PANE_ID = "3" }, cwd = "/project" },
      { pid = 11, cmd = "test-cli", env = { ZELLIJ_SESSION_NAME = "work", ZELLIJ_PANE_ID = "3" } },
      { pid = 12, cmd = "test-cli", env = { ZELLIJ_SESSION_NAME = "work", ZELLIJ_PANE_ID = "99" } },
      { pid = 13, cmd = "test-cli", env = {} },
    }
    Procs.new = function()
      error("unexpected process scan")
    end
    local found = Zellij.sessions(nil, {
      tools = { tool },
      procs = {
        list = function()
          return processes
        end,
        pids = function(_, pid)
          return { pid, 11 }
        end,
      },
    })
    assert.are.same(1, #found)
    assert.are.same("zellij: work:terminal_3", found[1].id)
    assert.are.same(10, found[1].zellij_pid)
    assert.are.same({ 10, 11 }, found[1].pids)
    assert.are.same(2, #calls) -- sessions + one pane listing
  end)

  it("rejects older versions before creating a tab", function()
    Config.cli.mux.create = "window"
    Util.exec = function()
      return {}, "zellij 0.43.1"
    end
    local s = session()
    s:init()
    local ok, err = pcall(s.start, s)
    assert.is_false(ok)
    assert.is_true(err:find("0.45.1 or newer", 1, true) ~= nil)
    assert.are.same(nil, s.started)
  end)

  it("does not mark failed tab creation as started", function()
    Config.cli.mux.create = "window"
    local exec = Util.exec
    Util.exec = function(cmd)
      if cmd[5] == "new-tab" then
        return nil
      end
      return exec(cmd)
    end
    local s = session()
    s:init()
    assert.is_false(pcall(s.start, s))
    assert.are.same(nil, s.started)
  end)
end)
