if vim.g.loaded_codetour then
  return
end
vim.g.loaded_codetour = true

vim.api.nvim_create_user_command("CodeTour", function(opts)
  require("codetour.cli").run(opts)
end, {
  nargs = "*",
  range = true,
  bang = true,
  desc = "CodeTour",
  complete = function(...)
    return require("codetour.cli").complete(...)
  end,
})

-- Tour files are JSON (VS Code contributes the same mapping).
vim.filetype.add({ extension = { tour = "json" } })

require("codetour.highlights").setup()

local group = vim.api.nvim_create_augroup("codetour", { clear = true })

local function discovered()
  local state = package.loaded["codetour.state"]
  return state ~= nil and state.discovered
end

local function startup()
  vim.schedule(function()
    require("codetour").on_startup()
  end)
end

if vim.v.vim_did_enter == 1 then
  startup()
else
  vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = startup })
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = function()
    require("codetour.highlights").setup()
  end,
})

-- Keep the tour list current (VS Code watches the tour directories).
vim.api.nvim_create_autocmd("BufWritePost", {
  group = group,
  pattern = "*.tour",
  callback = function()
    require("codetour.discovery").discover()
  end,
})

vim.api.nvim_create_autocmd({ "DirChanged", "FocusGained" }, {
  group = group,
  callback = function()
    if discovered() then
      require("codetour.discovery").discover()
      require("codetour.markers").refresh_all()
    end
  end,
})

vim.api.nvim_create_autocmd("BufWinEnter", {
  group = group,
  callback = function(ev)
    if discovered() and #require("codetour.state").tours > 0 then
      require("codetour.markers").refresh(ev.buf)
    end
  end,
})
