-- The CodeTour tree: a side panel listing the workspace's tours and their
-- steps (VS Code's "CodeTour" explorer view).

local config = require("codetour.config")
local state = require("codetour.state")
local storage = require("codetour.storage")
local util = require("codetour.util")

local M = {}

M.FILETYPE = "codetour-tree"
M.NAME = "codetour://tours"

local ns = vim.api.nvim_create_namespace("codetour_tree")

local tree = {
  buf = nil,
  ---@type table<integer, { tour?: codetour.Tour, step?: integer, placeholder?: boolean }>
  nodes = {},
  expanded = {},
  revealed = nil,
}

local function async(fn)
  return function(...)
    local args = { ... }
    require("codetour.async").run(function()
      fn(unpack(args))
    end)
  end
end

local function recorder()
  return require("codetour.recorder")
end

local function actions()
  return require("codetour.actions")
end

-- Rendering ---------------------------------------------------------------

local function tour_list()
  local list = vim.list_extend({}, state.tours)
  if state.active then
    local found = false
    for _, tour in ipairs(list) do
      if tour.id == state.active.tour.id then
        found = true
        break
      end
    end
    if not found then
      table.insert(list, 1, state.active.tour)
    end
  end
  return list
end

local function is_expanded(tour)
  if tree.expanded[tour.id] ~= nil then
    return tree.expanded[tour.id]
  end
  return state.is_active(tour)
end

local function tour_icon(tour)
  local icons = config.get().icons
  if state.is_recording(tour) then
    return icons.recording, "CodeTourRecording"
  elseif state.is_active(tour) then
    return icons.active, "CodeTourActive"
  elseif storage.is_complete(tour) then
    return icons.complete, "CodeTourComplete"
  end
  return icons.tour, "CodeTourTourIcon"
end

local function file_icon(path)
  if _G.MiniIcons then
    local ok, icon, hl = pcall(_G.MiniIcons.get, "file", path)
    if ok and icon then
      return icon, hl
    end
  end
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if ok then
    local icon, hl = devicons.get_icon(vim.fs.basename(path), vim.fn.fnamemodify(path, ":e"), { default = true })
    if icon then
      return icon, hl
    end
  end
  return config.get().icons.file, "CodeTourStepIcon"
end

local function step_icon(tour, index)
  local icons = config.get().icons
  local step = tour.steps[index + 1]
  if state.is_active(tour) and state.active.step == index then
    return icons.active, "CodeTourActive"
  elseif storage.is_complete(tour, index) then
    return icons.complete, "CodeTourComplete"
  elseif type(step.icon) == "string" and step.icon ~= "" and vim.fn.strdisplaywidth(step.icon) <= 2 then
    -- VS Code also accepts codicon names and image paths, which can't be
    -- shown in a terminal; short icons (emoji, nerd font glyphs) work.
    return step.icon, "CodeTourStepIcon"
  elseif step.directory then
    return icons.directory, "Directory"
  elseif step.file or step.uri then
    return file_icon(step.file or step.uri)
  end
  return icons.content, "CodeTourStepIcon"
end

local function node_key(node)
  if not node or not node.tour then
    return nil
  end
  return node.tour.id .. "#" .. tostring(node.step or "")
end

local function tree_window()
  if not (tree.buf and vim.api.nvim_buf_is_valid(tree.buf)) then
    return nil
  end
  for _, win in ipairs(vim.fn.win_findbuf(tree.buf)) do
    if vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage() then
      return win
    end
  end
end

M.window = tree_window

--- Builds the tree's lines, highlights and nodes.
function M.build()
  local icons = config.get().icons
  local keys = config.get().tree.keymaps
  local lines, marks, nodes = {}, {}, {}

  local function add(line, node)
    lines[#lines + 1] = line
    nodes[#lines] = node
    return #lines - 1
  end

  local function key(name)
    local k = keys[name]
    return type(k) == "table" and k[1] or k
  end

  local list = tour_list()
  if #list == 0 then
    add("No tours found in this workspace.")
    add("")
    if key("record") then
      add(("Press %s to record a tour, or"):format(key("record")))
    end
    if key("open_file") then
      add(("%s to open a tour file."):format(key("open_file")))
    end
    if key("open_url") then
      add(("%s to open a tour from a URL."):format(key("open_url")))
    end
    add("")
    add("Press ? for help.")
    for i = 0, #lines - 1 do
      marks[#marks + 1] = { row = i, col = 0, end_col = #lines[i + 1], hl = "CodeTourDescription" }
    end
    return lines, marks, nodes
  end

  for _, tour in ipairs(list) do
    local expanded = is_expanded(tour)
    local icon, icon_hl = tour_icon(tour)
    local prefix = (expanded and icons.expanded or icons.collapsed) .. " "
    local row = add(prefix .. icon .. " " .. tour.title, { tour = tour })
    marks[#marks + 1] = { row = row, col = 0, end_col = #prefix, hl = "CodeTourExpander" }
    marks[#marks + 1] = { row = row, col = #prefix, end_col = #prefix + #icon, hl = icon_hl }
    marks[#marks + 1] = { row = row, col = #prefix + #icon + 1, end_col = #lines[row + 1], hl = "CodeTourTourTitle" }

    local count = #tour.steps
    local description = ("%d step%s"):format(count, count == 1 and "" or "s")
    if tour.isPrimary then
      description = description .. " (Primary)"
    end
    marks[#marks + 1] = { row = row, virt_text = description }

    if expanded then
      if count == 0 then
        local recording = state.is_recording(tour)
        local text = recording and "Add tour step..." or "No steps recorded"
        local r = add("    " .. text, { tour = tour, placeholder = true })
        marks[#marks + 1] = { row = r, col = 4, end_col = #lines[r + 1], hl = "CodeTourDescription" }
      end
      for index = 0, count - 1 do
        local step_icon_text, step_hl = step_icon(tour, index)
        local indent = "    "
        local r = add(indent .. step_icon_text .. " " .. util.step_label(tour, index), { tour = tour, step = index })
        marks[#marks + 1] = { row = r, col = #indent, end_col = #indent + #step_icon_text, hl = step_hl }
        if state.is_active(tour) and state.active.step == index then
          marks[#marks + 1] = { row = r, col = #indent + #step_icon_text + 1, end_col = #lines[r + 1], hl = "CodeTourActiveStep" }
        end
      end
    end
  end

  return lines, marks, nodes
end

function M.render()
  if not (tree.buf and vim.api.nvim_buf_is_valid(tree.buf)) then
    return
  end
  local win = tree_window()
  local cursor_key
  if win then
    cursor_key = node_key(tree.nodes[vim.api.nvim_win_get_cursor(win)[1]])
  end

  local lines, marks, nodes = M.build()
  vim.bo[tree.buf].modifiable = true
  vim.api.nvim_buf_set_lines(tree.buf, 0, -1, false, lines)
  vim.bo[tree.buf].modifiable = false
  vim.bo[tree.buf].modified = false
  tree.nodes = nodes

  vim.api.nvim_buf_clear_namespace(tree.buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    if mark.virt_text then
      vim.api.nvim_buf_set_extmark(tree.buf, ns, mark.row, 0, {
        virt_text = { { "  " .. mark.virt_text, "CodeTourDescription" } },
        virt_text_pos = "eol",
      })
    elseif mark.end_col > mark.col then
      vim.api.nvim_buf_set_extmark(tree.buf, ns, mark.row, mark.col, {
        end_col = mark.end_col,
        hl_group = mark.hl,
      })
    end
  end

  if not win then
    return
  end

  -- Follow the active step, otherwise keep the cursor on the same node.
  local active_key = state.active and state.active.step >= 0 and node_key({ tour = state.active.tour, step = state.active.step })
  local target_key = cursor_key
  if active_key and active_key ~= tree.revealed then
    target_key = active_key
  end
  tree.revealed = active_key or nil
  for row, node in pairs(nodes) do
    if target_key and node_key(node) == target_key then
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      return
    end
  end
  local row = math.min(vim.api.nvim_win_get_cursor(win)[1], #lines)
  vim.api.nvim_win_set_cursor(win, { math.max(row, 1), 0 })
end

-- Nodes and actions ----------------------------------------------------------

local function current_node()
  return tree.nodes[vim.api.nvim_win_get_cursor(0)[1]]
end

local function selected_nodes()
  local first, last = vim.fn.line("v"), vim.fn.line(".")
  if first > last then
    first, last = last, first
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  local nodes = {}
  for row = first, last do
    if tree.nodes[row] and tree.nodes[row].tour and not tree.nodes[row].placeholder then
      nodes[#nodes + 1] = tree.nodes[row]
    end
  end
  return nodes
end

local function start_options(tour)
  if state.is_active(tour) then
    return { root = state.active.root, tours = state.active.tours, can_edit = state.active.can_edit }
  end
end

local function start_at(node)
  actions().start_tour(node.tour, node.step or 0, start_options(node.tour))
end

M.actions = {}

M.actions.toggle = async(function(node)
  if not node or not node.tour then
    return
  end
  if node.placeholder then
    if state.is_recording(node.tour) then
      recorder().add_content_step()
    end
  elseif node.step then
    start_at(node)
  else
    tree.expanded[node.tour.id] = not is_expanded(node.tour)
    M.render()
  end
end)

M.actions.start = function(node)
  if node and node.tour then
    start_at(node)
  end
end

M.actions.end_tour = function()
  actions().end_tour()
end

M.actions.resume = function()
  actions().resume()
end

M.actions.edit = async(function(node)
  if node and node.tour then
    recorder().edit(node.tour, node.step)
  end
end)

M.actions.preview = function()
  recorder().preview()
end

M.actions.add_content_step = async(function(node)
  if node and node.tour and state.is_recording(node.tour) then
    recorder().add_content_step(nil, node.step)
  else
    util.warn("Start recording the tour (e) before adding steps to it.")
  end
end)

M.actions.rename = async(function(node)
  if not (node and node.tour) then
    return
  end
  if node.step then
    recorder().change_step_title(node.tour, node.step)
  else
    recorder().change_title(node.tour)
  end
end)

M.actions.change_description = async(function(node)
  if node and node.tour then
    recorder().change_description(node.tour)
  end
end)

M.actions.change_ref = async(function(node)
  if node and node.tour then
    recorder().change_ref(node.tour)
  end
end)

M.actions.change_icon = async(function(node)
  if node and node.step then
    recorder().change_step_icon(node.tour, node.step)
  end
end)

M.actions.toggle_primary = function(node)
  if not (node and node.tour) then
    return
  end
  if node.tour.isPrimary then
    recorder().unmake_primary(node.tour)
  else
    recorder().make_primary(node.tour)
  end
end

M.actions.delete = async(function(node, nodes)
  nodes = nodes or { node }
  nodes = vim.tbl_filter(function(n)
    return n and n.tour and not n.placeholder
  end, nodes)
  if #nodes == 0 then
    return
  end
  if nodes[1].step then
    local tour = nodes[1].tour
    local steps = {}
    for _, n in ipairs(nodes) do
      if n.step and n.tour.id == tour.id then
        steps[#steps + 1] = n.step
      end
    end
    recorder().delete_steps(tour, steps)
  else
    local tours = {}
    for _, n in ipairs(nodes) do
      if not n.step then
        tours[#tours + 1] = n.tour
      end
    end
    recorder().delete_tours(tours)
  end
end)

M.actions.export = async(function(node)
  if node and node.tour then
    recorder().export_tour(node.tour)
  end
end)

M.actions.move_down = function(node)
  if node and node.step then
    recorder().move_step(1, node.tour, node.step)
    M.focus_node(node.tour, node.step + 1)
  end
end

M.actions.move_up = function(node)
  if node and node.step then
    recorder().move_step(-1, node.tour, node.step)
    M.focus_node(node.tour, node.step - 1)
  end
end

M.actions.peek = function(node)
  if not (node and node.tour) then
    return
  end
  local text
  if node.step then
    text = require("codetour.markdown").render(node.tour.steps[node.step + 1].description, {
      root = util.tour_root(node.tour),
      tours = state.tours,
    }):markdown()
  else
    text = node.tour.description or "_No description_"
  end
  M.popup(vim.split(text, "\n", { plain = true }), { rendered = true })
end

local popup = {}

local function close_popup()
  if popup.win and vim.api.nvim_win_is_valid(popup.win) then
    vim.api.nvim_win_close(popup.win, true)
  end
  popup = {}
end

--- Shows markdown in a window next to the tree (closed when the cursor moves).
function M.popup(lines, opts)
  close_popup()
  local tree_win = tree_window()
  if not tree_win then
    return
  end
  local player_opts = config.get().player
  local tree_width = vim.api.nvim_win_get_width(tree_win)
  local width = math.max(20, math.min(player_opts.max_width or 80, vim.o.columns - tree_width - 4))
  local on_right = config.get().tree.position == "right"

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = tree_win,
    row = vim.fn.winline() - 1,
    col = on_right and -(width + 2) or tree_width,
    width = width,
    height = 1,
    border = player_opts.border,
    zindex = 45,
  })
  require("codetour.player").setup_markdown_window(win, buf, opts and opts.rendered)
  local max_height = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
  local function fit()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_height(win, math.min(vim.api.nvim_win_text_height(win, {}).all, max_height))
    end
  end
  fit()
  -- Fit again once markdown renderers added their decorations.
  vim.defer_fn(fit, 150)
  popup = { win = win }

  vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave", "WinLeave" }, {
    buffer = vim.api.nvim_win_get_buf(tree_win),
    once = true,
    callback = function()
      vim.schedule(close_popup)
    end,
  })
  return win
end

M.actions.reset_progress = function(node)
  storage.reset(node and node.tour or nil)
  state.changed()
end

M.actions.toggle_markers = function()
  require("codetour.markers").toggle()
end

M.actions.record = async(function()
  recorder().record()
end)

M.actions.open_file = async(function()
  actions().open_tour_file()
end)

M.actions.open_url = async(function()
  actions().open_tour_url()
end)

M.actions.refresh = function()
  require("codetour.discovery").discover()
end

M.actions.close = function()
  M.close()
end

local HELP = {
  toggle = "Expand/collapse a tour, or start at a step",
  start = "Start the tour (at the step)",
  end_tour = "End the active tour",
  resume = "Resume the active tour",
  edit = "Edit the tour (at the step)",
  preview = "Stop editing the current step",
  add_content_step = "Add a content step (while recording)",
  rename = "Change the tour/step title",
  change_description = "Change the tour description",
  change_ref = "Change the tour's git ref",
  change_icon = "Change the step icon",
  toggle_primary = "Make/unmake the primary tour",
  delete = "Delete tours/steps (works in visual mode)",
  export = "Export the tour",
  move_down = "Move the step down",
  move_up = "Move the step up",
  peek = "Preview the step/tour description",
  reset_progress = "Reset the tour's progress",
  toggle_markers = "Show/hide tour markers",
  record = "Record a new tour",
  open_file = "Open a tour file",
  open_url = "Open a tour URL",
  refresh = "Re-discover tours",
  close = "Close the tree",
  help = "Show this help",
}

local HELP_SECTIONS = {
  { "Taking tours", { "toggle", "start", "resume", "end_tour", "peek", "reset_progress" } },
  {
    "Editing tours",
    {
      "record",
      "edit",
      "preview",
      "add_content_step",
      "rename",
      "change_description",
      "change_ref",
      "change_icon",
      "toggle_primary",
      "move_up",
      "move_down",
      "delete",
      "export",
    },
  },
  { "Other", { "open_file", "open_url", "toggle_markers", "refresh", "close", "help" } },
}

M.actions.help = function()
  local keys = config.get().tree.keymaps
  local lines = {}
  for _, section in ipairs(HELP_SECTIONS) do
    local entries = {}
    for _, name in ipairs(section[2]) do
      local lhs = keys[name]
      if lhs then
        local list = type(lhs) == "table" and lhs or { lhs }
        entries[#entries + 1] = ("- `%s` %s"):format(table.concat(list, "` `"), HELP[name])
      end
    end
    if #entries > 0 then
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      lines[#lines + 1] = "## " .. section[1]
      vim.list_extend(lines, entries)
    end
  end
  M.popup(lines, { rendered = true })
end

local function set_keymaps(buf)
  for name, lhs in pairs(config.get().tree.keymaps) do
    local action = M.actions[name]
    if lhs and action then
      for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
        vim.keymap.set("n", key, function()
          action(current_node())
        end, { buffer = buf, nowait = true, silent = true, desc = "CodeTour: " .. (HELP[name] or name) })
        if name == "delete" then
          vim.keymap.set("x", key, function()
            M.actions.delete(nil, selected_nodes())
          end, { buffer = buf, nowait = true, silent = true, desc = "CodeTour: Delete selected" })
        end
      end
    end
  end
end

--- Moves the tree cursor to a tour/step.
function M.focus_node(tour, step)
  local win = tree_window()
  if not win then
    return
  end
  local key = node_key({ tour = tour, step = step })
  for row, node in pairs(tree.nodes) do
    if node_key(node) == key then
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      return
    end
  end
end

-- Window -----------------------------------------------------------------------

local function ensure_buffer()
  if tree.buf and vim.api.nvim_buf_is_valid(tree.buf) then
    return tree.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, M.NAME)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = M.FILETYPE
  set_keymaps(buf)
  tree.buf = buf
  return buf
end

local subscribed = false

function M.open()
  require("codetour.discovery").ensure()
  local buf = ensure_buffer()
  local win = tree_window()
  if not win then
    local opts = config.get().tree
    win = vim.api.nvim_open_win(buf, true, {
      split = opts.position == "right" and "right" or "left",
      win = -1,
      width = opts.width,
    })
    local wo = vim.wo[win]
    wo.number = false
    wo.relativenumber = false
    wo.signcolumn = "no"
    wo.foldcolumn = "0"
    wo.wrap = false
    wo.cursorline = true
    wo.list = false
    wo.spell = false
    wo.winfixwidth = true
    -- Files opened in the tree window are moved to a code window, see
    -- codetour.player.rehome().
    vim.w[win].codetour_window = { kind = "tree", buf = buf }
  else
    vim.api.nvim_set_current_win(win)
  end

  if not subscribed then
    subscribed = true
    state.subscribe(function()
      if tree_window() then
        M.render()
      end
    end)
  end
  tree.revealed = nil
  M.render()
  return win
end

function M.close()
  local win = tree_window()
  if win then
    if #vim.api.nvim_tabpage_list_wins(0) == 1 then
      vim.w[win].codetour_window = nil
      vim.api.nvim_win_call(win, vim.cmd.enew)
    else
      vim.api.nvim_win_close(win, false)
    end
  end
end

function M.toggle()
  if tree_window() then
    M.close()
  else
    M.open()
  end
end

--- The node on a 1-based line (for tests and integrations).
function M.node(row)
  return tree.nodes[row]
end

function M.buffer()
  return tree.buf
end

return M
