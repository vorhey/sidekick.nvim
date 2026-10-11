---@module 'luassert'

local Installed = require("sidekick.cli.installed")

describe("CLI installation discovery", function()
  local path, home, root

  before_each(function()
    path, home = vim.env.PATH, vim.env.HOME
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
  end)

  after_each(function()
    vim.env.PATH, vim.env.HOME = path, home
    vim.fn.delete(root, "rf")
  end)

  it("matches executable checks for PATH, explicit paths, and missing commands", function()
    if vim.fn.has("win32") == 1 then
      return
    end
    vim.fn.writefile({ "#!/bin/sh", "exit 0" }, root .. "/available")
    vim.uv.fs_chmod(root .. "/available", 493)
    vim.fn.writefile({ "not executable" }, root .. "/plain")
    vim.uv.fs_chmod(root .. "/plain", 420)
    vim.fn.mkdir(root .. "/directory")
    vim.env.PATH = root .. ":" .. root -- duplicate PATH entries
    vim.env.HOME = root
    local tools = {
      available = { cmd = { "available" } },
      alias = { cmd = { "available" } },
      explicit = { cmd = { root .. "/available" } },
      home = { cmd = { "~/available" } }, -- not expanded, since it's not run in a shell
      missing = { cmd = { "missing" } },
      plain = { cmd = { "plain" } },
      directory = { cmd = { "directory" } },
    }
    local result
    Installed.get(tools, function(ret)
      result = ret
    end)
    assert.are.same(nil, result)
    assert.is_true(vim.wait(1000, function()
      return result ~= nil
    end))
    for name, tool in pairs(tools) do
      assert.are.same(vim.fn.executable(tool.cmd[1]) == 1, result[name])
    end
  end)

  it("refreshes missing commands when they are installed", function()
    if vim.fn.has("win32") == 1 then
      return
    end
    vim.env.PATH = root
    local tools = { tool = { cmd = { "new-tool" } } }
    local function check()
      local result
      Installed.get(tools, function(ret)
        result = ret
      end)
      assert.is_true(vim.wait(1000, function()
        return result ~= nil
      end))
      return result.tool
    end
    assert.is_false(check())
    vim.fn.writefile({ "#!/bin/sh" }, root .. "/new-tool")
    vim.uv.fs_chmod(root .. "/new-tool", 493)
    assert.is_true(check())
  end)
end)

describe("asynchronous CLI selector", function()
  local Select = require("sidekick.cli.ui.select")
  local Session = require("sidekick.cli.session")
  local State = require("sidekick.cli.state")
  local original
  local installed, sessions, pickers ---@type {tools:table, cb:fun(result:table)}[], fun(result:table)[], table[]

  before_each(function()
    original = {
      installed = Installed.get,
      sessions = Session.sessions_async,
      state = State.get,
      select = vim.ui.select,
      executable = vim.fn.executable,
    }
    installed, sessions, pickers = {}, {}, {}
    Installed.get = function(tools, cb)
      installed[#installed + 1] = { tools = tools, cb = cb }
    end
    Session.sessions_async = function(cb)
      sessions[#sessions + 1] = cb
    end
    vim.ui.select = function(items)
      pickers[#pickers + 1] = items
    end
  end)

  after_each(function()
    Installed.get = original.installed
    Session.sessions_async = original.sessions
    State.get = original.state
    vim.ui.select = original.select
    vim.fn.executable = original.executable
  end)

  it("waits for both results and only opens the picker of the latest request", function()
    State.get = function(filter, discovered, available)
      assert.are.same({ "sessions" }, discovered)
      assert.are.same({ tool = true }, available)
      return { filter.session, "other" }
    end
    Select.select({ filter = { session = "first" }, cb = function() end })
    Select.select({ filter = { session = "second" }, cb = function() end })
    installed[1].cb({ tool = true })
    sessions[1]({ "sessions" })
    sessions[2]({ "sessions" })
    assert.is_false(vim.wait(50, function()
      return #pickers > 0
    end))
    installed[2].cb({ tool = true })
    assert.is_true(vim.wait(1000, function()
      return #pickers > 0
    end))
    assert.are.same({ { "second", "other" } }, pickers)
  end)

  it("completes superseded automatic requests in call order", function()
    local selected = {} ---@type string[]
    State.get = function(filter)
      return { { installed = true, tool = filter.session } }
    end
    for _, id in ipairs({ "first", "second" }) do
      Select.select({
        auto = true,
        filter = { session = id },
        cb = function(state)
          selected[#selected + 1] = state.tool
        end,
      })
    end
    sessions[1]({})
    sessions[2]({})
    installed[2].cb({})
    assert.is_false(vim.wait(50, function()
      return #selected > 0
    end))
    installed[1].cb({})
    assert.is_true(vim.wait(1000, function()
      return #selected == 2
    end))
    assert.are.same({ "first", "second" }, selected)
    assert.are.same({}, pickers)
  end)

  it("only checks the tool of a name filter", function()
    Select.select({ filter = { name = "claude" }, cb = function() end })
    Select.select({ cb = function() end })
    assert.are.same({ "claude" }, vim.tbl_keys(installed[1].tools))
    assert.is_true(vim.tbl_count(installed[2].tools) > 1)
    assert.is_not_nil(installed[2].tools.claude)
  end)

  it("uses the provided sessions and installation results", function()
    vim.fn.executable = function()
      error("unexpected executable check")
    end
    for _, found in ipairs({ true, false }) do
      local states = State.get({ name = "claude" }, {}, { claude = found or nil })
      assert.are.same(1, #states)
      assert.are.same(found, states[1].installed)
    end
  end)
end)
