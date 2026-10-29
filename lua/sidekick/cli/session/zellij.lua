local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Zellij: sidekick.cli.Session
---@field zellij_pane_id string
---@field zellij_pid? number
---@field zellij_tab_id? number
local M = {}
M.__index = M
M.priority = 50
M.external = false

M.tpl = [[
layout {
    pane command="{cmd}" {
      borderless true
      focus true
      name "{name}"
      close_on_exit true
      {args}
   }
}
session_serialization false
]]

---@return sidekick.cli.terminal.Cmd?
function M:terminal()
  local layout = M.tpl
  layout = layout:gsub("{cmd}", self.tool.cmd[1])
  layout = layout:gsub("{name}", self.tool.name)
  if #self.tool.cmd == 1 then
    layout = layout:gsub("{args}", "")
  else
    local args = vim.list_slice(self.tool.cmd, 2)
    layout = layout:gsub("{args}", "args " .. table.concat(
      vim.tbl_map(function(a)
        return ("%q"):format(a)
      end, args),
      " "
    )) --[[@as string]]
  end

  local session = self.sid

  local layout_file = Config.state("zellij-layout-" .. session .. ".kdl")
  vim.fn.writefile(vim.split(layout, "\n"), layout_file)
  Util.set_state(session, { tool = self.tool.name, cwd = self.cwd })

  return {
    cmd = { "zellij", "--layout", layout_file, "attach", "--create", session },
    env = {
      ZELLIJ = false,
      ZELLIJ_SESSION_NAME = false,
      ZELLIJ_PANE_ID = false,
    },
  }
end

function M:init()
  if self.started then
    self.external = self.zellij_pane_id ~= nil
  else
    self.external = vim.env.ZELLIJ ~= nil and Config.cli.mux.create == "window"
    self.mux_session = self.external and vim.env.ZELLIJ_SESSION_NAME or self.sid
  end
  self.priority = self.external and 10 or 50
end

---@param session string
---@param args string[]
---@param opts? table
local function action(session, args, opts)
  local cmd = { "zellij", "--session", session, "action" }
  vim.list_extend(cmd, args)
  return Util.exec(cmd, opts)
end

---@param session string
---@return table[]
function M.panes(session)
  local _, output = action(session, { "list-panes", "--json" }, { notify = false })
  local ok, panes = pcall(vim.json.decode, output or "")
  return ok and type(panes) == "table" and panes or {}
end

---@return sidekick.cli.terminal.Cmd?
function M:start()
  if not self.external then
    if vim.env.ZELLIJ and Config.cli.mux.create == "split" then
      Util.warn("Zellij supports `cli.mux.create = window` or `terminal`. Falling back to `terminal`.")
    end
    return self:terminal()
  end
  local _, version = Util.exec({ "zellij", "--version" }, { notify = false })
  local parsed = vim.version.parse(version or "")
  assert(parsed and vim.version.ge(parsed, { 0, 45, 1 }), "Zellij tabs require Zellij 0.45.1 or newer")

  local cmd = {
    "new-tab",
    "--name",
    self.tool.name,
    "--cwd",
    self.cwd,
    "--no-focus",
    "--close-on-exit",
    "--layout-string",
    "layout { pane; }",
    "--",
    "env",
  }
  for key, value in pairs(self.tool.env or {}) do
    if value == false then
      vim.list_extend(cmd, { "-u", key })
    end
  end
  for key, value in pairs(self.tool.env or {}) do
    if value ~= false then
      cmd[#cmd + 1] = ("%s=%s"):format(key, tostring(value))
    end
  end
  vim.list_extend(cmd, self.tool.cmd)
  local lines = action(self.mux_session, cmd)
  local tab_id = lines and tonumber(lines[1])
  assert(tab_id, "Failed to create Zellij tab")
  -- new-tab returns before its terminal pane is necessarily visible to queries.
  local found
  vim.wait(2000, function()
    for _, pane in ipairs(M.panes(self.mux_session)) do
      if pane.tab_id == tab_id and not pane.is_plugin then
        found = pane
        return true
      end
    end
    return false
  end, 20)
  assert(found, "Could not find the terminal pane in the new Zellij tab")
  self.zellij_tab_id = tab_id
  self.zellij_pane_id = "terminal_" .. found.id
  self.id = "zellij: " .. self.mux_session .. ":" .. self.zellij_pane_id
  self.started = true
  Util.info(("Started **%s** in a new Zellij tab"):format(self.tool.name))
end

---@return sidekick.cli.terminal.Cmd?
function M:attach()
  if not self.external then
    return self:terminal()
  end
end

function M:is_running()
  if self.zellij_pid then
    return vim.api.nvim_get_proc(self.zellij_pid) ~= nil
  end
  for _, pane in ipairs(M.panes(self.mux_session)) do
    if "terminal_" .. pane.id == self.zellij_pane_id and not pane.is_plugin and not pane.exited then
      return true
    end
  end
  return false
end

function M:send(text)
  local function send()
    action(self.mux_session, { "paste", "--pane-id", self.zellij_pane_id, "--", text })
  end
  if self.tool.mux_focus then
    -- Send a focus-in event without changing the user's active tab.
    action(self.mux_session, { "write", "--pane-id", self.zellij_pane_id, "27", "91", "73" })
    vim.defer_fn(send, 50)
  else
    send()
  end
end

function M:submit()
  action(self.mux_session, { "send-keys", "--pane-id", self.zellij_pane_id, "Enter" })
end

function M.sessions(_, ctx)
  local sessions = Util.exec({ "zellij", "list-sessions", "-ns" }, { notify = false }) or {}
  local ret = {} ---@type sidekick.cli.session.State[]
  local Terminal = require("sidekick.cli.terminal")

  -- Find the terminal instance attached to this zellij session.
  -- We need this to get the PIDs for deduplication, since zellij's
  -- API doesn't provide process information.
  local function find_pids(sid)
    local pids = {} ---@type integer[]
    for _, t in pairs(Terminal.terminals) do
      if t.mux_backend == "zellij" and t.mux_session == sid then
        vim.list_extend(pids, t.pids or {})
      end
    end
    return pids
  end

  for _, s in ipairs(sessions) do
    local state = Util.get_state(s)
    if state then
      ret[#ret + 1] = {
        id = "zellij: " .. s,
        cwd = state.cwd,
        tool = state.tool,
        mux_session = s,
        pids = find_pids(s),
      }
    end
  end

  if #sessions == 0 then
    return ret
  end

  -- Tools expose their pane and session through inherited Zellij environment
  -- variables. Use the shared process snapshot, since list-panes has no PIDs.
  local Procs = require("sidekick.cli.procs")
  local tools = ctx and ctx.tools or Config.tools()
  local procs = ctx and ctx.procs or Procs.new()
  local panes, seen = {}, {}
  for _, proc in ipairs(procs:list()) do
    for _, tool in pairs(tools) do
      if tool:is_proc(proc) then
        local env = proc.env or {}
        local session, pane_id = env.ZELLIJ_SESSION_NAME, env.ZELLIJ_PANE_ID
        -- Embedded sessions were already added above.
        if session and pane_id and vim.tbl_contains(sessions, session) and not Util.get_state(session) then
          pane_id = "terminal_" .. pane_id:gsub("^terminal_", "")
          panes[session] = panes[session] or M.panes(session)
          local id = "zellij: " .. session .. ":" .. pane_id
          for _, pane in ipairs(panes[session]) do
            if not seen[id] and not pane.is_plugin and not pane.exited and "terminal_" .. pane.id == pane_id then
              seen[id] = true
              ret[#ret + 1] = {
                id = id,
                cwd = proc.cwd or pane.pane_cwd,
                tool = tool,
                mux_session = session,
                zellij_pane_id = pane_id,
                zellij_tab_id = pane.tab_id,
                zellij_pid = proc.pid,
                pids = procs:pids(proc.pid),
              }
            end
          end
        end
      end
    end
  end

  return ret
end

return M
