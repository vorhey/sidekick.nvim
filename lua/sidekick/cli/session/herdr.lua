local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Herdr: sidekick.cli.Session
---@field herdr_pane_id string
---@field herdr_pid number
local M = {}
M.__index = M

--- Run a herdr command and return the decoded `result` of its JSON response.
---@param args string[]
---@param opts? { notify?:boolean }
---@return table? result
local function api(args, opts)
  local cmd = { "herdr" } ---@type string[]
  vim.list_extend(cmd, args)
  local _, out = Util.exec(cmd, { notify = opts and opts.notify == true })
  local ok, data = pcall(vim.json.decode, out or "")
  return ok and type(data) == "table" and type(data.result) == "table" and data.result or nil
end

--- JSON `null` decodes to `vim.NIL`, which is truthy in Lua
---@param value any
---@return string?
local function str(value)
  return type(value) == "string" and value ~= "" and value or nil
end

---@param pane table
---@return sidekick.herdr.Pane?
local function pane_info(pane)
  local pane_id = type(pane) == "table" and str(pane.pane_id) or nil
  if pane_id then
    ---@class sidekick.herdr.Pane
    return {
      pane_id = pane_id,
      tab_id = str(pane.tab_id) or pane_id,
      cwd = str(pane.foreground_cwd) or str(pane.cwd) or "",
    }
  end
end

--- All panes known to the herdr server, keyed by pane id
---@return table<string, sidekick.herdr.Pane>
function M.panes()
  local ret = {} ---@type table<string, sidekick.herdr.Pane>
  local result = api({ "pane", "list" })
  for _, pane in ipairs(result and result.panes or {}) do
    local info = pane_info(pane)
    if info then
      ret[info.pane_id] = info
    end
  end
  return ret
end

function M:init()
  -- herdr panes are owned by the herdr server and can't be embedded in a
  -- Neovim terminal, so sessions are always external.
  self.external = true
  self.mux_session = self.mux_session or self.sid
  self.priority = 10
end

---@return sidekick.cli.terminal.Cmd?
function M:start()
  -- herdr can't run embedded in a Neovim terminal, so always spawn a pane
  -- through the herdr server. When Neovim is not running inside herdr,
  -- the pane is created next to the pane that currently has focus.
  local create = Config.cli.mux.create == "window" and "window" or "split"
  local pane = create == "window" and self:new_tab() or self:new_split()
  if not pane then
    return
  end
  self.id = ("herdr %s"):format(pane.pane_id)
  self.herdr_pane_id = pane.pane_id
  self.mux_session = pane.tab_id
  self.started = true

  -- the pane starts out running a shell, so track it to detect a closed pane
  local info = api({ "pane", "process-info", "--pane", pane.pane_id })
  self.herdr_pid = info and info.process_info and tonumber(info.process_info.shell_pid) or nil

  Util.exec({ "herdr", "pane", "rename", pane.pane_id, self.tool.name }, { notify = false })
  Util.exec({ "herdr", "pane", "run", pane.pane_id, self:shell_cmd() })
  Util.info(("Started **%s** in a new herdr %s"):format(self.tool.name, create == "window" and "tab" or "split"))
end

---@return sidekick.herdr.Pane?
function M:new_split()
  local cmd = { "pane", "split", "--no-focus", "--cwd", self.cwd } ---@type string[]
  vim.list_extend(cmd, { "--direction", Config.cli.mux.split.vertical and "right" or "down" })
  -- herdr only supports fractional splits, so treat sizes > 1 as a percentage
  local size = Config.cli.mux.split.size
  local ratio = size > 1 and size / 100 or size
  if ratio > 0 and ratio < 1 then
    vim.list_extend(cmd, { "--ratio", tostring(ratio) })
  end
  -- split the pane running Neovim, or the focused pane when running outside herdr
  vim.list_extend(cmd, vim.env.HERDR_PANE_ID and { "--pane", vim.env.HERDR_PANE_ID } or { "--current" })
  local result = api(cmd, { notify = true })
  return result and pane_info(result.pane)
end

---@return sidekick.herdr.Pane?
function M:new_tab()
  local cmd = { "tab", "create", "--no-focus", "--cwd", self.cwd, "--label", self.tool.name } ---@type string[]
  local result = api(cmd, { notify = true })
  return result and pane_info(result.root_pane)
end

--- The command that starts the tool in a herdr pane.
--- `herdr pane run` types the command in the pane's shell,
--- so `exec` makes sure the pane closes when the tool exits.
---@return string
function M:shell_cmd()
  local args = {} ---@type string[]
  local env = { "env" } ---@type string[]
  for key, value in pairs(self.tool.env or {}) do
    if value == false then
      vim.list_extend(env, { "-u", key }) -- unset
    else
      env[#env + 1] = ("%s=%s"):format(key, tostring(value))
    end
  end
  if #env > 1 then
    vim.list_extend(args, env)
  end
  local cmd = vim.deepcopy(self.tool.cmd)
  -- panes inherit the environment of the herdr server, so resolve the tool
  -- with Neovim's `PATH` to run the same binary Neovim would
  local exe = vim.fn.exepath(cmd[1])
  cmd[1] = exe ~= "" and exe or cmd[1]
  vim.list_extend(args, cmd)
  return "exec " .. table.concat(vim.tbl_map(vim.fn.shellescape, args), " ")
end

function M:is_running()
  return self.herdr_pid ~= nil and vim.api.nvim_get_proc(self.herdr_pid) ~= nil
end

function M.sessions()
  local panes = M.panes()
  local ret = {} ---@type sidekick.cli.session.State[]
  if vim.tbl_isempty(panes) then
    return ret
  end
  local tools = Config.tools()

  local Procs = require("sidekick.cli.procs")
  local procs = Procs.new()

  local seen = {} ---@type table<string, boolean>
  -- the pane running this Neovim never hosts one of its own sessions.
  -- without this, tools started in a Neovim terminal would be detected here
  -- as well, since they inherit `HERDR_PANE_ID` from Neovim.
  seen[vim.env.HERDR_PANE_ID or ""] = true

  for _, proc in ipairs(procs:list()) do
    for _, tool in pairs(tools) do
      if tool:is_proc(proc) then
        -- panes export their id, and tools inherit it from the pane's shell
        local pane = panes[(proc.env or {}).HERDR_PANE_ID or ""]
        if pane and not seen[pane.pane_id] then
          seen[pane.pane_id] = true
          ret[#ret + 1] = {
            id = ("herdr %s"):format(pane.pane_id),
            cwd = proc.cwd or pane.cwd,
            tool = tool,
            herdr_pane_id = pane.pane_id,
            herdr_pid = proc.pid,
            mux_session = pane.tab_id,
            pids = Procs.pids(proc.pid),
          }
        end
        break
      end
    end
  end

  return ret
end

---@param pane_id string
---@param text string
local function send_text(pane_id, text)
  Util.exec({ "herdr", "pane", "send-text", pane_id, text })
end

---Send text to a herdr pane
function M:send(text)
  local pane_id = self.herdr_pane_id
  if not pane_id then
    return
  end
  if self.tool.mux_focus then
    -- Focus the pane first (some TUI apps like qwen ignore input when unfocused).
    -- Only panes detected as an agent can be focused by id, so ignore failures.
    Util.exec({ "herdr", "agent", "focus", pane_id }, { notify = false })
    vim.defer_fn(function()
      send_text(pane_id, text)
    end, 50) -- slight delay to ensure the focus event is processed first
  else
    send_text(pane_id, text)
  end
end

---Send Enter to a herdr pane
function M:submit()
  if self.herdr_pane_id then
    Util.exec({ "herdr", "pane", "send-keys", self.herdr_pane_id, "Enter" })
  end
end

function M:dump()
  if not self.herdr_pane_id then
    return
  end
  local cmd = { "herdr", "pane", "read", self.herdr_pane_id } ---@type string[]
  vim.list_extend(cmd, { "--source", "recent", "--lines", tostring(Config.cli.mux.dump), "--format", "ansi" })
  local _, ret = Util.exec(cmd)
  return ret
end

return M
