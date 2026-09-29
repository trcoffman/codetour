-- Recording and editing tours (VS Code's recorder/commands.ts).

local actions = require("codetour.actions")
local async = require("codetour.async")
local config = require("codetour.config")
local json = require("codetour.json")
local player = require("codetour.player")
local state = require("codetour.state")
local tourfile = require("codetour.tourfile")
local util = require("codetour.util")

local M = {}

local function can_edit(tour)
  if not tourfile.is_saveable(tour) or (state.is_active(tour) and not state.active.can_edit) then
    util.error("This tour can't be edited.")
    return false
  end
  return true
end

local function editable(tour)
  return tourfile.is_saveable(tour) and not (state.is_active(tour) and not state.active.can_edit)
end

local function require_recording()
  local active = state.active
  if not (active and state.recording) then
    util.warn("You aren't recording a tour. Use :CodeTour record or :CodeTour edit first.")
    return nil
  end
  if not can_edit(active.tour) then
    return nil
  end
  if player.has_unsaved_edits() then
    util.warn("The current step has unsaved changes: use :w to save them or :q! to discard them.")
    return nil
  end
  return active
end

local function root_for(tour)
  if state.is_active(tour) and state.active.root then
    return state.active.root
  end
  return util.tour_root(tour)
end

local function refresh_player(tour)
  if state.is_active(tour) then
    player.refresh()
  end
end

-- Git refs -------------------------------------------------------------------

--- Asks which git ref a tour should be associated with.
---@return string|nil ref ("HEAD" means none)
function M.prompt_for_ref(root)
  local git = require("codetour.git")
  local repo = git.repository(root)
  if not repo then
    return nil
  end

  local items = {
    { label = "None", detail = "Allow the tour to apply to all versions of this repository", ref = "HEAD" },
  }
  if repo.branch then
    items[#items + 1] = {
      label = ("Current branch (%s)"):format(repo.branch),
      detail = "Allow the tour to apply to all versions of this branch",
      ref = repo.branch,
    }
  end
  if repo.commit then
    items[#items + 1] = {
      label = "Current commit",
      detail = "Keep the tour associated with a specific commit",
      ref = repo.commit,
    }
  end
  for _, tag in ipairs(git.tags(root)) do
    items[#items + 1] = { label = "Tag: " .. tag, detail = "Keep the tour associated with a specific tag", ref = tag }
  end

  local item = async.select(items, {
    prompt = "Select the Git ref to associate the tour with",
    format_item = function(item)
      return item.label .. " — " .. item.detail
    end,
  })
  return item and item.ref
end

-- Recording ----------------------------------------------------------------

function M.tour_path(root, title)
  return tourfile.path_for(root, title)
end

-- When a tour is saved outside of the workspace ("save as"), offer to export
-- it (embedding file contents) once recording ends, like VS Code does.
local function offer_export_on_end(path)
  vim.api.nvim_create_autocmd("User", {
    pattern = "CodeTourEnded",
    callback = function(ev)
      if not (ev.data and ev.data.tour and ev.data.tour.id == path) then
        return false
      end
      async.run(function()
        if async.confirm("Would you like to export this tour?", "Export Tour") then
          local tour = tourfile.read(path)
          if tour then
            util.write_file(path, tourfile.export(tour))
          end
        end
      end)
      return true
    end,
  })
end

--- Starts recording a new tour. `title` may also be a path ending in ".tour"
--- to save the tour outside of the workspace's tour directory.
function M.record(title, placeholder)
  require("codetour.discovery").ensure()
  local roots = util.roots()
  local root = roots[1]
  if #roots > 1 then
    root = async.select(roots, { prompt = "Select the workspace to save the tour to" })
    if not root then
      return
    end
  end

  while true do
    if not title or title == "" then
      title = async.input({
        prompt = "Specify the title of the tour (or a *.tour path to save it to): ",
        default = placeholder,
      })
      if not title or title == "" then
        return
      end
    end
    if title:match("%.tour$") or vim.uv.fs_stat(M.tour_path(root, title)) == nil then
      break
    end
    local choice = async.select({ "Re-enter title", "Overwrite existing tour" }, {
      prompt = ('This workspace already includes a tour with the title "%s."'):format(title),
    })
    if choice == "Re-enter title" then
      placeholder, title = title, nil
    elseif choice == nil then
      return
    else
      break
    end
  end

  local save_as = title:match("%.tour$") ~= nil
  local path = save_as and util.normalize(vim.fn.fnamemodify(vim.fn.expand(title), ":p")) or M.tour_path(root, title)
  local tour_title = save_as and vim.fs.basename(path):gsub("%.tour$", "") or title

  local ref
  if config.setting("record_mode", root) ~= "pattern" then
    ref = M.prompt_for_ref(root)
  end

  local tour = tourfile.create(path, tour_title, ref)
  if not tour then
    return
  end
  if save_as then
    offer_export_on_end(tour.id)
  end

  actions.start_tour(tour, 0, { root = root, edit_mode = true })
  require("codetour.discovery").discover()
  util.notify(
    "CodeTour recording started! Open a file and run :CodeTour add_step on a line (or a visual selection) to add a step, or :CodeTour add_content_step to add an introduction."
  )
  return tour
end

-- Adding steps ---------------------------------------------------------------

-- New steps are inserted after the current step and edited right away; they
-- are only written to the tour file once the description is saved (:w).
local function insert_pending(active, step)
  local index = active.step + 1
  table.insert(active.tour.steps, index + 1, step)
  active.step = index
  active.pending = true
  state.editing = true
  state.changed()
  player.render({ focus = true })
end

--- Removes a step that was being added but never saved.
function M.discard_pending()
  local active = state.active
  if not (active and active.pending) then
    return
  end
  table.remove(active.tour.steps, active.step + 1)
  active.step = math.min(active.step - 1, #active.tour.steps - 1)
  if active.step < 0 and #active.tour.steps > 0 then
    active.step = 0
  end
  active.pending = false
  state.editing = false
end

local function char_length(line, byte)
  local b = line:byte(byte + 1)
  if not b then
    return 0
  end
  return b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1
end

local function visual_selection(buf, opts)
  local start, finish = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  local mode = vim.fn.visualmode()
  local sr, sc, er, ec = start[2] - 1, start[3] - 1, finish[2] - 1, finish[3] - 1
  if start[2] ~= opts.line1 or finish[2] ~= opts.line2 then
    -- An explicit range (e.g. `:10,20CodeTour add_step`) selects whole lines.
    mode, sr, er = "V", opts.line1 - 1, opts.line2 - 1
  end
  local last = vim.api.nvim_buf_get_lines(buf, er, er + 1, false)[1] or ""
  if mode == "V" then
    sc, ec = 0, #last
  else
    ec = math.min(ec, #last)
    ec = ec + char_length(last, ec)
    local first = vim.api.nvim_buf_get_lines(buf, sr, sr + 1, false)[1] or ""
    sc = math.min(sc, #first)
  end
  return util.make_selection(buf, sr, sc, er, ec)
end

-- The window and buffer steps are added from (the code window, even when
-- the command is run from the step window).
local function code_context()
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    win = player.step_window() or win
  end
  return win, vim.api.nvim_win_get_buf(win)
end

--- Adds a step for the cursor line or, with a range, the selected text.
---@param opts? { range?: integer, line1?: integer, line2?: integer }
--- `range` is the number of addresses given to the command: 1 (`:5CodeTour
--- add_step`) adds a step for that line, 2 (e.g. from Visual mode) a
--- selection step.
function M.add_step(opts)
  opts = opts or {}
  local active = require_recording()
  if not active then
    return
  end

  local win, buf = code_context()
  local path = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= "" or path == "" then
    return util.warn("Open a file to add a step for it.")
  end
  local file = util.relative(active.root, util.normalize(path))

  local step
  if (opts.range or 0) > 1 then
    step = json.object({ file = file, selection = visual_selection(buf, opts), description = "" }, {
      "file",
      "selection",
      "description",
    })
  else
    local row = opts.range == 1 and opts.line1 - 1 or vim.api.nvim_win_get_cursor(win)[1] - 1
    step = json.object({ file = file, description = "" }, { "file", "description" })
    if config.setting("record_mode", active.root) == "pattern" then
      -- Use a pattern only if it identifies the line unambiguously.
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local pattern = require("codetour.ops").line_pattern(lines, row)
      if pattern then
        step.pattern = pattern
      else
        step.line = row + 1
      end
    else
      step.line = row + 1
    end
  end

  insert_pending(active, step)
end

--- Adds a step that isn't associated with a file (e.g. an introduction).
---@param title? string
---@param after? integer 0-based step to insert the new step after
function M.add_content_step(title, after)
  local active = require_recording()
  if not active then
    return
  end
  if not title or title == "" then
    title = async.input({
      prompt = "Specify the title of the step: ",
      default = active.step == -1 and "Introduction" or "",
    })
    if not title or title == "" then
      return
    end
  end
  if after then
    active.step = after
  end
  insert_pending(active, json.object({ title = title, description = "" }, { "title", "description" }))
end

local function current_directory()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.b[buf].netrw_curdir then
    return vim.b[buf].netrw_curdir
  end
  if vim.bo[buf].filetype == "oil" then
    local ok, oil = pcall(require, "oil")
    if ok and oil.get_current_dir() then
      return oil.get_current_dir()
    end
  end
  if name ~= "" and vim.fn.isdirectory(name) == 1 then
    return name
  end
end

--- Adds a step for a directory (the current explorer directory by default).
function M.add_directory_step(directory)
  local active = require_recording()
  if not active then
    return
  end
  directory = directory or current_directory()
  if not directory or directory == "" then
    local name = vim.api.nvim_buf_get_name(0)
    directory = async.input({
      prompt = "Directory: ",
      completion = "dir",
      default = name ~= "" and util.relative(util.normalize(vim.fn.getcwd()), vim.fs.dirname(name)) or nil,
    })
    if not directory or directory == "" then
      return
    end
  end
  local path = util.normalize(vim.fn.fnamemodify(vim.fn.expand(directory), ":p"))
  if vim.fn.isdirectory(path) ~= 1 then
    return util.warn(path .. " isn't a directory.")
  end
  local relative = util.relative(active.root, path)
  insert_pending(active, json.object({ directory = relative, description = "" }, { "directory", "description" }))
end

--- Saves the description typed in the step editor.
function M.save_step_description(text)
  local active = state.active
  local step = state.current_step()
  if not (active and step) then
    return
  end
  step.description = text
  active.pending = false
  state.editing = false
  tourfile.save(active.tour)
  player.render({ reveal = false, focus = true })
end

--- Called when the step editor is closed without saving.
function M.cancel_edit()
  local active = state.active
  if not active or not state.editing then
    return
  end
  if active.pending then
    M.discard_pending()
    state.changed()
    if active.step >= 0 then
      player.render({ focus = false })
    end
    return
  end
  state.editing = false
  state.changed()
  player.refresh()
end

-- Editing ------------------------------------------------------------------

--- Starts editing a tour (at a 0-based step).
function M.edit(tour, step)
  tour = tour or actions.pick_tour("Select the tour to edit", editable)
  if not tour or not can_edit(tour) then
    return
  end
  local active = state.active
  local same = state.is_active(tour)
  if step == nil and same then
    step = active.step
  end
  actions.start_tour(tour, step or 0, {
    edit_mode = true,
    root = same and active.root or nil,
    tours = same and active.tours or nil,
  })
  if #tour.steps == 0 then
    util.notify("This tour doesn't have any steps yet. Use :CodeTour add_step to add one.")
  end
end

--- Switches from editing the current step back to viewing it.
function M.preview()
  if not state.active then
    return
  end
  if player.has_unsaved_edits() then
    return util.warn("The step has unsaved changes: use :w to save them or :q! to discard them.")
  end
  if state.active.pending then
    M.discard_pending()
  end
  state.editing = false
  state.changed()
  if state.active.step >= 0 then
    player.render({ reveal = false })
  end
end

local function step_target(tour, index)
  tour = tour or (state.active and state.active.tour)
  if not tour then
    util.warn("There is no active tour.")
    return nil
  end
  if index == nil then
    index = state.is_active(tour) and state.active.step or -1
  end
  if not tour.steps[index + 1] then
    util.warn("There is no step to change.")
    return nil
  end
  if not can_edit(tour) then
    return nil
  end
  return tour, index
end

--- Moves a step up (-1) or down (1).
function M.move_step(delta, tour, index)
  tour, index = step_target(tour, index)
  if not tour then
    return
  end
  local target = index + delta
  if target < 0 or target >= #tour.steps then
    return
  end
  local step = table.remove(tour.steps, index + 1)
  table.insert(tour.steps, target + 1, step)

  -- Keep the player on the same step.
  if state.is_active(tour) then
    if state.active.step == index then
      state.active.step = target
    elseif state.active.step == target then
      state.active.step = index
    end
  end
  tourfile.save(tour)
  refresh_player(tour)
end

--- Deletes steps (0-based indexes) after confirming.
function M.delete_steps(tour, indexes)
  tour = tour or (state.active and state.active.tour)
  if not tour then
    return util.warn("There is no active tour.")
  end
  indexes = indexes or { state.is_active(tour) and state.active.step or -1 }
  indexes = vim.tbl_filter(function(i)
    return tour.steps[i + 1] ~= nil
  end, indexes)
  if #indexes == 0 or not can_edit(tour) then
    return
  end

  local plural = #indexes > 1
  local prompt = plural and ("Are you sure you want to delete the %d selected steps?"):format(#indexes)
    or "Are you sure you want to delete the selected step?"
  if not async.confirm(prompt, plural and ("Delete %d Steps"):format(#indexes) or "Delete Step") then
    return
  end

  table.sort(indexes, function(a, b)
    return a > b
  end)
  for _, index in ipairs(indexes) do
    table.remove(tour.steps, index + 1)
  end

  local deleted_current = false
  if state.is_active(tour) then
    local active = state.active
    deleted_current = vim.tbl_contains(indexes, active.step)
    local before = #vim.tbl_filter(function(i)
      return i <= active.step
    end, indexes)
    if before > 0 and (active.step > 0 or #tour.steps == 0) then
      active.step = active.step - before
    end
    active.step = math.min(math.max(active.step, #tour.steps > 0 and 0 or -1), #tour.steps - 1)
  end

  tourfile.save(tour)
  if state.is_active(tour) then
    if state.active.step < 0 then
      player.hide()
    elseif deleted_current then
      player.render({ focus = false })
    else
      player.refresh()
    end
  end
end

local function prompt_value(prompt, current)
  return async.input({ prompt = prompt, default = current or "" })
end

function M.change_step_title(tour, index, value)
  tour, index = step_target(tour, index)
  if not tour then
    return
  end
  local step = tour.steps[index + 1]
  if value == nil then
    value = prompt_value("Enter the title for this tour step: ", step.title)
    if value == nil then
      return
    end
  end
  step.title = value ~= "" and value or nil
  tourfile.save(tour)
  refresh_player(tour)
end

function M.change_step_icon(tour, index, value)
  tour, index = step_target(tour, index)
  if not tour then
    return
  end
  local step = tour.steps[index + 1]
  if value == nil then
    value = prompt_value("Enter the icon for this tour step: ", step.icon)
    if value == nil then
      return
    end
  end
  step.icon = value ~= "" and value or nil
  tourfile.save(tour)
end

--- Changes the line of the current step (blank uses the selection/end of file).
function M.change_step_line(value)
  local tour, index = step_target()
  if not tour then
    return
  end
  local step = tour.steps[index + 1]
  if value == nil then
    value = prompt_value(
      "Enter the new line # for this tour step (Leave blank to use the selection/document end): ",
      step.line and tostring(step.line) or ""
    )
    if value == nil then
      return
    end
  end
  local line = tonumber(value)
  if value ~= "" and not line then
    return util.warn("The line must be a number.")
  end
  step.line = line
  tourfile.save(tour)
  refresh_player(tour)
end

--- Sets the current step's selection to the visual selection, or clears it
--- when called without a range.
function M.change_step_selection(opts)
  opts = opts or {}
  local tour, index = step_target()
  if not tour then
    return
  end
  local step = tour.steps[index + 1]
  if (opts.range or 0) > 0 then
    local _, buf = code_context()
    step.selection = visual_selection(buf, opts)
  else
    step.selection = nil
  end
  tourfile.save(tour)
  refresh_player(tour)
end

-- Tour properties -------------------------------------------------------------

function M.change_title(tour, value)
  tour = tour or actions.pick_tour("Select the tour to rename", editable)
  if not tour or not can_edit(tour) then
    return
  end
  value = value or prompt_value("Enter the title for this tour: ", tour.title)
  if not value or value == "" then
    return
  end
  local old = tour.title
  tour.title = value
  tourfile.save(tour)

  -- Keep `nextTour` references to this tour working.
  for _, other in ipairs(state.tours) do
    if other ~= tour and other.nextTour == old and editable(other) then
      other.nextTour = value
      tourfile.save(other)
    end
  end
  refresh_player(tour)
end

function M.change_description(tour, value)
  tour = tour or actions.pick_tour("Select the tour to change", editable)
  if not tour or not can_edit(tour) then
    return
  end
  value = value or prompt_value("Enter the description for this tour: ", tour.description)
  if not value or value == "" then
    return
  end
  tour.description = value
  tourfile.save(tour)
end

function M.change_ref(tour)
  tour = tour or actions.pick_tour("Select the tour to change", editable)
  if not tour then
    return
  end
  if not tourfile.is_saveable(tour) then
    return util.error("You can't change the git ref of an embedded tour file.")
  end
  if not can_edit(tour) then
    return
  end
  local root = root_for(tour)
  if not require("codetour.git").repository(root) then
    return util.warn("The tour's workspace isn't a git repository.")
  end
  local ref = M.prompt_for_ref(root)
  if not ref then
    return
  end
  tour.ref = ref ~= "HEAD" and ref or nil
  tourfile.save(tour)
  refresh_player(tour)
end

function M.make_primary(tour)
  tour = tour or actions.pick_tour("Select the primary tour", editable)
  if not tour or not can_edit(tour) then
    return
  end
  tour.isPrimary = true
  tourfile.save(tour)
  for _, other in ipairs(state.tours) do
    if other.id ~= tour.id and other.isPrimary and editable(other) then
      other.isPrimary = nil
      tourfile.save(other)
    end
  end
end

function M.unmake_primary(tour)
  tour = tour or actions.pick_tour("Select the tour", function(t)
    return t.isPrimary == true and editable(t)
  end)
  if not tour or not can_edit(tour) then
    return
  end
  tour.isPrimary = nil
  tourfile.save(tour)
end

--- Deletes tour files after confirming.
function M.delete_tours(tours)
  if not tours or #tours == 0 then
    local tour = actions.pick_tour("Select the tour to delete", editable)
    tours = tour and { tour } or {}
  end
  tours = vim.tbl_filter(editable, tours)
  if #tours == 0 then
    return
  end

  local plural = #tours > 1
  local prompt = plural and ("Are you sure you want to delete the %d selected tours?"):format(#tours)
    or ('Are you sure you want to delete the "%s" tour?'):format(tours[1].title)
  if not async.confirm(prompt, plural and ("Delete %d Tours"):format(#tours) or "Delete Tour") then
    return
  end

  for _, tour in ipairs(tours) do
    if state.is_active(tour) then
      actions.end_tour()
    end
    local ok, err = os.remove(tour.id)
    if not ok then
      util.error("Unable to delete " .. tour.id .. ": " .. tostring(err))
    end
  end
  require("codetour.discovery").discover()
end

--- Exports a tour with the contents of its files embedded.
function M.export_tour(tour, path)
  tour = tour or actions.pick_tour("Select the tour to export")
  if not tour then
    return
  end
  if not path or path == "" then
    path = async.input({
      prompt = "Export tour to: ",
      default = tourfile.file_name(tour.title),
      completion = "file",
    })
    if not path or path == "" then
      return
    end
  end
  path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  local ok, err = util.write_file(path, tourfile.export(tour))
  if ok then
    util.notify("Exported the tour to " .. path)
  else
    util.error("Unable to export the tour: " .. tostring(err))
  end
end

return M
