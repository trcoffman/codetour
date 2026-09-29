-- Shared test helpers.
local M = {}

local original = {
  input = vim.ui.input,
  select = vim.ui.select,
  open = vim.ui.open,
  notify = vim.notify,
}

M.notifications = {}

--- Resets the editor and reloads the plugin so every test starts fresh.
function M.reset()
  local state = package.loaded["codetour.state"]
  if state and state.active then
    pcall(require("codetour.actions").end_tour, false)
  end

  vim.ui.input, vim.ui.select, vim.ui.open = original.input, original.select, original.open
  M.notifications = {}
  vim.notify = function(msg, level)
    table.insert(M.notifications, { msg = msg, level = level })
  end

  pcall(vim.cmd, "stopinsert")
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    pcall(function()
      vim.wo[win].winfixbuf = false
    end)
  end
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  local current = vim.api.nvim_get_current_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= current then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  pcall(vim.api.nvim_del_augroup_by_name, "codetour_player")
  for name in pairs(package.loaded) do
    if name == "codetour" or name:match("^codetour%.") then
      package.loaded[name] = nil
    end
  end
end

--- Creates a temporary workspace, makes it the cwd and returns its path.
---@param files table<string, string> relative path -> contents
function M.workspace(files)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = vim.uv.fs_realpath(root)
  for path, content in pairs(files or {}) do
    M.write(root .. "/" .. path, content)
  end
  vim.cmd.cd(vim.fn.fnameescape(root))
  return root
end

function M.write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(io.open(path, "wb"))
  fd:write(content)
  fd:close()
end

function M.read(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  return content
end

function M.read_json(path)
  return vim.json.decode(M.read(path))
end

--- Configures the plugin for tests and discovers the workspace's tours.
function M.setup(opts)
  require("codetour").setup(vim.tbl_deep_extend("force", {
    state_file = vim.fn.tempname() .. "/state.json",
    prompt_for_workspace_tours = false,
  }, opts or {}))
  require("codetour.discovery").discover()
  return require("codetour.state")
end

--- Replaces vim.ui.input/select with queued answers.
--- Select answers can be an index, the (formatted) item text, or a function.
function M.stub_ui()
  local ui = { inputs = {}, selects = {}, prompts = {}, items = {} }
  vim.ui.input = function(opts, cb)
    table.insert(ui.prompts, opts.prompt)
    ui.last_input = opts
    local answer = table.remove(ui.inputs, 1)
    if type(answer) == "function" then
      answer = answer(opts)
    end
    cb(answer)
  end
  vim.ui.select = function(items, opts, cb)
    table.insert(ui.prompts, opts.prompt)
    local format = opts.format_item or tostring
    local labels = vim.tbl_map(format, items)
    table.insert(ui.items, labels)
    local answer = table.remove(ui.selects, 1)
    if type(answer) == "function" then
      answer = answer(items, labels)
    end
    if type(answer) == "string" then
      for i, label in ipairs(labels) do
        if label == answer or vim.startswith(label, answer) then
          answer = i
          break
        end
      end
    end
    if type(answer) == "number" and items[answer] then
      cb(items[answer], answer)
    else
      cb(nil, nil)
    end
  end
  return ui
end

function M.stub_open()
  local opened = {}
  vim.ui.open = function(target)
    table.insert(opened, target)
  end
  return opened
end

function M.lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

function M.text(buf)
  return table.concat(M.lines(buf), "\n")
end

function M.has_notification(pattern)
  for _, n in ipairs(M.notifications) do
    if tostring(n.msg):find(pattern) then
      return true
    end
  end
  return false
end

--- Runs git in `root` (with an identity, so commits work on CI).
function M.git(root, ...)
  local result = vim.system(vim.list_extend({
    "git",
    "-C",
    root,
    "-c",
    "user.name=CodeTour Tests",
    "-c",
    "user.email=tests@example.com",
    "-c",
    "commit.gpgsign=false",
    "-c",
    "tag.gpgsign=false",
  }, { ... }), { text = true }):wait()
  assert(result.code == 0, "git " .. table.concat({ ... }, " ") .. " failed: " .. tostring(result.stderr))
  return vim.trim(result.stdout)
end

--- Serializes a tour for fixtures.
function M.tour(tbl)
  return vim.json.encode(tbl)
end

function M.lines_of(n, fmt)
  local lines = {}
  for i = 1, n do
    lines[#lines + 1] = (fmt or "line %d"):format(i)
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Types keys as if the user did (mappings apply).
function M.feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end

--- Runs `fn` inside a coroutine (for code using codetour.async).
function M.run(fn)
  local done, err = false, nil
  require("codetour.async").run(function()
    local ok, e = pcall(fn)
    done, err = true, not ok and e or nil
  end)
  vim.wait(2000, function()
    return done
  end)
  assert(done, "async function did not finish")
  if err then
    error(err, 0)
  end
end

return M
