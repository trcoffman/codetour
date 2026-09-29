-- In-memory store shared by the player, recorder, tree and markers.

---@class codetour.Step
---@field title? string
---@field description string
---@field icon? string
---@field file? string
---@field directory? string
---@field contents? string
---@field uri? string
---@field view? string
---@field line? integer 1-based
---@field selection? { start: { line: integer, character: integer }, ["end"]: { line: integer, character: integer } }
---@field commands? string[]
---@field pattern? string
---@field markerTitle? string

---@class codetour.Tour
---@field id string absolute path of the tour file (or its URL)
---@field title string
---@field description? string
---@field steps codetour.Step[]
---@field ref? string
---@field isPrimary? boolean
---@field nextTour? string
---@field stepMarker? string
---@field when? string

---@class codetour.ActiveTour
---@field tour codetour.Tour
---@field step integer 0-based index of the current step (-1 when empty)
---@field root? string workspace folder used to resolve relative paths
---@field tours? codetour.Tour[] sibling tours used to resolve tour links
---@field can_edit boolean
---@field pending? boolean the current step is being added and isn't saved yet

local M = {
  ---@type codetour.Tour[]
  tours = {},
  ---@type codetour.ActiveTour|nil
  active = nil,
  recording = false,
  editing = false,
  show_markers = nil,
  discovered = false,
}

local listeners = {}

--- Registers a function that is called whenever the store changes.
function M.subscribe(fn)
  listeners[#listeners + 1] = fn
  return function()
    for i, listener in ipairs(listeners) do
      if listener == fn then
        table.remove(listeners, i)
        return
      end
    end
  end
end

--- Notifies listeners that the store changed.
function M.changed()
  for _, listener in ipairs(vim.list_extend({}, listeners)) do
    local ok, err = pcall(listener)
    if not ok then
      vim.notify("CodeTour: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  pcall(vim.cmd.redrawstatus)
end

--- Fires a `User` autocommand (e.g. CodeTourStepChanged, CodeTourEnded).
function M.emit(event, data)
  vim.api.nvim_exec_autocmds("User", { pattern = event, data = data, modeline = false })
end

function M.is_active(tour)
  return M.active ~= nil and tour ~= nil and M.active.tour.id == tour.id
end

function M.is_recording(tour)
  return M.recording and M.is_active(tour)
end

function M.current_step()
  if M.active then
    return M.active.tour.steps[M.active.step + 1]
  end
end

return M
