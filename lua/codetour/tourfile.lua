-- Reading, writing and exporting *.tour files.

local json = require("codetour.json")
local util = require("codetour.util")

local M = {}

M.SCHEMA_URL = "https://aka.ms/codetour-schema"

-- Order used for keys that were not present when the file was read.
M.PREFERRED_KEYS = {
  "$schema",
  "title",
  "description",
  "file",
  "directory",
  "uri",
  "view",
  "selection",
  "line",
  "pattern",
  "contents",
  "icon",
  "commands",
  "ref",
  "isPrimary",
  "nextTour",
  "stepMarker",
  "when",
  "steps",
  "start",
  "end",
  "character",
}

--- Parses tour JSON and validates its shape.
---@return codetour.Tour|nil tour
---@return string|nil err
function M.parse(content, id)
  local ok, tour = pcall(json.decode, content)
  if not ok then
    return nil, tour
  end
  if type(tour) ~= "table" or json.is_array(tour) then
    return nil, "a tour must be a JSON object"
  end
  if type(tour.title) ~= "string" then
    return nil, "a tour must have a title"
  end
  if type(tour.steps) ~= "table" or not json.is_array(tour.steps) then
    return nil, "a tour must have a steps array"
  end
  for _, step in ipairs(tour.steps) do
    if type(step) ~= "table" then
      return nil, "tour steps must be objects"
    end
    if type(step.description) ~= "string" then
      step.description = ""
    end
  end
  tour.id = id
  return tour
end

--- Reads a tour file.
---@return codetour.Tour|nil tour
---@return string|nil err
function M.read(path)
  path = util.normalize(vim.fn.fnamemodify(path, ":p"))
  local content = util.read_file(path)
  if not content then
    return nil, "unable to read " .. path
  end
  return M.parse(content, path)
end

--- Serializes a tour the way the VS Code extension saves it.
function M.encode(tour, opts)
  local copy = json.copy(tour)
  copy.id = nil
  for _, step in ipairs(copy.steps or {}) do
    step.markerTitle = nil
  end

  if not (opts and opts.schema == false) then
    -- Like VS Code's `{ $schema, ...tour }`: the schema always comes first.
    local ordered = { "$schema" }
    for _, key in ipairs(json.keys(copy, M.PREFERRED_KEYS)) do
      if key ~= "$schema" then
        ordered[#ordered + 1] = key
      end
    end
    copy["$schema"] = copy["$schema"] or M.SCHEMA_URL
    json.object(copy, ordered)
  end

  return json.encode(copy, { preferred_keys = M.PREFERRED_KEYS })
end

function M.is_saveable(tour)
  return tour.id ~= nil and not util.is_url(tour.id)
end

--- Writes a tour back to its file.
---@return boolean ok
function M.save(tour)
  if not M.is_saveable(tour) then
    util.error("This tour can't be saved because it wasn't opened from a file.")
    return false
  end
  local ok, err = util.write_file(tour.id, M.encode(tour))
  if not ok then
    util.error("Unable to save tour: " .. tostring(err))
    return false
  end
  M.reload_buffers(tour.id)
  require("codetour.state").changed()
  return true
end

--- Reloads buffers showing a file the plugin just wrote (with 'autoread',
--- unmodified buffers are updated; modified ones get Neovim's usual warning).
function M.reload_buffers(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and util.same_path(vim.api.nvim_buf_get_name(buf), path) then
      pcall(vim.cmd.checktime, buf)
    end
  end
end

--- Creates a new, empty tour file.
---@return codetour.Tour|nil
function M.create(path, title, ref)
  local tour = { ["$schema"] = M.SCHEMA_URL, title = title, steps = json.array() }
  local keys = { "$schema", "title", "steps" }
  if ref and ref ~= "HEAD" then
    tour.ref = ref
    keys[#keys + 1] = "ref"
  end
  json.object(tour, keys)

  local ok, err = util.write_file(path, json.encode(tour))
  if not ok then
    util.error("Unable to create tour: " .. tostring(err))
    return nil
  end
  tour.id = util.normalize(path)
  return tour
end

--- Reads the text of a step's file, honoring the tour's git ref.
function M.read_step_file(tour, step, root)
  local path = util.join(root or util.tour_root(tour), step.file)
  local use_ref, repo = require("codetour.git").should_use_ref(path, tour.ref)
  if use_ref then
    local content = require("codetour.git").show(path, tour.ref, repo)
    if content then
      return content
    end
  end
  return util.read_file(path)
end

--- Returns a copy of the tour with the contents of every file embedded, so
--- it can be played back without the original code (VS Code's exportTour).
---@return string
function M.export(tour)
  local copy = json.copy(tour)
  local root = util.tour_root(tour)
  for _, step in ipairs(copy.steps) do
    step.markerTitle = nil
    if not (step.contents or step.uri or not step.file) then
      local contents = M.read_step_file(tour, step, root)
      if contents then
        step.contents = contents
      end
    end
  end
  copy.id = nil
  copy.ref = nil
  return M.encode(copy, { schema = false })
end

--- Where a new tour with this title is saved in a workspace folder.
function M.path_for(root, title)
  local directory = require("codetour.config").setting("custom_tour_directory", root)
  if type(directory) ~= "string" or directory == "" then
    directory = ".tours"
  end
  return util.join(root, directory .. "/" .. M.file_name(title))
end

--- Converts a title into the file name used for a new tour.
function M.file_name(title)
  return title:lower():gsub("%s", "-"):gsub("[^%w%-_]", "") .. ".tour"
end

return M
