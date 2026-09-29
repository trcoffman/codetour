local M = {}

---@class codetour.Config
M.defaults = {
  -- Show a prompt the first time a workspace with tours is opened
  -- (VS Code: `codetour.promptForWorkspaceTours`).
  prompt_for_workspace_tours = true,

  -- How new steps are anchored while recording: "lineNumber" or "pattern"
  -- (VS Code: `codetour.recordMode`).
  record_mode = "lineNumber",

  -- Show gutter markers on lines that belong to a tour
  -- (VS Code: `codetour.showMarkers`).
  show_markers = true,

  -- Additional workspace-relative directory to discover and record tours in
  -- (VS Code: `codetour.customTourDirectory`).
  custom_tour_directory = nil,

  -- Also read `codetour.*` settings from `<root>/.vscode/settings.json`.
  -- Options passed to `setup()` take precedence over workspace settings.
  vscode_settings = true,

  -- Workspace folders to discover tours in (a list or a function returning
  -- one). Defaults to the current working directory.
  roots = nil,

  -- Where tour progress is persisted.
  state_file = vim.fn.stdpath("data") .. "/codetour/state.json",

  player = {
    -- Move the cursor into the step window when a step is shown.
    focus = true,
    max_width = 100,
    max_height = 20,
    border = "rounded",
    -- Buffer-local mappings inside the step window (false disables one).
    keymaps = {
      next = "n",
      prev = "p",
      open_link = "<CR>",
      next_link = "<Tab>",
      prev_link = "<S-Tab>",
      edit = "e",
      hide = "q",
      end_tour = "Q",
      unfocus = "<Esc>",
    },
  },

  tree = {
    position = "left",
    width = 40,
    -- Buffer-local mappings inside the tour tree (false disables one).
    keymaps = {
      toggle = { "<CR>", "o" },
      start = "s",
      end_tour = "S",
      resume = "u",
      edit = "e",
      preview = "v",
      add_content_step = "a",
      rename = "r",
      change_description = "cd",
      change_ref = "cr",
      change_icon = "ci",
      toggle_primary = "p",
      delete = "d",
      export = "x",
      move_down = "J",
      move_up = "K",
      peek = "<Tab>",
      reset_progress = "X",
      toggle_markers = "m",
      record = "+",
      open_file = "O",
      open_url = "U",
      refresh = "R",
      close = "q",
      help = "?",
    },
  },

  markers = {
    sign = "◆",
    -- Show the tour title/step as virtual text at the end of marker lines.
    virtual_text = false,
  },

  icons = {
    collapsed = "▸",
    expanded = "▾",
    tour = "○",
    active = "▶",
    complete = "✓",
    recording = "●",
    file = "•",
    directory = "▪",
    content = "¶",
  },

  -- Maps VS Code view IDs used by `step.view` to an Ex command or function.
  views = {},

  -- Maps command IDs used by command links and `step.commands` to an Ex
  -- command or a function receiving the command arguments.
  commands = {},

  terminal = {
    height = 12,
  },

  -- Format the buffer (via LSP) after inserting a code snippet.
  format_on_insert = true,

  -- Called with the absolute path when a directory step is shown, e.g. to
  -- reveal it in a file explorer.
  on_directory_step = nil,
}

local options = vim.deepcopy(M.defaults)
local user = {}

-- VS Code setting names for the options that can also come from a
-- workspace's .vscode/settings.json.
local WORKSPACE_SETTINGS = {
  prompt_for_workspace_tours = "codetour.promptForWorkspaceTours",
  record_mode = "codetour.recordMode",
  show_markers = "codetour.showMarkers",
  custom_tour_directory = "codetour.customTourDirectory",
}

function M.setup(opts)
  user = opts or {}
  options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user)
end

function M.get()
  return options
end

local settings_cache = {}

local function read_workspace_settings(root)
  local path = root .. "/.vscode/settings.json"
  local stat = vim.uv.fs_stat(path)
  if not stat then
    settings_cache[path] = nil
    return {}
  end

  local cached = settings_cache[path]
  if cached and cached.mtime == stat.mtime.sec and cached.size == stat.size then
    return cached.settings
  end

  local settings = {}
  local fd = io.open(path, "r")
  if fd then
    local content = fd:read("*a")
    fd:close()
    local ok, decoded = pcall(require("codetour.json").decode, content, { jsonc = true })
    if ok and type(decoded) == "table" then
      settings = decoded
    end
  end

  settings_cache[path] = { mtime = stat.mtime.sec, size = stat.size, settings = settings }
  return settings
end

--- Returns an option that can be overridden by workspace settings.
---@param key string
---@param root? string
function M.setting(key, root)
  if user[key] ~= nil then
    return user[key]
  end

  if options.vscode_settings and root and WORKSPACE_SETTINGS[key] then
    local value = read_workspace_settings(root)[WORKSPACE_SETTINGS[key]]
    if value ~= nil and value ~= vim.NIL then
      return value
    end
  end

  return options[key]
end

return M
