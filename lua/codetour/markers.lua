-- Tour markers: signs on lines that belong to a tour step, so tours can be
-- discovered while browsing code (VS Code's gutter decorator + hover).

local config = require("codetour.config")
local state = require("codetour.state")
local util = require("codetour.util")

local M = {}

local ns = vim.api.nvim_create_namespace("codetour_markers")

---@type table<integer, { tour: codetour.Tour, step: codetour.Step, index: integer, line: integer }[]>
local cache = {}

function M.enabled()
  if state.show_markers == nil then
    state.show_markers = config.setting("show_markers", util.roots()[1]) ~= false
  end
  return state.show_markers
end

local function same_file(step_path, path, real)
  if step_path == path then
    return true
  end
  return vim.fs.basename(step_path) == vim.fs.basename(path) and util.realpath(step_path) == real
end

--- Returns the tour steps located in a buffer.
function M.steps_for(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    return {}
  end
  local path = util.normalize(name)
  local real
  local lines
  local result = {}

  for _, tour in ipairs(state.tours) do
    local root = util.tour_root(tour)
    for index, step in ipairs(tour.steps) do
      local step_path
      if step.file and not step.contents then
        step_path = util.join(root, step.file)
      elseif step.uri and step.uri:match("^file://") then
        step_path = util.normalize(vim.uri_to_fname(step.uri))
      end
      if step_path then
        if not real and vim.fs.basename(step_path) == vim.fs.basename(path) then
          real = util.realpath(path)
        end
        if same_file(step_path, path, real) then
          local line
          if step.line then
            line = step.line - 1
          elseif step.pattern then
            lines = lines or vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            line = require("codetour.regex").find_line(lines, step.pattern)
          elseif step.selection then
            line = step.selection["end"].line - 1
          end
          if line then
            result[#result + 1] = { tour = tour, step = step, index = index - 1, line = line }
          end
        end
      end
    end
  end
  return result
end

function M.refresh(buf)
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then
    cache[buf] = nil
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  cache[buf] = nil
  if not M.enabled() or #state.tours == 0 then
    return
  end

  local steps = M.steps_for(buf)
  cache[buf] = steps
  local count = vim.api.nvim_buf_line_count(buf)
  local opts = config.get().markers
  for _, item in ipairs(steps) do
    if item.line >= 0 and item.line < count then
      local mark = {
        sign_text = opts.sign,
        sign_hl_group = "CodeTourMarker",
        priority = 5,
      }
      if opts.virtual_text then
        mark.virt_text = {
          { ("CodeTour: %s (Step #%d)"):format(item.tour.title, item.index + 1), "CodeTourMarkerText" },
        }
        mark.virt_text_pos = "eol"
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, item.line, 0, mark)
    end
  end
end

--- Refreshes the markers of every buffer shown in a window.
function M.refresh_all()
  local seen = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if not seen[buf] then
      seen[buf] = true
      M.refresh(buf)
    end
  end
  for buf in pairs(cache) do
    if not seen[buf] then
      M.refresh(buf)
    end
  end
end

function M.set_enabled(enabled)
  state.show_markers = enabled
  M.refresh_all()
  state.changed()
end

function M.toggle()
  M.set_enabled(not M.enabled())
end

--- The steps attached to the cursor line.
function M.steps_at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local steps = cache[buf] or M.steps_for(buf)
  return vim.tbl_filter(function(item)
    return item.line == line
  end, steps)
end

--- Starts the tour step attached to the cursor line (the "Start Tour" link
--- in VS Code's marker hover).
function M.start_at_cursor()
  local steps = M.steps_at_cursor()
  if #steps == 0 then
    return util.notify("There is no tour step on this line.")
  end
  local item = steps[1]
  if #steps > 1 then
    item = require("codetour.async").select(steps, {
      prompt = "Select the tour to start",
      format_item = function(entry)
        return ("CodeTour: %s (Step #%d)"):format(entry.tour.title, entry.index + 1)
      end,
    })
    if not item then
      return
    end
  end
  require("codetour.actions").start_tour(item.tour, item.index)
end

function M.namespace()
  return ns
end

state.subscribe(function()
  if state.discovered then
    M.refresh_all()
  end
end)

return M
