-- Completion of well-known commands after typing `command:` in the step
-- editor (VS Code's completionProvider.ts).

local M = {}

M.ITEMS = {
  {
    label = "Navigate to tour step",
    detail = "Navigates the end-user to the specified step in the current tour.",
    snippet = "codetour.navigateToStep?${1:stepNumber}",
  },
  {
    label = "Open URL",
    detail = "Launches the end-user's default browser to the specified URL.",
    snippet = 'vscode.open?["${1:url}"]',
  },
  {
    label = "Run build task",
    detail = "Runs the build task, as configured by the current workspace.",
    snippet = "workbench.action.tasks.build",
  },
  {
    label = "Run task",
    detail = "Runs a task that's defined by the current workspace.",
    snippet = 'workbench.action.tasks.runTask?["${1:taskName}"]',
  },
  {
    label = "Run test task",
    detail = "Runs the test task, as configured by the current workspace.",
    snippet = "workbench.action.tasks.test",
  },
  {
    label = "Run terminal command",
    detail = "Executes a shell command in the end-user's integrated terminal.",
    snippet = 'codetour.sendTextToTerminal?["${1:shellCommand}"]',
  },
  {
    label = "Start tour",
    detail = 'Starts another tour using its title (e.g. "Status Bar")',
    snippet = 'codetour.startTourByTitle?["${1:tourTitle}"]',
  },
}

local function plain(snippet)
  return (snippet:gsub("%${%d+:([^}]*)}", "%1"))
end

local function complete_items(base)
  local items = {}
  for _, item in ipairs(M.ITEMS) do
    local word = plain(item.snippet)
    if not base or base == "" or vim.startswith(word, base) then
      items[#items + 1] = {
        word = word,
        abbr = item.label,
        menu = item.detail,
        user_data = { codetour_snippet = item.snippet },
      }
    end
  end
  return items
end

-- Byte column (0-based) right after "command:" before the cursor, if any.
local function command_start()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = vim.api.nvim_get_current_line():sub(1, col)
  local s = before:find("command:[^%s%)]*$")
  if s then
    return s + #"command:" - 1
  end
end

function M.omnifunc(findstart, base)
  if findstart == 1 then
    return command_start() or -3
  end
  return complete_items(base)
end

function M.attach(buf)
  vim.bo[buf].omnifunc = "v:lua.require'codetour.completion'.omnifunc"

  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = buf,
    callback = function()
      local col = vim.api.nvim_win_get_cursor(0)[2]
      local before = vim.api.nvim_get_current_line():sub(1, col)
      if before:sub(-#"command:") == "command:" and vim.fn.pumvisible() == 0 then
        vim.fn.complete(col + 1, complete_items())
      end
    end,
  })

  -- Replace the inserted text with a snippet so placeholders can be filled.
  vim.api.nvim_create_autocmd("CompleteDone", {
    buffer = buf,
    callback = function()
      local item = vim.v.completed_item
      local snippet = type(item) == "table" and type(item.user_data) == "table" and item.user_data.codetour_snippet
      if not snippet or not vim.snippet or snippet == item.word then
        return
      end
      vim.schedule(function()
        local row, col = unpack(vim.api.nvim_win_get_cursor(0))
        local line = vim.api.nvim_get_current_line()
        if line:sub(col - #item.word + 1, col) ~= item.word then
          return
        end
        vim.api.nvim_buf_set_text(0, row - 1, col - #item.word, row - 1, col, { "" })
        vim.api.nvim_win_set_cursor(0, { row, col - #item.word })
        vim.snippet.expand(snippet)
      end)
    end,
  })
end

return M
