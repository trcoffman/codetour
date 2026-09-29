-- Starting, navigating and ending tours (VS Code's store/actions.ts).

local async = require("codetour.async")
local config = require("codetour.config")
local player = require("codetour.player")
local state = require("codetour.state")
local storage = require("codetour.storage")
local util = require("codetour.util")

local M = {}

local function discovery()
  return require("codetour.discovery")
end

local function fire_step_changed()
  state.emit("CodeTourStepChanged", { tour = state.active.tour, step = state.active.step })
end

---@class codetour.StartOptions
---@field root? string workspace folder used to resolve relative paths
---@field edit_mode? boolean start recording/editing the tour
---@field can_edit? boolean whether the tour may be edited (default true)
---@field tours? codetour.Tour[] sibling tours used to resolve tour links
---@field focus? boolean

--- Starts a tour at a 0-based step.
---@param tour codetour.Tour
---@param step? integer
---@param opts? codetour.StartOptions
function M.start_tour(tour, step, opts)
  opts = opts or {}
  if state.active and state.active.pending then
    require("codetour.recorder").discard_pending()
  end

  local same_tour = state.is_active(tour)
  if not same_tour then
    player.close()
    if not opts.edit_mode then
      state.recording = false
      state.editing = false
    end
  end

  if #tour.steps == 0 then
    step = -1
  else
    step = math.max(0, math.min(step or 0, #tour.steps - 1))
  end

  state.active = {
    tour = tour,
    step = step,
    root = opts.root or util.tour_root(tour),
    tours = opts.tours,
    can_edit = opts.can_edit ~= false,
  }

  if opts.edit_mode then
    state.recording = true
    state.editing = true
  else
    fire_step_changed()
  end

  state.changed()
  if step >= 0 then
    player.render({ navigated = true, focus = opts.focus ~= false })
  end
end

--- Reads a tour file and starts it (VS Code API: startTourByUri).
function M.start_tour_by_path(path, step)
  local tour, err = require("codetour.tourfile").read(path)
  if not tour then
    util.error("This file doesn't appear to be a valid tour: " .. tostring(err))
    return
  end
  M.start_tour(tour, step)
end

--- Ends the active tour.
---@param fire? boolean fire the CodeTourEnded event (default true)
function M.end_tour(fire)
  local active = state.active
  if not active then
    return
  end
  if active.pending then
    require("codetour.recorder").discard_pending()
  end

  state.recording = false
  state.editing = false
  player.close()
  state.active = nil
  require("codetour.commands").close_terminal()
  player.close_scratch_buffers()

  state.changed()
  if fire ~= false then
    state.emit("CodeTourEnded", { tour = active.tour })
  end
end

local function can_leave_step()
  if player.has_unsaved_edits() then
    util.warn("The step has unsaved changes: use :w to save them or :q! to discard them.")
    return false
  end
  return true
end

function M.next()
  local active = state.active
  if not active then
    return util.warn("There is no active tour.")
  end
  if not can_leave_step() then
    return
  end
  if active.step >= #active.tour.steps - 1 then
    return util.notify("This is the last step of the tour.")
  end
  storage.complete_step(active.tour, active.step)
  active.step = active.step + 1
  fire_step_changed()
  state.changed()
  player.render({ navigated = true, focus = true })
end

function M.prev()
  local active = state.active
  if not active then
    return util.warn("There is no active tour.")
  end
  if not can_leave_step() then
    return
  end
  if active.step <= 0 then
    return util.notify("This is the first step of the tour.")
  end
  active.step = active.step - 1
  fire_step_changed()
  state.changed()
  player.render({ navigated = true, focus = true })
end

--- Navigates to a 1-based step of the active tour.
function M.goto_step(number)
  local active = state.active
  if not active then
    return util.warn("There is no active tour.")
  end
  number = tonumber(number)
  if not number or number < 1 or number > #active.tour.steps then
    return util.warn(("The tour doesn't have a step #%s."):format(tostring(number)))
  end
  if not can_leave_step() then
    return
  end
  M.start_tour(active.tour, number - 1, { root = active.root, tours = active.tours, can_edit = active.can_edit })
end

--- Shows the current step again (e.g. after navigating to other files).
function M.resume()
  if not state.active then
    return util.warn("There is no active tour.")
  end
  if state.active.step < 0 then
    return util.notify("The tour doesn't have any steps yet.")
  end
  player.render({ focus = true })
end

--- Marks the current step complete and starts the next tour (if a title is
--- given) or ends the tour.
function M.finish(title)
  local active = state.active
  if active and active.step >= 0 then
    storage.complete_step(active.tour, active.step)
  end
  if title then
    M.start_by_title(title)
  else
    M.end_tour()
  end
end

--- Starts a tour by its exact title, optionally at a 1-based step.
function M.start_by_title(title, number)
  local active = state.active
  local tours = (active and active.tours) or state.tours
  for _, tour in ipairs(tours) do
    if tour.title == title then
      return M.start_tour(tour, number and (tonumber(number) - 1) or 0, {
        root = active and active.root or nil,
        tours = active and active.tours or nil,
      })
    end
  end
  util.warn(("Unable to find a tour titled %q."):format(title))
end

local function format_tour(tour)
  local label = tour.title
  if tour.description and tour.description ~= "" then
    label = label .. " — " .. tour.description:gsub("\n", " ")
  end
  return label
end

--- Starts the only tour, or asks which one to start.
---@return boolean started
function M.select_tour(tours, root, step)
  tours = tours or state.tours
  if #tours == 0 then
    util.notify("There are no tours in this workspace. Use :CodeTour record to create one.")
    return false
  end
  if #tours == 1 then
    M.start_tour(tours[1], step, { root = root, tours = tours })
    return true
  end
  local tour = async.select(tours, { prompt = "Select the tour to start", format_item = format_tour })
  if tour then
    M.start_tour(tour, step, { root = root, tours = tours })
    return true
  end
  return false
end

--- Starts the primary tour (or a tour titled "1 - ..."), else asks.
function M.start_default_tour(root, tours, step)
  tours = tours or state.tours
  if #tours == 0 then
    return false
  end
  for _, tour in ipairs(tours) do
    if tour.isPrimary then
      M.start_tour(tour, step, { root = root, tours = tours })
      return true
    end
  end
  for _, tour in ipairs(tours) do
    if tour.title:match("^#?1%s+%-") then
      M.start_tour(tour, step, { root = root, tours = tours })
      return true
    end
  end
  return M.select_tour(tours, root, step)
end

--- Finds a tour by title or by (a suffix of) its file path, like the
--- `?tour=` parameter of VS Code's URI handler.
function M.find_tour(name, tours)
  tours = tours or state.tours
  for _, tour in ipairs(tours) do
    if tour.title == name then
      return tour
    end
  end
  local lower = name:lower()
  for _, tour in ipairs(tours) do
    if tour.title:lower() == lower or util.tour_title(tour):lower() == lower then
      return tour
    end
  end
  local file = name:match("%.tour$") and name or name .. ".tour"
  for _, tour in ipairs(tours) do
    if tour.id:sub(-#file) == file and (#tour.id == #file or tour.id:sub(-#file - 1, -#file - 1) == "/") then
      return tour
    end
  end
  -- Finally, a part of the title, as long as it identifies a single tour
  -- (e.g. "getting" for "🏃 Getting Started").
  local matches = vim.tbl_filter(function(tour)
    return tour.title:lower():find(lower, 1, true) ~= nil
  end, tours)
  if #matches == 1 then
    return matches[1]
  end
end

--- Offers to start a tour the first time a workspace with tours is opened.
---@param opts? { notify?: boolean } only show a (non-blocking) notification
function M.prompt_for_tour(root, tours, opts)
  root = root or util.roots()[1]
  tours = tours or state.tours
  if #tours == 0 or state.active or storage.was_prompted(root) then
    return false
  end
  if not config.setting("prompt_for_workspace_tours", root) then
    return false
  end
  storage.set_prompted(root)
  local message = "This workspace has guided tours you can take to get familiar with the codebase."
  if opts and opts.notify then
    -- At startup, don't block the editor with a picker (VS Code shows a
    -- toast, which is easy to ignore).
    util.notify(message .. " Run :CodeTour start to take one, or :CodeTour tree to browse them.")
    return false
  end
  local choice = async.select({ "Start CodeTour", "Not now" }, { prompt = message })
  if choice == "Start CodeTour" then
    return M.start_default_tour(root, tours)
  end
  return false
end

--- Opens a tour file from disk (VS Code: "Open Tour File...").
function M.open_tour_file(path)
  if not path or path == "" then
    path = async.input({ prompt = "Tour file: ", completion = "file" })
    if not path or path == "" then
      return
    end
  end
  local tour, err = require("codetour.tourfile").read(vim.fn.expand(path))
  if not tour then
    util.error("This file doesn't appear to be a valid tour. Please inspect its contents and try again. (" .. tostring(err) .. ")")
    return
  end
  M.start_tour(tour)
end

--- Downloads and starts a tour (VS Code: "Open Tour URL...").
function M.open_tour_url(url)
  if not url or url == "" then
    local clipboard = vim.fn.getreg("+")
    url = async.input({
      prompt = "Specify the URL of the tour file to open: ",
      default = clipboard:match("^https?://%S+$") and clipboard or nil,
    })
    if not url or url == "" then
      return
    end
  end
  if vim.fn.executable("curl") ~= 1 then
    return util.error("Opening tours from a URL requires curl.")
  end
  local result = vim.system({ "curl", "-fsSL", url }, { text = true }):wait(30000)
  local tour = result.code == 0 and require("codetour.tourfile").parse(result.stdout, url)
  if not tour then
    util.error("This file doesn't appear to be a valid tour. Please inspect its contents and try again.")
    return
  end
  -- The tour can't be saved back to a URL, so it's read-only.
  M.start_tour(tour, nil, { can_edit = false })
end

--- Picks a tour for commands that act on "a tour": the active one, else ask.
---@return codetour.Tour|nil
function M.pick_tour(prompt, filter)
  -- Commands act on the active tour (even if it doesn't pass the filter, so
  -- the command can explain why it can't be used).
  if state.active then
    return state.active.tour
  end
  discovery().ensure()
  local tours = filter and vim.tbl_filter(filter, state.tours) or state.tours
  if #tours == 0 then
    util.notify("There are no tours in this workspace.")
    return nil
  end
  if #tours == 1 then
    return tours[1]
  end
  return async.select(tours, { prompt = prompt or "Select a tour", format_item = format_tour })
end

return M
