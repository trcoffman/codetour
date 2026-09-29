local M = {}

function M.check()
  local health = vim.health
  health.start("codetour.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 or newer is required")
  end

  if vim.fn.executable("git") == 1 then
    health.ok("git is installed (needed for tours pinned to a git ref)")
  else
    health.warn("git isn't installed: tours pinned to a git ref show the working tree")
  end

  if vim.fn.executable("curl") == 1 then
    health.ok("curl is installed (needed for :CodeTour open_url)")
  else
    health.warn("curl isn't installed: :CodeTour open_url won't work")
  end

  local renderer
  for _, module in ipairs({ "render-markdown", "markview" }) do
    if pcall(require, module) then
      renderer = module
      break
    end
  end
  if renderer then
    health.ok(renderer .. " is installed and will render step descriptions")
  else
    health.warn("No markdown renderer found. Install render-markdown.nvim (or markview.nvim) for nicer step descriptions")
  end

  if pcall(vim.treesitter.language.inspect, "markdown") then
    health.ok("The treesitter markdown parser is available")
  else
    health.warn("The treesitter markdown parser isn't available")
  end

  local state = require("codetour.state")
  require("codetour.discovery").ensure()
  health.info(("%d tour(s) found in %s"):format(#state.tours, table.concat(require("codetour.util").roots(), ", ")))
end

return M
