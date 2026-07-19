local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Wezterm: sidekick.cli.Session
---@field wezterm_pane_id string
---@field wezterm_pid number
local M = {}
M.__index = M

---@return sidekick.cli.terminal.Cmd?
function M:attach()
  if self.sid == self.mux_session then
    return { cmd = { "wezterm", "cli", "activate-pane", "--pane-id", self.wezterm_pane_id } }
  end
end

function M:init()
  if self.started then
    self.external = self.sid ~= self.mux_session
  else
    self.external = vim.env.WEZTERM_PANE and Config.cli.mux.create ~= "terminal"
    self.mux_session = self.sid
  end
  self.priority = self.external and 10 or 50
end

---@return sidekick.cli.terminal.Cmd?
function M:start()
  -- wezterm can't run embedded in a Neovim terminal, so always spawn
  -- a pane through the wezterm mux server. When not running inside wezterm,
  -- the user must have started one with `wezterm start --daemonize`.
  local create = Config.cli.mux.create == "window" and "window" or "split"
  local cmd ---@type string[]
  if create == "window" then
    cmd = { "wezterm", "cli", "spawn", "--cwd", self.cwd, "--new-window" }
  else
    cmd = { "wezterm", "cli", "split-pane", "--cwd", self.cwd }
    cmd[#cmd + 1] = Config.cli.mux.split.vertical and "--right" or "--bottom"
    local size = Config.cli.mux.split.size
    vim.list_extend(cmd, { "--percent", tostring(size <= 1 and (size * 100) or size) })
  end
  self:add_cmd(cmd)
  if self:spawn(cmd) then
    Util.info(("Started **%s** in a new wezterm %s"):format(self.tool.name, create))
  end
end

--- Execute the given wezterm command and update the session info.
--- wezterm prints the id of the spawned pane on stdout.
---@param cmd string[]
---@return string? pane_id
function M:spawn(cmd)
  for _, line in ipairs(Util.exec(cmd, { notify = true }) or {}) do
    local pane_id = line:match("^%s*(%d+)%s*$")
    if pane_id then
      self.id = ("wezterm %s"):format(pane_id)
      self.wezterm_pane_id = pane_id
      self.started = true
      return pane_id
    end
  end
end

function M:is_running()
  return self.wezterm_pid and vim.api.nvim_get_proc(self.wezterm_pid) ~= nil
end

---@param ret string[]
function M:add_cmd(ret)
  local env = { "env" }
  for key, value in pairs(self.tool.env or {}) do
    if value == false then
      vim.list_extend(env, { "-u", key }) -- unset
    else
      env[#env + 1] = ("%s=%s"):format(key, tostring(value))
    end
  end
  if #env > 1 then
    vim.list_extend(ret, env)
  end
  vim.list_extend(ret, self.tool.cmd)
end

--- wezterm's list output doesn't include the pane's pid,
--- so resolve it from the pane's tty with lsof
---@param tty_name? string
---@return number?
local function tty_pid(tty_name)
  local tty = tty_name and tty_name:match("/dev/(pts/%d+)")
  if tty then
    local lines = Util.exec({ "lsof", "-t", "/dev/" .. tty }, { notify = false })
    return lines and tonumber(lines[1]) or nil
  end
end

---@param opts? { notify?:boolean }
---@return sidekick.wezterm.Pane[]
function M.panes(opts)
  opts = opts or {}
  local _, output = Util.exec({ "wezterm", "cli", "list", "--format", "json" }, { notify = opts.notify == true })
  local ok, data = pcall(vim.json.decode, output or "")
  local panes = {} ---@type sidekick.wezterm.Pane[]
  for _, pane in ipairs(ok and data or {}) do
    ---@class sidekick.wezterm.Pane
    panes[#panes + 1] = {
      skid = ("wezterm %d"):format(pane.pane_id), -- unique id for the pane
      pid = pane.pid or tty_pid(pane.tty_name), -- process id of the pane
      pane_id = tostring(pane.pane_id),
      tab_id = tostring(pane.tab_id),
      window_id = tostring(pane.window_id),
      cwd = pane.cwd or "",
    }
  end
  return panes
end

function M.sessions()
  local panes = M.panes()
  local ret = {} ---@type sidekick.cli.session.State[]
  local tools = Config.tools()

  local Procs = require("sidekick.cli.procs")
  local procs = Procs.new()
  for _, pane in ipairs(panes) do
    procs:walk(pane.pid, function(proc)
      for _, tool in pairs(tools) do
        if tool:is_proc(proc) then
          ret[#ret + 1] = {
            id = pane.skid,
            cwd = proc.cwd or pane.cwd,
            tool = tool,
            wezterm_pane_id = pane.pane_id,
            wezterm_pid = pane.pid,
            mux_session = pane.tab_id,
            pids = Procs.pids(pane.pid),
          }
          return true
        end
      end
    end)
  end

  return ret
end

function M:pane_id()
  if not self.wezterm_pane_id and not self.external then
    for _, pane in ipairs(M.panes()) do
      if pane.skid == self.id then
        self.wezterm_pane_id = pane.pane_id
        break
      end
    end
  end
  return self.wezterm_pane_id
end

--- Use --no-paste to send raw text so newlines execute commands
---@param pane_id string
---@param text string
local function send_text(pane_id, text)
  Util.exec({ "wezterm", "cli", "send-text", "--pane-id", pane_id, "--no-paste" }, { stdin = text })
end

---Send text to a wezterm pane
function M:send(text)
  local pane_id = self:pane_id()
  if not pane_id then
    return
  end
  if self.tool.mux_focus then
    -- Focus the pane first (some TUI apps like qwen ignore input when unfocused)
    Util.exec({ "wezterm", "cli", "activate-pane", "--pane-id", pane_id })
    vim.defer_fn(function()
      send_text(pane_id, text)
    end, 50) -- slight delay to ensure the focus event is processed first
  else
    send_text(pane_id, text)
  end
end

---Send Enter to a wezterm pane
function M:submit()
  local pane_id = self:pane_id()
  if pane_id then
    send_text(pane_id, "\r")
  end
end

function M:dump()
  local pane_id = self:pane_id()
  if not pane_id then
    return
  end
  local _, ret = Util.exec({ "wezterm", "cli", "get-text", "--pane-id", pane_id }, { notify = true })
  return ret
end

return M
