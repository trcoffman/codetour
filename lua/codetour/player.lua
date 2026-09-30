-- Shows the current step: opens its file at the right line and displays the
-- step description in a window anchored below that line (the equivalent of
-- the comment thread VS Code uses). Virtual lines are reserved underneath the
-- anchor line so the step window never hides code. Content steps (not
-- attached to any code) are shown as a markdown page in the code window.

local config = require("codetour.config")
local markdown = require("codetour.markdown")
local state = require("codetour.state")
local util = require("codetour.util")

local M = {}

local ns = vim.api.nvim_create_namespace("codetour_player")
local group = vim.api.nvim_create_augroup("codetour_player", { clear = true })

---@class codetour.View
---@field win? integer window showing the step's file
---@field buf? integer the step's buffer
---@field line? integer 0-based line the step window is anchored to
---@field root? string
---@field float? integer
---@field float_buf? integer buffer showing the description (the step window's or the page)
---@field page? boolean the step is shown as a page in `win` instead of a step window
---@field cursor? integer[] 0-based row and column where the cursor goes when the step is shown
---@field mode? "preview"|"edit"
---@field actions table[] link actions of the step window
---@field hidden? boolean
---@field height? integer height of the step window's text when it's fully visible
---@field layout? string how the step window was last fitted into the code window
---@field skip? integer screen lines of the step window's text scrolled out with the code
---@field border? table the step window's border characters
local view = { actions = {} }

-- Set while we close our own windows so WinClosed handlers ignore it.
local closing = false

M.EDITOR_NAME = "codetour://edit"

function M.view()
  return view
end

-- Scratch buffers ------------------------------------------------------------

local function find_buffer(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
end

--- Returns a (reused) scratch buffer called `name`.
function M.scratch_buffer(name, opts)
  opts = opts or {}
  local buf = find_buffer(name)
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
  end
  vim.bo[buf].buftype = opts.buftype or "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.b[buf].codetour_scratch = true
  -- Pickers (snacks.nvim) usually skip non-file buffers when choosing where to
  -- open a file; windows showing a step are fine targets.
  vim.b[buf].snacks_main = true
  if opts.lines and not vim.bo[buf].modified then
    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
    vim.bo[buf].modified = false
  end
  vim.bo[buf].modifiable = opts.modifiable == true
  vim.bo[buf].readonly = opts.modifiable ~= true
  if opts.filetype and vim.bo[buf].filetype ~= opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
  return buf
end

local function split_content(content)
  local lines = vim.split(content, "\n", { plain = true })
  local eol = lines[#lines] == ""
  if eol and #lines > 1 then
    lines[#lines] = nil
  end
  return lines, eol
end

local function detect_filetype(path, buf)
  local ok, ft = pcall(vim.filetype.match, { filename = path, buf = buf })
  return ok and ft or nil
end

-- Buffer for steps whose file contents are embedded in the tour (exported
-- tours). Writing it saves the contents back into the tour.
local function contents_buffer(tour, step)
  local name = "codetour://tour/" .. (step.file or "contents")
  local lines, eol = split_content(step.contents)
  local buf = M.scratch_buffer(name, { buftype = "acwrite", lines = lines, modifiable = true })
  vim.b[buf].codetour_eol = eol
  if not vim.b[buf].codetour_write_handler then
    vim.b[buf].codetour_write_handler = true
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = function()
        local active, current = state.active, state.current_step()
        if not (active and current and current.contents) then
          util.error("This buffer no longer belongs to the active tour step.")
          return
        end
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        current.contents = vim.b[buf].codetour_eol and text .. "\n" or text
        if require("codetour.tourfile").save(active.tour) then
          vim.bo[buf].modified = false
        end
      end,
    })
  end
  local ft = detect_filetype(step.file or "", buf)
  if ft and vim.bo[buf].filetype ~= ft then
    vim.bo[buf].filetype = ft
  end
  return buf
end

local function directory_buffer(root, directory)
  local path = util.join(root, directory)
  local cwd = util.normalize(vim.fn.getcwd())
  local function display(p)
    local relative = util.relative(cwd, p)
    return relative:sub(1, 3) == "../" and p or relative
  end

  local entries = {}
  local handle = vim.uv.fs_scandir(path)
  while handle do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    entries[#entries + 1] = { name = name, dir = kind == "directory" }
  end
  table.sort(entries, function(a, b)
    if a.dir ~= b.dir then
      return a.dir
    end
    return a.name:lower() < b.name:lower()
  end)

  local lines = { display(path) .. "/" }
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = display(path .. "/" .. entry.name) .. (entry.dir and "/" or "")
  end
  return M.scratch_buffer("codetour://" .. directory, { lines = lines }), path
end

---@return { buf: integer, kind: string, path?: string }
function M.resolve_target(tour, step, root)
  if step.contents then
    return { buf = contents_buffer(tour, step), kind = "contents" }
  end

  if step.uri or step.file then
    local path
    if step.uri and not step.uri:match("^file://") then
      return { buf = vim.fn.bufadd(step.uri), kind = "uri" }
    elseif step.uri then
      path = util.normalize(vim.uri_to_fname(step.uri))
    else
      path = util.join(root, step.file)
    end

    local git = require("codetour.git")
    local use_ref, repo = git.should_use_ref(path, tour.ref)
    if use_ref then
      local content, err = git.show(path, tour.ref, repo)
      if content then
        local relative = util.relative(repo.root, util.realpath(path))
        local buf = M.scratch_buffer(("codetour://%s/%s"):format(tour.ref, relative), {
          lines = (split_content(content)),
        })
        local ft = detect_filetype(path, buf)
        if ft and vim.bo[buf].filetype ~= ft then
          vim.bo[buf].filetype = ft
        end
        return { buf = buf, kind = "ref", path = path }
      end
      util.warn(("Unable to show %s at %s (%s); showing the working tree version."):format(step.file, tour.ref, err))
    end

    local buf = vim.fn.bufadd(path)
    vim.bo[buf].buflisted = true
    return { buf = buf, kind = "file", path = path }
  end

  if step.directory then
    local buf, path = directory_buffer(root, step.directory)
    return { buf = buf, kind = "directory", path = path }
  end

  -- Filled by M.render(): the step as a page, or empty behind the step editor.
  return { buf = M.scratch_buffer("codetour://CodeTour"), kind = "content" }
end

-- Line resolution -------------------------------------------------------------

local warned_patterns = {}

--- Returns the 0-based line a step is attached to (see codetour.anchor).
function M.resolve_line(tour, index, step, buf)
  vim.fn.bufload(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local line, _, problem, problem_kind = require("codetour.anchor").resolve(tour, index, lines)
  if problem_kind == "unsupported" and not warned_patterns[problem] then
    warned_patterns[problem] = true
    util.warn(problem)
  end
  return line
end

-- Windows ------------------------------------------------------------------

local function is_code_window(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  if vim.wo[win].winfixbuf then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local buftype = vim.bo[buf].buftype
  return buftype == "" or buftype == "acwrite" or vim.b[buf].codetour_scratch == true
end

local function in_current_tab(win)
  return vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
end

local function create_window()
  local win = vim.api.nvim_open_win(0, false, { split = "right", win = -1 })
  for _, option in ipairs({ "number", "relativenumber", "signcolumn", "foldcolumn", "wrap", "cursorline", "list", "spell" }) do
    vim.wo[win][option] = vim.go[option]
  end
  vim.wo[win].winfixwidth = false
  vim.wo[win].winfixbuf = false
  return win
end

local function pick_window(buf)
  local wins = vim.api.nvim_tabpage_list_wins(0)
  if is_code_window(view.win) and in_current_tab(view.win) and vim.api.nvim_win_get_buf(view.win) == buf then
    return view.win
  end
  for _, win in ipairs(wins) do
    if is_code_window(win) and vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  if is_code_window(view.win) and in_current_tab(view.win) then
    return view.win
  end
  local current = vim.api.nvim_get_current_win()
  if is_code_window(current) then
    return current
  end
  local previous = vim.fn.win_getid(vim.fn.winnr("#"))
  if is_code_window(previous) then
    return previous
  end
  for _, win in ipairs(wins) do
    if is_code_window(win) then
      return win
    end
  end
  return create_window()
end

--- Moves a buffer that was opened in the step window or the tree (e.g. by a
--- file picker) to a code window, and restores the plugin's window.
---@param win integer
function M.rehome(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  -- { kind = "step"|"tree", buf = the buffer the window is meant to show }
  local guard = vim.w[win].codetour_window
  local buf = vim.api.nvim_win_get_buf(win)
  if type(guard) ~= "table" or buf == guard.buf then
    return
  end
  local stale = (guard.kind == "step" and win ~= view.float)
    or (guard.kind == "tree" and not vim.api.nvim_buf_is_valid(guard.buf))
  if stale then
    -- The window isn't ours anymore (e.g. the tree buffer was deleted).
    vim.w[win].codetour_window = nil
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  if guard.kind == "tree" then
    vim.api.nvim_win_set_buf(win, guard.buf)
  else
    -- The step window's own buffer was wiped when it was replaced; closing
    -- the window behaves like the user closing it (`:CodeTour resume` shows
    -- the step again).
    vim.api.nvim_win_close(win, true)
  end

  local target = pick_window(buf)
  vim.api.nvim_win_set_buf(target, buf)
  pcall(vim.api.nvim_win_set_cursor, target, cursor)
  vim.api.nvim_set_current_win(target)
end

local function show_buffer(win, buf)
  if vim.api.nvim_win_get_buf(win) == buf then
    return
  end
  -- Record a jump so <C-o> returns to where the user was.
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! m'")
  end)
  vim.api.nvim_win_set_buf(win, buf)
end

-- Step window content -----------------------------------------------------

local function command(name, args)
  return { type = "command", name = name, args = args or {} }
end

local function previous_tour(tour)
  for _, other in ipairs(state.tours) do
    if other.nextTour == tour.title then
      return other
    end
  end
  local number = tour.title:match("^#?(%d+)%s+%-")
  if number then
    local target = "^#?" .. (tonumber(number) - 1) .. "%s+[-:]"
    for _, other in ipairs(state.tours) do
      if other.title:match(target) then
        return other
      end
    end
  end
end

local function next_tour(tour)
  if tour.nextTour then
    for _, other in ipairs(state.tours) do
      if other.title == tour.nextTour then
        return other
      end
    end
    return nil
  end
  local number = util.tour_number(tour)
  if number then
    local target = "^#?" .. (number + 1) .. "%s+[-:]"
    for _, other in ipairs(state.tours) do
      if other.title:match(target) then
        return other
      end
    end
  end
end

M.previous_tour = previous_tour
M.next_tour = next_tour

--- Builds the markdown shown for a step (description + navigation links).
function M.build_preview(active)
  local tour, index = active.tour, active.step
  local step = tour.steps[index + 1]
  local b = markdown.render(step.description, {
    root = active.root,
    tours = active.tours or state.tours,
  })

  local has_previous = index > 0
  local has_next = index < #tour.steps - 1
  local is_final = index == #tour.steps - 1
  if state.editing or not (has_previous or has_next or is_final) then
    return b
  end

  b:text("\n\n---\n")
  if has_previous then
    local label = util.step_label(tour, index - 1, false, false)
    b:text("← ")
    b:link("Previous" .. (label ~= "" and (" (" .. label .. ")") or ""), command("codetour.previousTourStep"))
  else
    local previous = previous_tour(tour)
    if previous then
      has_previous = true
      b:text("← ")
      b:link(("Previous Tour (%s)"):format(util.tour_title(previous)), command("codetour.startTourByTitle", { previous.title }))
    end
  end

  local separator = has_previous and " | " or ""
  if has_next then
    local label = util.step_label(tour, index + 1, false, false)
    b:text(separator)
    b:link("Next" .. (label ~= "" and (" (" .. label .. ")") or ""), command("codetour.nextTourStep"))
    b:text(" →")
  elseif is_final then
    local following = next_tour(tour)
    b:text(separator)
    if following then
      b:link(("Next Tour (%s)"):format(util.tour_title(following)), command("codetour.finishTour", { following.title }))
    else
      b:link("Finish Tour", command("codetour.finishTour"))
    end
  end
  return b
end

local function key_hints(mode)
  if mode == "edit" then
    return " :w save │ :q cancel "
  end
  local keys = config.get().player.keymaps
  local hints = {}
  local function add(key, label)
    if key then
      hints[#hints + 1] = (type(key) == "table" and key[1] or key) .. " " .. label
    end
  end
  add(keys.next, "next")
  add(keys.prev, "prev")
  add(keys.open_link, "open link")
  add(keys.hide, "hide")
  add(keys.end_tour, "end")
  if #hints == 0 then
    return nil
  end
  return " " .. table.concat(hints, " │ ") .. " "
end

local function title_for(active, mode)
  local label = ("Step #%d of %d"):format(active.step + 1, #active.tour.steps)
  if active.tour.title then
    label = label .. (" (%s)"):format(util.tour_title(active.tour))
  end
  if mode == "edit" then
    label = (active.pending and "New " or "Edit ") .. label
  elseif state.recording then
    label = "● " .. label
  end
  return " " .. label .. " "
end

local function border_rows()
  local border = config.get().player.border
  if border == "none" or border == "" or border == nil then
    return 0
  end
  return 2
end

-- Estimates how many screen rows `lines` need at `width`, ignoring the parts
-- of links that markdown renderers conceal.
local function content_height(lines, width)
  local rows = 0
  for _, line in ipairs(lines) do
    local visible = line:gsub("%]%b()", "]"):gsub("[%[%]]", "")
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(visible) / width))
  end
  return rows
end

---@param mode "preview"|"edit"|"page"
local function set_keymaps(buf, mode)
  if mode == "edit" then
    return
  end
  local keys = config.get().player.keymaps
  local function map(lhs, fn, desc)
    if not lhs then
      return
    end
    for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
      vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true, desc = "CodeTour: " .. desc })
    end
  end
  map(keys.next, function()
    require("codetour.actions").next()
  end, "Next step")
  map(keys.prev, function()
    require("codetour.actions").prev()
  end, "Previous step")
  map(keys.open_link, M.open_link, "Open link")
  map(keys.next_link, function()
    M.jump_link(1)
  end, "Next link")
  map(keys.prev_link, function()
    M.jump_link(-1)
  end, "Previous link")
  map(keys.edit, function()
    require("codetour.recorder").edit()
  end, "Edit tour")
  map(keys.hide, M.hide, "Hide step")
  map(keys.end_tour, function()
    require("codetour.actions").end_tour()
  end, "End tour")
  -- `gx` usually opens the URL under the cursor; here links point at actions.
  map("gx", M.open_link, "Open link")
  if mode == "page" then
    -- The page is in the code window already, and <C-o> works as usual.
    return
  end
  map(keys.unfocus, M.focus_code, "Focus code")
  -- The step window can't switch buffers, so jump from the code window.
  map("<C-o>", function()
    local count = vim.v.count1
    M.focus_code()
    vim.cmd(("normal! %d\15"):format(count))
  end, "Jump back in the code window")
end

--- Sets up a window showing markdown: wrapping, conceal and rendering by
--- render-markdown.nvim / markview.nvim (or treesitter highlighting).
---@param rendered boolean render the markdown (false shows the raw text, for editing)
---@param opts? { buffer_local?: boolean } set window options only for `buf` (like `:setlocal`),
--- for a window that shows other buffers too
function M.setup_markdown_window(win, buf, rendered, opts)
  local buffer_local = opts and opts.buffer_local
  local function set(name, value)
    if buffer_local then
      vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
    else
      vim.wo[win][name] = value
    end
  end
  set("wrap", true)
  set("linebreak", true)
  -- Read-only content stays concealed on the cursor line too, so moving the
  -- cursor through a step doesn't reveal link syntax.
  set("conceallevel", rendered and 2 or 0)
  set("concealcursor", rendered and "nc" or "")
  set("number", false)
  set("relativenumber", false)
  set("signcolumn", "no")
  set("foldcolumn", "0")
  set("cursorline", false)

  -- render-markdown attaches when the filetype is set, so its per-buffer
  -- config has to be registered first. Steps are rendered without its
  -- "anti-conceal" (which shows the raw cursor line); the step editor isn't
  -- rendered at all, because CodeTour's syntax (e.g. `>> cmd`) isn't regular
  -- markdown and would be rendered misleadingly.
  local ok, render_markdown = pcall(require, "render-markdown")
  if ok and type(render_markdown.render) == "function" then
    local rm_config = rendered and config.get().player.render_markdown or { enabled = false }
    pcall(render_markdown.render, { buf = buf, win = win, config = rm_config })
  end

  if vim.bo[buf].filetype ~= "markdown" then
    vim.bo[buf].filetype = "markdown"
  end
  if not vim.treesitter.highlighter.active[buf] then
    pcall(vim.treesitter.start, buf, "markdown")
  end
  -- Markdown ftplugins and user autocmds often turn spell checking on.
  set("spell", false)
end

local function create_editor_buffer(active)
  local buf = find_buffer(M.EDITOR_NAME)
  if buf then
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, M.EDITOR_NAME)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.b[buf].codetour_step = active.tour.id .. "#" .. active.step
  local description = active.tour.steps[active.step + 1].description or ""
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(description, "\n", { plain = true }))
  vim.bo[buf].modified = false

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      vim.bo[buf].modified = false
      require("codetour.recorder").save_step_description(text)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      M.relayout()
    end,
  })
  require("codetour.completion").attach(buf)
  return buf
end

local function create_preview_buffer(active)
  local b = M.build_preview(active)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, b:lines())
  vim.bo[buf].modifiable = false
  vim.b[buf].codetour_player = true
  view.actions = b.actions
  return buf
end

-- The window's 'scrolloff', limited like Neovim limits it in small windows.
local function scrolloff(win)
  local so = vim.api.nvim_get_option_value("scrolloff", { win = win })
  if so < 0 then
    so = vim.o.scrolloff
  end
  return math.max(0, math.min(so, math.floor((vim.api.nvim_win_get_height(win) - 1) / 2)))
end

local function float_geometry(win, float_buf, mode, float)
  local info = vim.fn.getwininfo(win)[1]
  local text_width = math.max(1, info.width - info.textoff)
  local max_width = config.get().player.max_width or text_width
  local width = math.max(1, math.min(max_width, text_width) - 2)
  local height = content_height(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), width)
  if float and vim.api.nvim_win_is_valid(float) then
    -- Once the window exists, measure it: this accounts for lines hidden by
    -- markdown renderers (e.g. code fences) and the real wrapping.
    if vim.api.nvim_win_get_width(float) ~= width then
      vim.api.nvim_win_set_width(float, width)
    end
    height = vim.api.nvim_win_text_height(float, {}).all
  end
  if mode == "edit" then
    height = math.max(height + 1, 5)
  end
  -- Leave room for the step's line, and for 'scrolloff' above it: otherwise
  -- Neovim scrolls the window (and the step window off the screen) to keep
  -- that many lines above the cursor.
  local max_height = math.min(config.get().player.max_height, info.height - border_rows() - 1 - scrolloff(win))
  return width, math.max(1, math.min(height, math.max(1, max_height)))
end

local function float_config(width, height, mode, active)
  local text = vim.api.nvim_win_text_height(view.win, { start_row = view.line, end_row = view.line })
  local cfg = {
    relative = "win",
    win = view.win,
    bufpos = { view.line, 0 },
    -- Explicit, as nvim_win_set_config() keeps what update_visibility() set.
    anchor = "NW",
    row = math.max(1, text.all - text.fill),
    col = 0,
    width = width,
    height = height,
    border = config.get().player.border,
    zindex = 40,
  }
  if border_rows() > 0 then
    cfg.title = { { title_for(active, mode), "CodeTourTitle" } }
    cfg.title_pos = "left"
    local hints = key_hints(mode)
    if hints then
      cfg.footer = { { hints, "CodeTourFooter" } }
      cfg.footer_pos = "right"
    end
  end
  return cfg
end

local function reserve_space(rows)
  local virt_lines = {}
  for _ = 1, rows do
    virt_lines[#virt_lines + 1] = { { "", "Normal" } }
  end
  vim.api.nvim_buf_set_extmark(view.buf, ns, view.line, 0, {
    id = 1,
    virt_lines = virt_lines,
  })
end

local function clear_decorations()
  if view.buf and vim.api.nvim_buf_is_valid(view.buf) then
    vim.api.nvim_buf_clear_namespace(view.buf, ns, 0, -1)
  end
end

local function close_float()
  if view.float and vim.api.nvim_win_is_valid(view.float) then
    closing = true
    pcall(vim.api.nvim_win_close, view.float, true)
    closing = false
  end
  view.float, view.float_buf = nil, nil
end

-- Where the space reserved for the step window is on the screen: nil while
-- it's out of view, else how many of its rows are visible and whether it's
-- cut off at the top of the window (the step's line is scrolled out of view)
-- rather than at the bottom.
---@return { rows: integer, top: boolean }?
local function reserved_space()
  -- line("w0") and line("w$") also bring the window's view up to date.
  local top, bottom = vim.fn.line("w0", view.win), vim.fn.line("w$", view.win)
  local anchor = view.line + 1
  local total = view.height + border_rows()
  if anchor >= top and anchor <= bottom then
    local pos = vim.fn.screenpos(view.win, anchor, 1)
    if pos.row == 0 then
      return nil
    end
    local info = vim.fn.getwininfo(view.win)[1]
    local last_row = info.winrow + (info.winbar or 0) + info.height - 1
    local text = vim.api.nvim_win_text_height(view.win, { start_row = view.line, end_row = view.line })
    local rows = last_row - (pos.row + text.all - text.fill) + 1
    return rows > 0 and { rows = math.min(rows, total), top = false } or nil
  end
  if anchor == top - 1 then
    -- Scrolled just past the step's line: what's left of the reserved space
    -- is shown as filler above the first line.
    local topfill = vim.api.nvim_win_call(view.win, vim.fn.winsaveview).topfill or 0
    if topfill > 0 then
      return { rows = math.min(topfill, total), top = true }
    end
  end
end

-- Keeps the step window in sync with its code window: hidden while the space
-- reserved for it is scrolled out of view or another buffer is shown, and
-- cut to the part of that space that's visible otherwise (so it scrolls with
-- the code instead of covering it).
local function update_visibility()
  if not (view.float and vim.api.nvim_win_is_valid(view.float)) then
    return
  end
  if not (view.win and vim.api.nvim_win_is_valid(view.win)) then
    return M.hide()
  end
  local space = view.height and vim.api.nvim_win_get_buf(view.win) == view.buf and reserved_space() or nil
  local border = border_rows()
  -- The window's height, and how many of its rows are scrolled out at the
  -- top: its top border first, then the first lines of the text.
  local height, clipped
  if space and not space.top then
    height, clipped = math.min(view.height, space.rows - border), 0
  elseif space then
    clipped = view.height + border - space.rows
    height = view.height - math.max(0, clipped - (border > 0 and 1 or 0))
  end
  local visible = height ~= nil and height >= 1

  if view.hidden ~= not visible then
    view.hidden = not visible
    vim.api.nvim_win_set_config(view.float, { hide = view.hidden })
    if view.hidden and vim.api.nvim_get_current_win() == view.float then
      M.focus_code()
    end
  end
  if not visible then
    return
  end

  local layout = ("%s %d %d"):format(space.top and "top" or "below", height, clipped)
  if layout == view.layout then
    return
  end
  view.layout = layout
  local cfg = float_config(vim.api.nvim_win_get_width(view.float), height, view.mode, state.active)
  if space.top then
    -- Floats can't extend above their window, so stand on the line below
    -- the reserved space, and drop what's scrolled out.
    cfg.bufpos, cfg.anchor, cfg.row = { view.line + 1, 0 }, "SW", 0
    if clipped > 0 and border > 0 and view.border then
      local b = view.border
      cfg.border = { "", "", "", b[4], b[5], b[6], b[7], b[8] }
      cfg.title = ""
    end
  end
  cfg.hide = false
  vim.api.nvim_win_set_config(view.float, cfg)

  local skip = space.top and math.max(0, clipped - (border > 0 and 1 or 0)) or 0
  if skip ~= (view.skip or 0) then
    view.skip = skip
    vim.api.nvim_win_call(view.float, function()
      vim.fn.winrestview({ topline = 1, skipcol = 0, lnum = 1, col = 0 })
      if skip > 0 then
        vim.cmd(("normal! %d\5"):format(skip))
      end
    end)
  end
end

local function watch()
  vim.api.nvim_clear_autocmds({ group = group })
  vim.api.nvim_create_autocmd({ "WinScrolled", "BufWinEnter", "BufEnter", "WinEnter" }, {
    group = group,
    callback = function()
      vim.schedule(update_visibility)
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      if vim.tbl_contains(vim.v.event.windows or {}, view.win) then
        vim.schedule(M.relayout)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local win = tonumber(ev.match)
      if closing then
        return
      end
      if win == view.float then
        view.float, view.float_buf = nil, nil
        clear_decorations()
        if view.mode == "edit" then
          vim.schedule(function()
            require("codetour.recorder").cancel_edit()
          end)
        end
      elseif win == view.win then
        vim.schedule(M.hide)
      end
    end,
  })
end

local function open_float(active, mode)
  local float_buf = mode == "edit" and create_editor_buffer(active) or create_preview_buffer(active)
  local width, height = float_geometry(view.win, float_buf, mode)
  reserve_space(height + border_rows())

  local cfg = float_config(width, height, mode, active)
  local win = vim.api.nvim_open_win(float_buf, false, cfg)
  view.float, view.float_buf, view.mode, view.hidden = win, float_buf, mode, false
  view.height, view.layout, view.skip = height, nil, 0
  -- The border as characters (whatever the configured style), to drop its
  -- top when the window is partly scrolled out of view.
  view.border = border_rows() > 0 and vim.api.nvim_win_get_config(win).border or nil

  M.setup_markdown_window(win, float_buf, mode == "preview")
  vim.wo[win].winhighlight = "NormalFloat:CodeTourFloat,FloatBorder:CodeTourBorder"
  -- Scroll by screen lines when following the code (see update_visibility()),
  -- without 'scrolloff' moving the view back to the cursor.
  vim.wo[win].smoothscroll = true
  vim.api.nvim_set_option_value("scrolloff", 0, { scope = "local", win = win })
  -- Files opened in the step window (by `:edit`, pickers, ...) are moved to
  -- the code window, see M.rehome().
  vim.w[win].codetour_window = { kind = "step", buf = float_buf }
  set_keymaps(float_buf, mode)
end

-- Replaces the contents of a read-only scratch buffer.
local function set_scratch_lines(buf, lines)
  vim.bo[buf].readonly = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modified = false
end

local function escape_statusline(text)
  return (text:gsub("%%", "%%%%"))
end

-- Shows a content step as a page of markdown in the code window: there's no
-- code to show it next to, and a page has room for a long overview.
---@param reveal boolean show the top of the page (false keeps the view, e.g. after an edit)
local function show_page(active, win, buf, reveal)
  local saved = not reveal and vim.api.nvim_win_get_buf(win) == buf and vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local b = M.build_preview(active)
  set_scratch_lines(buf, b:lines())
  view.float_buf, view.mode, view.page, view.actions = buf, "preview", true, b.actions

  M.setup_markdown_window(win, buf, true, { buffer_local = true })
  local winbar = "%#CodeTourTitle#" .. escape_statusline(title_for(active, "preview")) .. "%*"
  local hints = key_hints("preview")
  if hints then
    winbar = winbar .. "%=%#CodeTourFooter#" .. escape_statusline(hints) .. "%*"
  end
  vim.api.nvim_set_option_value("winbar", winbar, { scope = "local", win = win })
  set_keymaps(buf, "page")
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview(saved or { lnum = 1, col = 0, topline = 1, leftcol = 0 })
  end)
end

local function page_shown()
  return view.page == true
    and view.win ~= nil
    and vim.api.nvim_win_is_valid(view.win)
    and vim.api.nvim_win_get_buf(view.win) == view.buf
end

-- Replaces the page with the buffer shown before it.
local function leave_page()
  if not page_shown() then
    return
  end
  local win = view.win
  local alternate = vim.api.nvim_win_call(win, function()
    return vim.fn.bufnr("#")
  end)
  if alternate > 0 and alternate ~= view.buf and vim.api.nvim_buf_is_valid(alternate) and not vim.b[alternate].codetour_scratch then
    vim.api.nvim_win_set_buf(win, alternate)
  else
    vim.api.nvim_win_call(win, function()
      vim.cmd.enew()
    end)
  end
end

-- Scrolls so the step line, its selection and the step window are visible.
local function reveal(step)
  local win, line = view.win, view.line
  local height = vim.api.nvim_win_get_height(win)
  local function rows(from, to)
    return vim.api.nvim_win_text_height(win, { start_row = from, end_row = to }).all
  end

  local block_top = line
  if step.selection then
    block_top = math.min(line, math.max(0, step.selection.start.line - 1))
  end

  -- The space reserved below the step line counts as filler of the *next*
  -- line, so add the step window's rows explicitly.
  local float_rows = view.height and (view.height + border_rows()) or 0

  local so = scrolloff(win)
  local anchor, target
  local block = rows(block_top, line) + float_rows
  if block <= height then
    -- Centered, but at least 'scrolloff' rows from the top when there's room.
    anchor = block_top
    target = math.min(math.max(math.floor((height - block) / 2), so), height - block)
  else
    anchor, target = line, math.max(0, height - rows(line, line) - float_rows)
  end

  local top, used = anchor, 0
  while top > 0 do
    local h = rows(top - 1, top - 1)
    if used + h > target then
      break
    end
    used = used + h
    top = top - 1
  end

  -- The cursor goes to the start of the step (see place_cursor()) unless
  -- that's scrolled out of view or closer than 'scrolloff' to the top of the
  -- window: then Neovim would scroll to make room around the cursor, and push
  -- the step window off the screen. Use the first line of the step that's
  -- far enough from the top instead.
  local function comfortable(lnum)
    -- At the top of the buffer there's nothing to scroll to.
    return lnum >= top and (top == 0 or lnum == top and so == 0 or lnum > top and rows(top, lnum - 1) >= so)
  end
  local lnum, col = unpack(view.cursor or { line, 0 })
  if not comfortable(lnum) then
    lnum = line
    for l = math.max(block_top, top), line do
      if comfortable(l) then
        lnum = l
        break
      end
    end
    local text = vim.api.nvim_buf_get_lines(view.buf, lnum, lnum + 1, false)[1] or ""
    col = #text:match("^%s*")
  end

  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = top + 1, leftcol = 0, lnum = lnum + 1, col = col, curswant = col })
  end)
end

local function place_cursor(step)
  local row, col = view.line, 0
  if step.selection then
    local sr, sc, er, ec = util.selection_range(view.buf, step.selection)
    vim.api.nvim_buf_set_extmark(view.buf, ns, sr, sc, {
      end_row = er,
      end_col = ec,
      hl_group = "CodeTourSelection",
      strict = false,
    })
    row, col = sr, sc
  else
    local text = vim.api.nvim_buf_get_lines(view.buf, row, row + 1, false)[1] or ""
    col = #text:match("^%s*")
  end
  view.cursor = { row, col }
  vim.api.nvim_win_set_cursor(view.win, { row + 1, col })
  vim.api.nvim_win_call(view.win, function()
    vim.cmd("silent! normal! zv")
  end)
end

local function run_step_extras(step, root)
  local commands = require("codetour.commands")
  if step.directory and config.get().on_directory_step then
    local ok, err = pcall(config.get().on_directory_step, util.join(root, step.directory))
    if not ok then
      util.error(tostring(err))
    end
  end
  if step.view then
    commands.focus_view(step.view)
  end
  for _, cmd in ipairs(step.commands or {}) do
    commands.run_action(markdown.parse_command(cmd))
  end
end

--- Shows the active tour's current step.
---@param opts? { focus?: boolean, navigated?: boolean, reveal?: boolean }
function M.render(opts)
  opts = opts or {}
  local active = state.active
  local step = state.current_step()
  if not (active and step) then
    return M.hide()
  end

  local current = vim.api.nvim_get_current_win()
  local was_focused = (view.float ~= nil and current == view.float) or (page_shown() and current == view.win)
  local target = M.resolve_target(active.tour, step, active.root)
  local win = pick_window(target.buf)
  local ok, err = pcall(show_buffer, win, target.buf)
  if not ok then
    util.error("Unable to open the step's file: " .. tostring(err))
    return
  end

  close_float()
  clear_decorations()
  view.win, view.buf, view.root, view.page = win, target.buf, active.root, nil
  local mode = (state.recording and state.editing) and "edit" or "preview"

  if target.kind == "content" and mode == "preview" then
    show_page(active, win, target.buf, opts.reveal ~= false)
    watch()
    if was_focused or (opts.focus and config.get().player.focus) or not vim.api.nvim_win_is_valid(current) then
      vim.api.nvim_set_current_win(win)
    else
      vim.api.nvim_set_current_win(current)
    end
    if opts.navigated then
      run_step_extras(step, active.root)
    end
    return
  elseif target.kind == "content" then
    -- The step editor is anchored to the (empty) first line.
    set_scratch_lines(target.buf, { "" })
    vim.api.nvim_set_option_value("winbar", "", { scope = "local", win = win })
  end

  -- Reserve space (and highlight the selection) only in the window showing
  -- the step, not in other windows showing the same buffer. The API is
  -- experimental, so it's optional.
  if vim.api.nvim__ns_set then
    pcall(vim.api.nvim__ns_set, ns, { wins = { win } })
  end
  view.line = M.resolve_line(active.tour, active.step, step, target.buf)

  open_float(active, mode)
  if opts.reveal ~= false then
    place_cursor(step)
    reveal(step)
  elseif step.selection then
    local sr, sc, er, ec = util.selection_range(view.buf, step.selection)
    vim.api.nvim_buf_set_extmark(view.buf, ns, sr, sc, { end_row = er, end_col = ec, hl_group = "CodeTourSelection", strict = false })
  end
  watch()

  if mode == "edit" then
    vim.api.nvim_set_current_win(view.float)
    if active.pending and vim.api.nvim_buf_get_lines(view.float_buf, 0, -1, false)[1] == "" then
      vim.cmd.startinsert()
    end
  elseif was_focused or (opts.focus and config.get().player.focus) then
    vim.api.nvim_set_current_win(view.float)
  elseif vim.api.nvim_win_is_valid(current) then
    vim.api.nvim_set_current_win(current)
  else
    vim.api.nvim_set_current_win(win)
  end

  if opts.navigated then
    run_step_extras(step, active.root)
  end
  update_visibility()

  -- Lay out again once the code window was redrawn (its sign column may have
  -- appeared) and once markdown renderers have processed the step. If that
  -- changes the height, scroll again so the whole step window is visible.
  local float = view.float
  local function relayout()
    if view.float ~= float then
      return
    end
    local before = view.height
    M.relayout()
    if opts.reveal ~= false and view.height ~= before and vim.api.nvim_win_get_buf(view.win) == view.buf then
      reveal(step)
      update_visibility()
    end
  end
  vim.schedule(relayout)
  vim.defer_fn(relayout, 150)
end

--- Re-renders the step window in place (e.g. after the tour was edited),
--- without switching buffers or moving the cursor.
function M.refresh()
  if not state.active then
    return M.close()
  end
  if not (view.win and vim.api.nvim_win_is_valid(view.win)) then
    return
  end
  if view.mode == "edit" and M.has_unsaved_edits() then
    -- Don't throw away what the user is typing.
    return
  end
  local step = state.current_step()
  if not step then
    return M.hide()
  end
  local target = M.resolve_target(state.active.tour, step, state.active.root)
  if vim.api.nvim_win_get_buf(view.win) ~= target.buf then
    return M.hide()
  end
  M.render({ reveal = false })
end

--- Recomputes the size of the step window (e.g. after resizing or typing).
function M.relayout()
  if not (view.float and vim.api.nvim_win_is_valid(view.float) and state.active) then
    return
  end
  if vim.api.nvim_win_get_buf(view.float) ~= view.float_buf then
    -- A file was opened in the step window (M.rehome() moves it).
    return
  end
  if not (view.win and vim.api.nvim_win_is_valid(view.win)) or vim.api.nvim_win_get_buf(view.win) ~= view.buf then
    -- The step window is hidden while another buffer is shown.
    return
  end
  local width, height = float_geometry(view.win, view.float_buf, view.mode, view.float)
  view.height = height
  reserve_space(height + border_rows())
  local cfg = float_config(width, height, view.mode, state.active)
  cfg.hide = view.hidden
  vim.api.nvim_win_set_config(view.float, cfg)
  view.layout = nil
  update_visibility()
end

--- Closes the step window but keeps the tour active (`:CodeTour resume`
--- shows it again).
function M.hide()
  leave_page()
  close_float()
  clear_decorations()
  vim.api.nvim_clear_autocmds({ group = group })
  view.mode, view.page = nil, nil
end

--- Closes the step window and forgets the view.
function M.close()
  M.hide()
  local editor = find_buffer(M.EDITOR_NAME)
  if editor then
    pcall(vim.api.nvim_buf_delete, editor, { force = true })
  end
  view = { actions = {} }
end

function M.is_visible()
  return (view.float ~= nil and vim.api.nvim_win_is_valid(view.float)) or page_shown()
end

--- Whether the step editor has unsaved changes.
function M.has_unsaved_edits()
  local editor = find_buffer(M.EDITOR_NAME)
  return editor ~= nil and vim.api.nvim_buf_is_loaded(editor) and vim.bo[editor].modified
end

function M.focus()
  if page_shown() then
    vim.api.nvim_set_current_win(view.win)
  elseif M.is_visible() and not view.hidden then
    vim.api.nvim_set_current_win(view.float)
  end
end

function M.focus_code()
  if view.win and vim.api.nvim_win_is_valid(view.win) then
    vim.api.nvim_set_current_win(view.win)
  end
end

--- The buffer showing the step's file.
function M.step_buffer()
  return view.buf
end

function M.step_window()
  return view.win
end

-- Links --------------------------------------------------------------------

--- Activates the link under the cursor in the step window.
function M.open_link()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local link = markdown.link_at(lines, cursor[1] - 1, cursor[2])
  if not link then
    return
  end
  local action = markdown.resolve(link.dest, { root = view.root, actions = view.actions })
  if action then
    require("codetour.commands").run_action(action)
  end
end

--- Moves the cursor to the next (1) or previous (-1) link.
function M.jump_link(direction)
  local links = markdown.links(vim.api.nvim_buf_get_lines(0, 0, -1, false))
  if #links == 0 then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local target
  if direction > 0 then
    for _, link in ipairs(links) do
      if link.row > row or (link.row == row and link.col > col) then
        target = link
        break
      end
    end
    target = target or links[1]
  else
    for i = #links, 1, -1 do
      local link = links[i]
      if link.row < row or (link.row == row and link.col < col) then
        target = link
        break
      end
    end
    target = target or links[#links]
  end
  vim.api.nvim_win_set_cursor(0, { target.row + 1, target.col })
end

--- Lists the actionable links of the current step (for `:CodeTour links`).
function M.links()
  if not (view.float_buf and vim.api.nvim_buf_is_valid(view.float_buf)) or view.mode ~= "preview" then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(view.float_buf, 0, -1, false)
  local result = {}
  for _, link in ipairs(markdown.links(lines)) do
    local text = lines[link.row + 1]:sub(link.col + 1, link.end_col)
    local label = text:match("^!?%[(.-)%]%(") or text
    local action = markdown.resolve(link.dest, { root = view.root, actions = view.actions })
    if action then
      result[#result + 1] = { label = label:gsub("\\([%[%]\\])", "%1"), action = action }
    end
  end
  return result
end

--- Hides step windows and scratch buffers that belong to the tour
--- (VS Code closes its virtual documents when a tour ends).
function M.close_scratch_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[buf].codetour_scratch and not vim.bo[buf].modified then
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        local alternate = vim.api.nvim_win_call(win, function()
          return vim.fn.bufnr("#")
        end)
        if alternate > 0 and alternate ~= buf and vim.api.nvim_buf_is_valid(alternate) and not vim.b[alternate].codetour_scratch then
          vim.api.nvim_win_set_buf(win, alternate)
        elseif #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)) > 1 then
          pcall(vim.api.nvim_win_close, win, false)
        else
          vim.api.nvim_win_call(win, function()
            vim.cmd.enew()
          end)
        end
      end
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

return M
