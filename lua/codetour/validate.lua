-- `:CodeTour validate`: checks tours with the `codetour` CLI (see src/cli)
-- and lists the problems in the quickfix list.

local config = require("codetour.config")
local util = require("codetour.util")

local M = {}

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

--- The command that runs the CLI, or nil and why it wasn't found. Uses the
--- `cli` option, else `codetour` on the PATH, else the CLI built in the
--- plugin's own directory (`npm install && npm run build`).
---@return string[]|nil command
---@return string|nil err
function M.command()
  local cli = config.get().cli
  if cli then
    return type(cli) == "table" and vim.deepcopy(cli) or { cli }
  end
  if vim.fn.executable("codetour") == 1 then
    return { "codetour" }
  end
  local bundled = plugin_root .. "/dist/cli.js"
  if vim.uv.fs_stat(bundled) and vim.fn.executable("node") == 1 then
    return { "node", bundled }
  end
  return nil,
    ("The codetour CLI wasn't found. Build it with `npm install && npm run build` in %s, put `codetour` on your PATH, or set the `cli` option."):format(
      plugin_root
    )
end

--- Validates the workspace's tours (or one tour) into the quickfix list.
---@param tour? string a tour title, file name or path
---@param on_done? fun(problems: table[]|nil)
function M.run(tour, on_done)
  local command, err = M.command()
  if not command then
    util.error(err)
    return on_done and on_done(nil)
  end

  local roots = util.roots()
  vim.list_extend(command, { "--json" })
  for _, root in ipairs(roots) do
    vim.list_extend(command, { "--root", root })
  end
  vim.list_extend(command, { "validate", tour })

  local ok, spawn_err = pcall(vim.system, command, { cwd = roots[1], text = true }, function(result)
    vim.schedule(function()
      local decoded_ok, data = pcall(vim.json.decode, result.stdout or "")
      if not decoded_ok or type(data) ~= "table" or data.error then
        local message = decoded_ok and type(data) == "table" and data.error or vim.trim(result.stderr or "")
        util.error("codetour validate failed: " .. (message ~= "" and message or ("exit code " .. result.code)))
        return on_done and on_done(nil)
      end

      local items = {}
      for _, problem in ipairs(data.problems or {}) do
        items[#items + 1] = {
          filename = util.join(roots[1], problem.file),
          lnum = problem.line,
          text = problem.message,
          type = problem.severity == "error" and "E" or "W",
        }
      end
      vim.fn.setqflist({}, " ", { title = "CodeTour", items = items })
      if #items > 0 then
        vim.cmd("copen")
      else
        util.notify(("No problems found in %d tour%s."):format(data.tours or 0, data.tours == 1 and "" or "s"))
      end
      if on_done then
        on_done(data.problems)
      end
    end)
  end)
  if not ok then
    util.error("Unable to run the codetour CLI: " .. tostring(spawn_err))
    return on_done and on_done(nil)
  end
end

return M
