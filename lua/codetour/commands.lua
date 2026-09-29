-- Runs link actions and the VS Code command IDs used by tours
-- (`[text](command:...)` links and `step.commands`).

local config = require("codetour.config")
local state = require("codetour.state")
local util = require("codetour.util")

local M = {}

local function actions()
  return require("codetour.actions")
end

local function recorder()
  return require("codetour.recorder")
end

local function async_call(fn)
  return function(...)
    local args = { ... }
    require("codetour.async").run(function()
      fn(unpack(args))
    end)
  end
end

local function open_target(target)
  if type(target) == "table" then
    target = target.fsPath or target.path or target.external
  end
  if type(target) ~= "string" then
    return
  end
  if target:match("^file://") then
    target = vim.uri_to_fname(target)
  elseif util.is_url(target) or target:match("^mailto:") then
    return vim.ui.open(target)
  end
  M.open_file(util.join(state.active and state.active.root or util.roots()[1], target))
end

--- Command IDs understood by the Neovim port. Users can add or override
--- commands with the `commands` option.
M.builtin = {
  ["codetour.startTour"] = async_call(function()
    require("codetour.discovery").ensure()
    actions().select_tour()
  end),
  ["codetour.endTour"] = function()
    actions().end_tour()
  end,
  ["codetour.nextTourStep"] = function()
    actions().next()
  end,
  ["codetour.previousTourStep"] = function()
    actions().prev()
  end,
  ["codetour.navigateToStep"] = function(number)
    actions().goto_step(number)
  end,
  ["codetour.startTourByTitle"] = function(title, number)
    actions().start_by_title(title, number)
  end,
  ["codetour.finishTour"] = function(title)
    actions().finish(title)
  end,
  ["codetour.resumeTour"] = function()
    actions().resume()
  end,
  ["codetour.sendTextToTerminal"] = function(text)
    M.send_to_terminal(text)
  end,
  ["codetour.insertCodeSnippet"] = function(code)
    M.insert_code(code)
  end,
  ["codetour.openTourFile"] = async_call(function()
    actions().open_tour_file()
  end),
  ["codetour.openTourUrl"] = async_call(function()
    actions().open_tour_url()
  end),
  ["codetour.recordTour"] = async_call(function()
    recorder().record()
  end),
  ["codetour.editTour"] = async_call(function()
    recorder().edit()
  end),
  ["codetour.previewTour"] = function()
    recorder().preview()
  end,
  ["codetour.addContentStep"] = async_call(function()
    recorder().add_content_step()
  end),
  ["codetour.showMarkers"] = function()
    require("codetour.markers").set_enabled(true)
  end,
  ["codetour.hideMarkers"] = function()
    require("codetour.markers").set_enabled(false)
  end,
  ["codetour.resetProgress"] = function()
    require("codetour.storage").reset()
    state.changed()
  end,
  ["vscode.open"] = open_target,
  ["workbench.action.tasks.build"] = "make",
  ["workbench.action.terminal.new"] = function()
    M.open_terminal(true)
  end,
  ["workbench.action.terminal.focus"] = function()
    M.open_terminal(true)
  end,
  ["terminal.focus"] = function()
    M.open_terminal(true)
  end,
}

--- Executes a command by ID.
function M.execute(name, args)
  local handler = config.get().commands[name]
  if handler == nil then
    handler = M.builtin[name]
  end
  if type(handler) == "string" then
    local ok, err = pcall(vim.cmd, handler)
    if not ok then
      util.error(("An error has occurred: %s"):format(err))
    end
  elseif type(handler) == "function" then
    local ok, err = pcall(handler, unpack(args or {}))
    if not ok then
      util.error(("An error has occurred: %s"):format(err))
    end
  else
    util.warn(("The command %q isn't available in Neovim. Map it with the `commands` option."):format(name))
  end
end

function M.open_file(path)
  local win = require("codetour.player").step_window()
  if not (win and vim.api.nvim_win_is_valid(win)) then
    win = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(win)
  vim.cmd.edit(vim.fn.fnameescape(path))
end

--- Runs an action produced by a link or step command.
function M.run_action(action)
  if action.type == "command" then
    M.execute(action.name, action.args)
  elseif action.type == "url" then
    vim.ui.open(action.url)
  elseif action.type == "file" then
    if action.image or action.path:match("%.[Pp][Nn][Gg]$") or action.path:match("%.[Ss][Vv][Gg]$") or action.path:match("%.[Jj][Pp][Ee]?[Gg]$") or action.path:match("%.[Gg][Ii][Ff]$") then
      vim.ui.open(action.path)
    else
      M.open_file(action.path)
    end
  end
end

-- Views ------------------------------------------------------------------

-- Neovim equivalents of the VS Code views a step can focus (`step.view`).
-- Each entry lists candidates; the first one that's available is used.
M.VIEWS = {
  terminal = {
    function()
      M.open_terminal(true)
    end,
  },
  problems = {
    function()
      vim.diagnostic.setqflist()
    end,
  },
  explorer = { "Neotree reveal", "NvimTreeFindFile", "Oil", "Lexplore" },
  scm = { "Neogit", "Git", "LazyGit" },
  search = { "Telescope live_grep", "FzfLua live_grep" },
  output = { "messages" },
  console = { "messages" },
  comments = {},
  extensions = { "Lazy", "Mason" },
  debug = {
    function()
      require("dapui").open()
    end,
  },
}

local function command_exists(cmd)
  local name = cmd:match("^(%S+)")
  return vim.fn.exists(":" .. name) == 2
end

--- Focuses the Neovim equivalent of a VS Code view.
function M.focus_view(id)
  local candidates = config.get().views[id]
  if candidates == nil then
    candidates = M.VIEWS[id] or M.VIEWS[id:match("^([^:]+):")]
  end
  if type(candidates) ~= "table" then
    candidates = { candidates }
  end
  for _, candidate in ipairs(candidates) do
    if type(candidate) == "function" then
      if pcall(candidate) then
        return true
      end
    elseif type(candidate) == "string" and command_exists(candidate) then
      local ok = pcall(vim.cmd, candidate)
      if ok then
        return true
      end
    end
  end
  util.error(
    ("The current tour step is attempting to focus a view which isn't available: %s. Please check the tour and try again."):format(id)
  )
  return false
end

-- Terminal -------------------------------------------------------------------

local terminal = {}

local function terminal_alive()
  return terminal.buf ~= nil
    and vim.api.nvim_buf_is_valid(terminal.buf)
    and terminal.job ~= nil
    and vim.fn.jobwait({ terminal.job }, 0)[1] == -1
end

--- Opens (or reveals) the "CodeTour" terminal.
function M.open_terminal(focus)
  local previous = vim.api.nvim_get_current_win()
  local height = config.get().terminal.height
  if terminal_alive() then
    local wins = vim.fn.win_findbuf(terminal.buf)
    if #wins == 0 then
      vim.api.nvim_open_win(terminal.buf, false, { split = "below", win = -1, height = height })
    end
  else
    if terminal.buf and vim.api.nvim_buf_is_valid(terminal.buf) then
      pcall(vim.api.nvim_buf_delete, terminal.buf, { force = true })
    end
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, { split = "below", win = -1, height = height })
    local job
    vim.api.nvim_win_call(win, function()
      if vim.fn.has("nvim-0.11") == 1 then
        job = vim.fn.jobstart(vim.o.shell, { term = true })
      else
        job = vim.fn.termopen(vim.o.shell)
      end
    end)
    vim.b[buf].codetour_terminal = true
    pcall(vim.api.nvim_buf_set_name, buf, "CodeTour")
    terminal = { buf = buf, job = job }
  end

  if focus then
    local win = vim.fn.win_findbuf(terminal.buf)[1]
    if win then
      vim.api.nvim_set_current_win(win)
    end
  elseif vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
  return terminal
end

--- Runs a shell command in the "CodeTour" terminal (`>> command` syntax).
function M.send_to_terminal(text)
  local term = M.open_terminal(false)
  vim.fn.chansend(term.job, text .. "\r")
end

--- Closes the terminal (VS Code disposes it when the tour ends).
function M.close_terminal()
  if terminal.buf and vim.api.nvim_buf_is_valid(terminal.buf) then
    pcall(vim.fn.jobstop, terminal.job)
    pcall(vim.api.nvim_buf_delete, terminal.buf, { force = true })
  end
  terminal = {}
end

function M.terminal()
  return terminal
end

-- Code snippets ------------------------------------------------------------

--- Inserts a code block from the step description at the step's line (or
--- replaces its selection).
function M.insert_code(code)
  local active = state.active
  local step = state.current_step()
  local buf = require("codetour.player").step_buffer()
  if not (active and step and buf and vim.api.nvim_buf_is_valid(buf)) then
    return util.warn("There is no active tour step to insert code into.")
  end
  if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
    return util.warn("The step's file is read-only (the tour is pinned to a different git ref).")
  end

  local lines = vim.split(code, "\n", { plain = true })
  if step.selection then
    local sr, sc, er, ec = util.selection_range(buf, step.selection)
    vim.api.nvim_buf_set_text(buf, sr, sc, er, ec, lines)
  elseif step.line then
    local row = math.min(step.line - 1, vim.api.nvim_buf_line_count(buf))
    vim.api.nvim_buf_set_text(buf, row, 0, row, 0, lines)
  else
    return util.warn("The step isn't associated with a line to insert code at.")
  end

  local adjustment = #lines - 1
  if adjustment > 0 and step.line then
    step.line = step.line + adjustment
    require("codetour.tourfile").save(active.tour)
  end

  if config.get().format_on_insert then
    local clients = vim.lsp.get_clients({ bufnr = buf, method = "textDocument/formatting" })
    if #clients > 0 then
      pcall(vim.lsp.buf.format, { bufnr = buf })
    end
  end
  require("codetour.player").refresh()
end

return M
