-- Lets multi-prompt flows (e.g. recording a tour) be written sequentially on
-- top of the callback-based vim.ui.input / vim.ui.select.

local M = {}

--- Runs `fn` in a coroutine, reporting errors.
function M.run(fn, ...)
  local co = coroutine.create(fn)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    vim.notify("CodeTour: " .. tostring(err), vim.log.levels.ERROR)
  end
end

-- Waits for a callback-style function, which may call back synchronously.
local function await(start)
  local co = coroutine.running()
  if not co then
    error("codetour.async functions must be called from async.run()", 2)
  end

  local done, result, waiting = false, nil, false
  start(function(...)
    result = { n = select("#", ...), ... }
    done = true
    if waiting then
      -- Resume outside of the UI's callback (e.g. while a picker is closing).
      vim.schedule(function()
        local ok, err = coroutine.resume(co)
        if not ok then
          vim.notify("CodeTour: " .. tostring(err), vim.log.levels.ERROR)
        end
      end)
    end
  end)

  if not done then
    waiting = true
    coroutine.yield()
  end
  return unpack(result, 1, result.n)
end

--- Prompts for text. Returns nil when cancelled.
function M.input(opts)
  return await(function(cb)
    vim.ui.input(opts, cb)
  end)
end

--- Prompts for a choice. Returns the item (and index) or nil when cancelled.
function M.select(items, opts)
  return await(function(cb)
    vim.ui.select(items, opts, cb)
  end)
end

--- Asks to confirm a destructive action.
function M.confirm(prompt, action)
  local choice = M.select({ action, "Cancel" }, { prompt = prompt })
  return choice == action
end

return M
