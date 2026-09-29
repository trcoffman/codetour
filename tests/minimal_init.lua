-- Minimal init used to run the test suite: `make test`.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local plenary = vim.env.PLENARY_DIR or (root .. "/.tests/plenary.nvim")

vim.opt.runtimepath:prepend(plenary)
vim.opt.runtimepath:prepend(root)
-- Tests change the cwd, so make `require("tests.helpers")` independent of it.
package.path = root .. "/?.lua;" .. package.path

vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

vim.cmd("runtime plugin/plenary.vim")
vim.cmd("runtime plugin/codetour.lua")
