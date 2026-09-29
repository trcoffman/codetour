-- Converts "CodeTour-flavored markdown" into regular markdown for the step
-- window (a port of VS Code's generatePreviewContent). The result is rendered
-- by whatever markdown renderer is installed (e.g. render-markdown.nvim).
--
--   >> npm test          run a shell command in a terminal
--   [#2] / [text][#2]    navigate to a step of the current tour
--   [Tour] / [Tour#2]    start another tour (optionally at a step)
--   [text](./file)       open a workspace file
--   [text](command:x?[]) run a command
--   ```lang ... ```      offer to insert the snippet into the step's file
--
-- Every link points at `codetour:<id>`, where `<id>` indexes the action table
-- returned alongside the markdown. Keeping the (concealed) destinations short
-- matters because Neovim wraps lines as if concealed text was visible.

local util = require("codetour.util")

local M = {}

M.SCHEME = "codetour:"

local Builder = {}
Builder.__index = Builder

--- Creates a markdown builder that collects link actions.
function M.builder()
  return setmetatable({ parts = {}, actions = {} }, Builder)
end

function Builder:text(str)
  self.parts[#self.parts + 1] = str
  return self
end

function M.escape_label(label)
  return (label:gsub("[%[%]\\]", "\\%0"))
end

--- Appends a link that runs `action` when activated.
function Builder:link(label, action)
  self.actions[#self.actions + 1] = action
  return self:text(("[%s](%s%d)"):format(M.escape_label(label), M.SCHEME, #self.actions))
end

--- Appends an image whose target is opened by `action`.
function Builder:image(label, action)
  self.actions[#self.actions + 1] = action
  return self:text(("![%s](%s%d)"):format(M.escape_label(label), M.SCHEME, #self.actions))
end

function Builder:markdown()
  return table.concat(self.parts)
end

function Builder:lines()
  return vim.split(self:markdown(), "\n", { plain = true })
end

-- Commands --------------------------------------------------------------

local function url_decode(str)
  return (str:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Parses the arguments of a command link or step command.
function M.parse_command_args(raw)
  if not raw or raw == "" then
    return {}
  end
  if raw:find("%%%x%x") then
    raw = url_decode(raw)
  end
  local ok, value = pcall(vim.json.decode, raw)
  if not ok then
    return { raw }
  end
  if type(value) == "table" and vim.islist(value) then
    return value
  end
  return { value }
end

--- Parses a command string such as `codetour.navigateToStep?2`.
function M.parse_command(str)
  local name, raw = str:match("^([^?]+)%?(.*)$")
  return { type = "command", name = name or str, args = M.parse_command_args(raw) }
end

--- Resolves a link destination into an action.
---@param dest string|{ command: string, args?: string }
---@param ctx { root?: string, actions?: table[] }
function M.resolve(dest, ctx)
  if type(dest) == "table" then
    return { type = "command", name = dest.command, args = M.parse_command_args(dest.args) }
  end
  local id = dest:match("^" .. M.SCHEME .. "(%d+)$")
  if id then
    return ctx.actions and ctx.actions[tonumber(id)]
  end
  if dest == "" or dest:sub(1, 1) == "#" then
    return nil
  end
  if dest:match("^command:") then
    return M.parse_command(dest:sub(9))
  end
  if dest:match("^%a[%w+.-]*:") and not dest:match("^%a:[/\\]") then
    if dest:match("^file://") then
      return { type = "file", path = vim.uri_to_fname(dest) }
    end
    return { type = "url", url = dest }
  end
  return { type = "file", path = util.join(ctx.root, url_decode(dest)) }
end

-- Inline parsing ------------------------------------------------------------

local function find_bracket_end(line, i)
  local depth, j = 0, i
  while j <= #line do
    local c = line:sub(j, j)
    if c == "\\" then
      j = j + 2
    else
      if c == "[" then
        depth = depth + 1
      elseif c == "]" then
        depth = depth - 1
        if depth == 0 then
          return j
        end
      end
      j = j + 1
    end
  end
end

-- Parses `[text](destination "title")` starting at the "[" at index `i`.
-- Command destinations keep VS Code's quirk of allowing unencoded JSON
-- arguments (e.g. `command:foo?["a b"]`).
local function parse_inline_link(line, i)
  local text_end = find_bracket_end(line, i)
  if not text_end or line:sub(text_end + 1, text_end + 1) ~= "(" then
    return nil
  end
  local text = line:sub(i + 1, text_end - 1)
  local j = text_end + 2
  j = j + #line:match("^%s*", j)

  local dest
  if line:sub(j, j + 7) == "command:" then
    local name = line:match("^command:([%w_%.%+%-]+)", j)
    if not name then
      return nil
    end
    j = j + 8 + #name
    local args
    if line:sub(j, j) == "?" then
      j = j + 1
      if line:sub(j, j) == "[" then
        local close = line:find("]", j, true)
        if not close then
          return nil
        end
        args = line:sub(j, close)
        j = close + 1
      else
        args = line:match("^[^%s%)]*", j)
        j = j + #args
      end
    end
    dest = { command = name, args = args }
  elseif line:sub(j, j) == "<" then
    local close = line:find(">", j, true)
    if not close then
      return nil
    end
    dest = line:sub(j + 1, close - 1)
    j = close + 1
  else
    local depth, k = 0, j
    while k <= #line do
      local c = line:sub(k, k)
      if c == "\\" then
        k = k + 2
      elseif c == "(" then
        depth = depth + 1
        k = k + 1
      elseif c == ")" then
        if depth == 0 then
          break
        end
        depth = depth - 1
        k = k + 1
      elseif c:match("%s") then
        break
      else
        k = k + 1
      end
    end
    dest = line:sub(j, k - 1)
    j = k
  end

  j = j + #line:match("^%s*", j)
  local quote = line:sub(j, j)
  if quote == '"' or quote == "'" then
    local close = line:find(quote, j + 1, true)
    if not close then
      return nil
    end
    j = close + 1
    j = j + #line:match("^%s*", j)
  end

  if line:sub(j, j) ~= ")" then
    return nil
  end
  return { text = text, dest = dest, start = i, stop = j }
end

local function find_tour(title, ctx)
  for _, tour in ipairs(ctx.tours or {}) do
    if util.tour_title(tour) == title then
      return tour
    end
  end
end

-- Resolves the inner text of a `[Tour#2]` / `[#2]` reference.
local function resolve_reference(inner, link_title, ctx)
  if not inner:match("^%s*[^%]%s]") then
    return nil
  end
  local title, step = inner:match("^([^#]*)#(%d+)$")
  if not title then
    if inner:find("#", 1, true) then
      return nil
    end
    title = inner
  end

  if title == "" then
    return link_title or ("#" .. step), {
      type = "command",
      name = "codetour.navigateToStep",
      args = { tonumber(step) },
    }
  end

  local tour = find_tour(title, ctx)
  if not tour then
    return nil
  end
  return link_title or tour.title, {
    type = "command",
    name = "codetour.startTourByTitle",
    args = step and { tour.title, tonumber(step) } or { tour.title },
  }
end

-- Parses `[text][ref]` or `[ref]` (not followed by "(") at index `i`.
-- Returns label, action and the index of the closing bracket; an unresolved
-- but well-formed reference returns only the index so it's skipped.
local function parse_reference(line, i, ctx)
  local first_end = line:find("]", i + 1, true)
  if not first_end or first_end == i + 1 then
    return nil
  end
  local first = line:sub(i + 1, first_end - 1)
  if first:find("[", 1, true) then
    return nil
  end
  local after = line:sub(first_end + 1, first_end + 1)
  if after == "(" then
    return nil
  end

  if after == "[" then
    local second_end = line:find("]", first_end + 2, true)
    if second_end and line:sub(second_end + 1, second_end + 1) ~= "(" then
      local second = line:sub(first_end + 2, second_end - 1)
      if second:match("^%s*[^%]%s]") then
        local label, action = resolve_reference(second, first, ctx)
        if label then
          return label, action, second_end
        end
        return nil, nil, second_end
      end
    end
  end

  local label, action = resolve_reference(first, nil, ctx)
  if label then
    return label, action, first_end
  end
end

-- The label of a link, with nested links/images reduced to their text.
local function link_label(text)
  text = text:gsub("!?%[([^%]]*)%]%b()", "%1")
  return (text:gsub("\\([%[%]\\])", "%1"))
end

local function transform_line(b, line, ctx)
  local i, n = 1, #line
  local plain = 1

  local function flush(upto)
    if upto >= plain then
      b:text(line:sub(plain, upto))
    end
  end

  while i <= n do
    local c = line:sub(i, i)
    if c == "\\" then
      i = i + 2
    elseif c == "`" then
      local ticks = line:match("^`+", i)
      local close = line:find(ticks, i + #ticks, true)
      i = close and close + #ticks or i + #ticks
    elseif c == "!" and line:sub(i + 1, i + 1) == "[" then
      local link = parse_inline_link(line, i + 1)
      local action = link and type(link.dest) == "string" and M.resolve(link.dest, ctx)
      if action then
        flush(i - 1)
        action.image = action.type == "file" or nil
        b:image(link_label(link.text), action)
        plain = link.stop + 1
      end
      i = link and link.stop + 1 or i + 1
    elseif c == "[" then
      local link = parse_inline_link(line, i)
      if link then
        local action = M.resolve(link.dest, ctx)
        if action then
          flush(i - 1)
          b:link(link_label(link.text), action)
          plain = link.stop + 1
        end
        i = link.stop + 1
      else
        local label, action, stop = parse_reference(line, i, ctx)
        if label then
          flush(i - 1)
          b:link(label, action)
          plain = stop + 1
        end
        i = stop and stop + 1 or i + 1
      end
    else
      i = i + 1
    end
  end
  flush(n)
end

--- Converts a step description into markdown.
---@param text string
---@param ctx { root?: string, tours?: codetour.Tour[] }
---@param b? table builder to append to
function M.render(text, ctx, b)
  b = b or M.builder()
  local fence
  local code = {}
  local first = true

  for line in vim.gsplit(text or "", "\n", { plain = true }) do
    line = line:gsub("\r$", "")
    if not first then
      b:text("\n")
    end
    first = false

    if fence then
      b:text(line)
      if line:match("^%s*" .. vim.pesc(fence.marker) .. "%s*$") then
        -- Like VS Code, only fences with a language get an "Insert Code" link.
        if fence.lang then
          b:text("\n↪ ")
          b:link("Insert Code", {
            type = "command",
            name = "codetour.insertCodeSnippet",
            args = { table.concat(code, "\n") },
          })
        end
        fence = nil
        code = {}
      else
        code[#code + 1] = line
      end
    else
      local marker, info = line:match("^%s*(```+)%s*(.-)%s*$")
      if not marker then
        marker, info = line:match("^%s*(~~~+)%s*(.-)%s*$")
      end
      local script = line:match("^>>%s+(.*)$")
      if marker then
        fence = { marker = marker, lang = info ~= "" and info or nil }
        b:text(line)
      elseif script then
        b:text("> ")
        b:link(script, { type = "command", name = "codetour.sendTextToTerminal", args = { script } })
      else
        transform_line(b, line, ctx)
      end
    end
  end

  return b
end

--- Finds the links in rendered markdown lines (outside of code).
---@return { row: integer, col: integer, end_col: integer, dest: any }[] 0-based, end-exclusive
function M.links(lines)
  local links = {}
  local fence
  for row, line in ipairs(lines) do
    local marker = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
    if fence then
      if marker and line:match("^%s*" .. vim.pesc(fence) .. "%s*$") then
        fence = nil
      end
    elseif marker then
      fence = marker
    else
      local i = 1
      while i <= #line do
        local c = line:sub(i, i)
        if c == "\\" then
          i = i + 2
        elseif c == "`" then
          local ticks = line:match("^`+", i)
          local close = line:find(ticks, i + #ticks, true)
          i = close and close + #ticks or i + #ticks
        elseif c == "[" or (c == "!" and line:sub(i + 1, i + 1) == "[") then
          local start = c == "!" and i + 1 or i
          local link = parse_inline_link(line, start)
          if link then
            links[#links + 1] = { row = row - 1, col = i - 1, end_col = link.stop, dest = link.dest }
            i = link.stop + 1
          else
            i = start + 1
          end
        elseif c == "<" and line:match("^<%a[%w+.-]*:[^>%s]+>", i) then
          local url = line:match("^<([^>]+)>", i)
          links[#links + 1] = { row = row - 1, col = i - 1, end_col = i + #url + 1, dest = url }
          i = i + #url + 2
        elseif c == "h" and line:match("^https?://", i) and (i == 1 or not line:sub(i - 1, i - 1):match("[%w/]")) then
          local url = line:match("^https?://[^%s<>]+", i)
          while url:match("[%.,;:!%?'\")]$") do
            url = url:sub(1, -2)
          end
          links[#links + 1] = { row = row - 1, col = i - 1, end_col = i - 1 + #url, dest = url }
          i = i + #url
        else
          i = i + 1
        end
      end
    end
  end
  return links
end

--- Returns the link under a (0-based) position.
function M.link_at(lines, row, col)
  for _, link in ipairs(M.links(lines)) do
    if link.row == row and col >= link.col and col < link.end_col then
      return link
    end
  end
end

return M
