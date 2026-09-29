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

local function list_directory(dir, files)
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
      list_directory(path, files)
    elseif entry.kind == "file" or entry.kind == "link" then
      files[#files + 1] = path
    end
  end
end

--- Lists the files in a workspace folder that may contain tours (like VS
--- Code, every file in the tour directories is tried).
function M.tour_files(root)
  local files = {}
  for _, directory in ipairs(M.directories(root)) do
    list_directory(util.join(root, directory), files)
  end
  for _, file in ipairs(M.MAIN_TOUR_FILES) do
    local path = util.join(root, file)
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type == "file" then
      files[#files + 1] = path
    end
  end
  return files
end

--- Reads every tour in a workspace folder.
function M.find_tours(root)
  local tours = {}
  for _, path in ipairs(M.tour_files(root)) do
    local tour = tourfile.read(path)
    if tour then
      tours[#tours + 1] = tour
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

--- Reads the tours of every workspace folder, sorted by title.
---@param opts? { all?: boolean } include tours hidden by their `when` clause
function M.load(opts)
  local tours = {}
  for _, root in ipairs(util.roots()) do
    vim.list_extend(tours, M.find_tours(root))
  end
  if not (opts and opts.all) then
    tours = vim.tbl_filter(is_visible, tours)
  end
  table.sort(tours, compare_titles)
  for _, tour in ipairs(tours) do
    M.update_marker_titles(tour)
  end
  return tours
end

--- Re-discovers the workspace's tours and updates the store.
function M.discover()
  local tours = M.load()
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

function M.find_by_id(id, tours)
  for _, tour in ipairs(tours or state.tours) do
    if tour.id == id then
      return tour
    end
  end
end

return M
