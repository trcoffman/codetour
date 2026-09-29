-- CodeTour for Neovim: record and play back guided tours of codebases.
--
-- The public API mirrors the one exported by the VS Code extension. Tour
-- events are published as `User` autocommands:
--   CodeTourStepChanged  a tour was started or navigated (data: { tour, step })
--   CodeTourEnded        a tour ended (data: { tour })

local M = {}

local function async(fn)
  return function(...)
    local args = { ... }
    require("codetour.async").run(function()
      fn(unpack(args))
    end)
  end
end

---@param opts? codetour.Config
function M.setup(opts)
  require("codetour.config").setup(opts)
  require("codetour.highlights").setup()
  local state = require("codetour.state")
  state.show_markers = nil
  if state.discovered then
    require("codetour.discovery").discover()
    require("codetour.markers").refresh_all()
  end
end

--- Runs when Neovim has started: discovers tours, shows markers and offers to
--- start a tour the first time a workspace with tours is opened.
function M.on_startup()
  local state = require("codetour.state")
  require("codetour.discovery").discover()
  if #state.tours == 0 then
    return
  end
  require("codetour.markers").refresh_all()
  if #vim.api.nvim_list_uis() > 0 then
    require("codetour.async").run(function()
      require("codetour.actions").prompt_for_tour()
    end)
  end
end

--- Starts a tour at a 0-based step (VS Code API: startTour).
---@param tour codetour.Tour
---@param step? integer
---@param opts? codetour.StartOptions
function M.start_tour(tour, step, opts)
  require("codetour.actions").start_tour(tour, step, opts)
end

--- Starts the tour stored in a file (VS Code API: startTourByUri).
function M.start_tour_by_path(path, step)
  require("codetour.actions").start_tour_by_path(path, step)
end

--- Ends the active tour (VS Code API: endCurrentTour).
function M.end_tour()
  require("codetour.actions").end_tour()
end

--- Returns the tour as JSON with the contents of its files embedded
--- (VS Code API: exportTour).
---@return string
function M.export_tour(tour)
  return require("codetour.tourfile").export(tour)
end

--- Starts recording a new tour (VS Code API: recordTour).
M.record_tour = async(function(title)
  require("codetour.recorder").record(title)
end)

--- Starts the only tour or asks which one to start (VS Code API: selectTour).
M.select_tour = async(function(tours, root, step)
  require("codetour.actions").select_tour(tours, root, step)
end)

--- Starts the primary tour, or asks which one to start.
M.start_default_tour = async(function(root, tours, step)
  require("codetour.discovery").ensure()
  require("codetour.actions").start_default_tour(root, tours, step)
end)

--- Offers to start a tour if the workspace wasn't prompted yet
--- (VS Code API: promptForTour).
M.prompt_for_tour = async(function(root, tours)
  require("codetour.actions").prompt_for_tour(root, tours)
end)

M.next = function()
  require("codetour.actions").next()
end

M.prev = function()
  require("codetour.actions").prev()
end

M.resume = function()
  require("codetour.actions").resume()
end

--- The tours discovered in the workspace.
---@return codetour.Tour[]
function M.get_tours()
  require("codetour.discovery").ensure()
  return require("codetour.state").tours
end

--- The active tour, if any.
---@return codetour.ActiveTour|nil
function M.get_active()
  return require("codetour.state").active
end

--- Text for a statusline component, e.g. "CodeTour: #2 of 5 (Setup)".
---@return string
function M.status()
  local state = package.loaded["codetour.state"]
  if not (state and state.active) then
    return ""
  end
  local active = state.active
  local prefix = state.recording and "Recording " or ""
  return ("%sCodeTour: #%d of %d (%s)"):format(
    prefix,
    active.step + 1,
    #active.tour.steps,
    require("codetour.util").tour_title(active.tour)
  )
end

return M
