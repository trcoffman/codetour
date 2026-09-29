local config = require("codetour.config")

local M = {}

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "CodeTour" })
end

function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

-- Paths ----------------------------------------------------------------

local function is_absolute(path)
  return path:sub(1, 1) == "/" or path:match("^%a:/") ~= nil
end

--- Normalizes a path and resolves "." and ".." segments.
function M.normalize(path)
  path = vim.fs.normalize(path)
  local prefix = ""
  if path:sub(1, 1) == "/" then
    prefix = "/"
  elseif path:match("^%a:/") then
    prefix = path:sub(1, 3)
    path = path:sub(4)
  end

  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        parts[#parts] = nil
      elseif prefix == "" then
        parts[#parts + 1] = ".."
      end
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return prefix .. table.concat(parts, "/")
end

--- Joins a workspace root with a (usually relative) path from a tour file.
function M.join(root, path)
  path = vim.fs.normalize(path)
  if is_absolute(path) or not root or root == "" then
    return M.normalize(path)
  end
  return M.normalize(root .. "/" .. path)
end

--- Mirrors Node's `path.relative(from, to)` with forward slashes.
function M.relative(from, to)
  from, to = M.normalize(from), M.normalize(to)
  if from == to then
    return ""
  end

  local a, b = vim.split(from, "/", { trimempty = true }), vim.split(to, "/", { trimempty = true })
  local common = 0
  while common < #a and common < #b and a[common + 1] == b[common + 1] do
    common = common + 1
  end

  local parts = {}
  for _ = common + 1, #a do
    parts[#parts + 1] = ".."
  end
  for i = common + 1, #b do
    parts[#parts + 1] = b[i]
  end
  return table.concat(parts, "/")
end

function M.realpath(path)
  return vim.uv.fs_realpath(path) or M.normalize(path)
end

function M.same_path(a, b)
  if not a or not b then
    return false
  end
  return M.normalize(a) == M.normalize(b) or M.realpath(a) == M.realpath(b)
end

function M.read_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  return content
end

function M.write_file(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd, err = io.open(path, "wb")
  if not fd then
    return false, err
  end
  fd:write(content)
  fd:close()
  return true
end

function M.is_url(str)
  return str:match("^%a[%w+.-]*://") ~= nil and not str:match("^file://")
end

-- Workspace ------------------------------------------------------------

--- The workspace folders tours are discovered in.
function M.roots()
  local roots = config.get().roots
  if type(roots) == "function" then
    roots = roots()
  end
  if type(roots) == "string" then
    roots = { roots }
  end
  if not roots or #roots == 0 then
    roots = { vim.fn.getcwd() }
  end
  return vim.tbl_map(function(root)
    return M.normalize(vim.fn.fnamemodify(root, ":p"))
  end, roots)
end

--- Returns the workspace folder a tour belongs to (VS Code's getWorkspaceUri).
function M.tour_root(tour)
  local roots = M.roots()
  if tour and tour.id and not M.is_url(tour.id) then
    local id = M.normalize(tour.id)
    local best
    for _, root in ipairs(roots) do
      if id:sub(1, #root + 1) == root .. "/" and (not best or #root > #best) then
        best = root
      end
    end
    if best then
      return best
    end
  end
  return roots[1]
end

-- Titles and labels ------------------------------------------------------

--- Strips a "1 - " style prefix from a tour title (VS Code's getTourTitle).
function M.tour_title(tour)
  -- Deliberately mirrors the VS Code implementation (including only keeping
  -- the text up to the next "-") so tour references resolve identically.
  if tour.title:match("^#?%d+%s%-") then
    local parts = vim.split(tour.title, "-", { plain = true })
    return vim.trim(parts[2] or "")
  end
  return tour.title
end

function M.tour_number(tour)
  local number = tour.title:match("^#?(%d+)%s+%-")
  return number and tonumber(number)
end

local function decode_uri_component(str)
  local ok, result = pcall(function()
    return (str:gsub("%%(%x%x)", function(hex)
      return string.char(tonumber(hex, 16))
    end))
  end)
  return ok and result or str
end

--- Label shown for a step in the tree and in navigation links.
---@param tour codetour.Tour
---@param index integer 0-based
function M.step_label(tour, index, include_number, default_to_file)
  if include_number == nil then
    include_number = true
  end
  if default_to_file == nil then
    default_to_file = true
  end

  local step = tour.steps[index + 1]
  local prefix = include_number and ("#%d - "):format(index + 1) or ""
  local label = ""
  local heading = vim.trim(step.description or ""):match("^#+%s*([^\n]*)")
  if step.title and step.title ~= "" then
    label = step.title
  elseif heading then
    label = heading
  elseif step.markerTitle then
    label = step.markerTitle
  elseif default_to_file then
    label = step.uri or decode_uri_component(step.directory or step.file or "")
  end

  return prefix .. label
end

-- Step markers (e.g. `// CT1.2 - Title` comments) -------------------------

function M.step_marker_prefix(tour)
  if tour.stepMarker and tour.stepMarker ~= "" then
    return tour.stepMarker
  end
  local number = M.tour_number(tour)
  if number then
    return "CT" .. number
  end
end

function M.is_marker_step(tour, index)
  local step = tour.steps[index + 1]
  return M.step_marker_prefix(tour) ~= nil and step.file ~= nil and step.line == nil
end

--- The JS pattern used to locate a marker step (e.g. "CT1.3").
function M.step_marker(tour, index)
  if M.is_marker_step(tour, index) then
    return ("%s.%d"):format(M.step_marker_prefix(tour), index + 1)
  end
end

-- Character offsets --------------------------------------------------------
-- Tour selections store VS Code positions, whose columns count UTF-16 code
-- units. Neovim works with byte offsets.

--- Converts a 0-based byte offset into a 0-based UTF-16 offset.
function M.byte_to_utf16(line, byte)
  local units, i = 0, 1
  while i <= byte and i <= #line do
    local b = line:byte(i)
    local len = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1
    if i + len - 1 > byte then
      break
    end
    units = units + (len == 4 and 2 or 1)
    i = i + len
  end
  return units
end

--- Converts a 0-based UTF-16 offset into a 0-based byte offset.
function M.utf16_to_byte(line, units)
  local count, i = 0, 1
  while i <= #line and count < units do
    local b = line:byte(i)
    local len = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1
    count = count + (len == 4 and 2 or 1)
    i = i + len
  end
  return math.min(i - 1, #line)
end

--- Converts a step selection into 0-based, end-exclusive byte positions.
---@return integer start_row, integer start_col, integer end_row, integer end_col
function M.selection_range(buf, selection)
  local count = vim.api.nvim_buf_line_count(buf)
  local function position(pos)
    local row = math.max(0, math.min(pos.line - 1, count - 1))
    local text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    return row, M.utf16_to_byte(text, math.max(0, pos.character - 1))
  end
  local sr, sc = position(selection.start)
  local er, ec = position(selection["end"])
  return sr, sc, er, ec
end

--- Builds a step selection (1-based VS Code positions) from byte positions.
function M.make_selection(buf, sr, sc, er, ec)
  local function line(row)
    return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  end
  local json = require("codetour.json")
  return json.object({
    start = json.object({ line = sr + 1, character = M.byte_to_utf16(line(sr), sc) + 1 }, { "line", "character" }),
    ["end"] = json.object({ line = er + 1, character = M.byte_to_utf16(line(er), ec) + 1 }, { "line", "character" }),
  }, { "start", "end" })
end

return M
