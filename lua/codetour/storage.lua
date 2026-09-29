-- Persists tour progress and which workspaces were already prompted
-- (VS Code keeps these in the extension's globalState).

local config = require("codetour.config")

local M = {}

local data

local function empty()
  return { progress = {}, prompted = {} }
end

local function read()
  local content = require("codetour.util").read_file(config.get().state_file)
  if not content or content == "" then
    return empty()
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return empty()
  end
  decoded.progress = type(decoded.progress) == "table" and decoded.progress or {}
  decoded.prompted = type(decoded.prompted) == "table" and decoded.prompted or {}
  return decoded
end

-- Re-reads the file before every write so that multiple Neovim instances
-- don't clobber each other's progress.
local function update(fn)
  data = read()
  fn(data)
  local ok, err = require("codetour.util").write_file(config.get().state_file, vim.json.encode(data))
  if not ok then
    require("codetour.util").error("Unable to save tour progress: " .. tostring(err))
  end
end

local function get()
  if not data then
    data = read()
  end
  return data
end

--- Forgets the cached state (the next access re-reads the state file).
function M.reload()
  data = nil
end

--- Marks a step (0-based) of a tour as completed.
function M.complete_step(tour, step)
  update(function(state)
    local steps = state.progress[tour.id] or {}
    if not vim.tbl_contains(steps, step) then
      steps[#steps + 1] = step
    end
    state.progress[tour.id] = steps
  end)
end

--- Whether a step (0-based) or, without `step`, the whole tour is complete.
function M.is_complete(tour, step)
  local steps = get().progress[tour.id] or {}
  if step ~= nil then
    return vim.tbl_contains(steps, step)
  end
  return #tour.steps > 0 and #steps >= #tour.steps
end

function M.has_progress(tour)
  if tour then
    return #(get().progress[tour.id] or {}) > 0
  end
  return next(get().progress) ~= nil
end

--- Clears the progress of one tour, or of every tour.
function M.reset(tour)
  update(function(state)
    if tour then
      state.progress[tour.id] = nil
    else
      state.progress = {}
    end
  end)
end

function M.was_prompted(root)
  return get().prompted[root] == true
end

function M.set_prompted(root)
  update(function(state)
    state.prompted[root] = true
  end)
end

return M
