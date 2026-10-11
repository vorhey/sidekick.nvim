local M = {}

-- Check PATH candidates concurrently: executable() can block on each missing
-- command when PATH contains slow mounts. Keep results local to this request.
---@param tools table<string,sidekick.cli.Tool>
---@param cb fun(installed:table<string,boolean>)
function M.get(tools, cb)
  local installed, commands = {}, {}
  for name, tool in pairs(tools) do
    local cmd = tool.cmd[1]
    commands[cmd] = commands[cmd] or {}
    commands[cmd][#commands[cmd] + 1] = name
  end
  local pending = vim.tbl_count(commands)
  local function finish(cmd, found)
    for _, name in ipairs(commands[cmd]) do
      installed[name] = found
    end
    pending = pending - 1
    if pending == 0 then
      vim.schedule(function()
        cb(installed)
      end)
    end
  end
  if pending == 0 then
    vim.schedule(function()
      cb(installed)
    end)
    return
  end
  local paths, seen = {}, {} ---@type string[], table<string, boolean>
  for _, path in ipairs(vim.split(vim.env.PATH or "", ":", { plain = true })) do
    if not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  for cmd in pairs(commands) do
    if vim.fn.has("win32") == 1 then
      -- Preserve PATHEXT and Windows executable resolution rules.
      finish(cmd, vim.fn.executable(cmd) == 1)
    else
      -- Like executable(): a command with a path separator is not searched in
      -- PATH, and an empty PATH entry is the current directory.
      local candidates = { cmd }
      if not cmd:find("/", 1, true) then
        candidates = vim.tbl_map(function(path)
          return path == "" and cmd or path .. "/" .. cmd
        end, paths)
      end
      local remaining, found = #candidates, false
      local function checked(executable)
        found = found or executable
        remaining = remaining - 1
        if remaining == 0 then
          finish(cmd, found)
        end
      end
      for _, candidate in ipairs(candidates) do
        vim.uv.fs_stat(candidate, function(err, stat)
          if err or not stat or stat.type ~= "file" then
            checked(false)
            return
          end
          vim.uv.fs_access(candidate, "X", function(access_err, executable)
            checked(not access_err and executable == true)
          end)
        end)
      end
    end
  end
end

return M
