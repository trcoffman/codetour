-- Finds the tours that belong to the workspace folders.

local config = require("codetour.config")
local state = require("codetour.state")
local tourfile = require("codetour.tourfile")
local util = require("codetour.util")

local M = {}

M.MAIN_TOUR_FILES = { ".tour", ".vscode/main.tour", "main.tour" }
M.TOUR_DIRECTORIES = { ".vscode/tours", ".github/tours", ".tours" }

function M.directories(root)
  local directories = vim.list_extend({}, M.TOUR_DIRECTORIES)
  local custom = config.setting("custom_tour_directory", root)
  if type(custom) == "string" and custom ~= "" then
    directories[#directories + 1] = custom
  end
  return directories
end

local warned = {}

local function read_tour(path, tours)
  local tour = tourfile.read(path)
  if tour then
    tours[#tours + 1] = tour
  end
end

local function read_directory(dir, tours)
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return
  end
  local entries = {}
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    entries[#entries + 1] = { name = name, kind = kind }
  end
  table.sort(entries, function(a, b)
    return a.name < b.name
  end)
  for _, entry in ipairs(entries) do
    local path = dir .. "/" .. entry.name
    if entry.kind == "directory" then
      read_directory(path, tours)
    elseif entry.kind == "file" or entry.kind == "link" then
      read_tour(path, tours)
    end
  end
end

--- Reads every tour in a workspace folder.
function M.find_tours(root)
  local tours = {}
  for _, directory in ipairs(M.directories(root)) do
    read_directory(util.join(root, directory), tours)
  end
  for _, file in ipairs(M.MAIN_TOUR_FILES) do
    local path = util.join(root, file)
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type == "file" then
      read_tour(path, tours)
    end
  end
  return tours
end

-- Approximates JavaScript's localeCompare (which VS Code sorts tours with):
-- case-insensitive, with symbols and emoji (e.g. "🏃 Getting Started")
-- sorting before letters and digits.
local function collation_key(title)
  return (title:lower():gsub(".", function(c)
    return (c:match("%w") and "\2" or "\1") .. c
  end))
end

local function compare_titles(a, b)
  local ka, kb = collation_key(a.title), collation_key(b.title)
  if ka ~= kb then
    return ka < kb
  end
  return a.title < b.title
end

local function is_visible(tour)
  if type(tour.when) ~= "string" or tour.when == "" then
    return true
  end
  local visible, err = require("codetour.when").matches(tour.when)
  if err and not warned[tour.id .. tour.when] then
    warned[tour.id .. tour.when] = true
    util.warn(("Unable to evaluate the `when` clause of %q: %s"):format(tour.title, err))
  end
  return visible
end

--- Resolves `markerTitle` for steps that are located by a step marker comment
--- (e.g. `// CT1.2 - Setup`), which the tree uses as the step label.
function M.update_marker_titles(tour)
  local prefix = util.step_marker_prefix(tour)
  if not prefix then
    return
  end
  local root = util.tour_root(tour)
  for index, step in ipairs(tour.steps) do
    if util.is_marker_step(tour, index - 1) then
      local content = tourfile.read_step_file(tour, step, root)
      local pattern = require("codetour.regex").to_vim(("%s\\.%d\\s*[-:]\\s*(.*)"):format(prefix, index))
      if content and pattern then
        for line in vim.gsplit(content, "\n", { plain = true }) do
          local match = vim.fn.matchlist(line, pattern)
          if #match > 0 then
            step.markerTitle = vim.trim(match[2])
            break
          end
        end
      end
    end
  end
end

--- Re-discovers the workspace's tours and updates the store.
function M.discover()
  local tours = {}
  for _, root in ipairs(util.roots()) do
    vim.list_extend(tours, M.find_tours(root))
  end

  tours = vim.tbl_filter(is_visible, tours)
  table.sort(tours, compare_titles)
  for _, tour in ipairs(tours) do
    M.update_marker_titles(tour)
  end

  state.tours = tours
  state.discovered = true

  local active = state.active
  local refresh = false
  if active and not active.pending and tourfile.is_saveable(active.tour) then
    local updated
    for _, tour in ipairs(tours) do
      if tour.id == active.tour.id then
        updated = tour
        break
      end
    end
    if updated then
      -- Discovery runs often (e.g. on FocusGained), so only re-render the
      -- step when the tour actually changed; re-rendering resets the step
      -- window (and its scroll position).
      refresh = tourfile.encode(updated) ~= tourfile.encode(active.tour)
      active.tour = updated
      if active.step >= #updated.steps then
        active.step = #updated.steps - 1
      end
    elseif not vim.uv.fs_stat(active.tour.id) then
      -- The file backing the active tour was deleted.
      require("codetour.actions").end_tour()
      return
    end
  end

  -- Loading the markers module subscribes it to store changes.
  require("codetour.markers")
  state.changed()
  if refresh and state.active then
    require("codetour.player").refresh()
  end
end

--- Discovers tours if that hasn't happened yet.
function M.ensure()
  if not state.discovered then
    M.discover()
  end
end

function M.find_by_id(id, tours)
  for _, tour in ipairs(tours or state.tours) do
    if tour.id == id then
      return tour
    end
  end
end

return M
