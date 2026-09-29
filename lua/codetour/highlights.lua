local M = {}

M.GROUPS = {
  CodeTourMarker = "DiagnosticInfo",
  CodeTourMarkerText = "Comment",
  CodeTourSelection = "Visual",
  CodeTourFloat = "NormalFloat",
  CodeTourBorder = "FloatBorder",
  CodeTourTitle = "FloatTitle",
  CodeTourFooter = "Comment",
  CodeTourExpander = "Comment",
  CodeTourTourTitle = "Normal",
  CodeTourTourIcon = "Special",
  CodeTourStepIcon = "Special",
  CodeTourActive = "DiagnosticWarn",
  CodeTourActiveStep = { bold = true },
  CodeTourComplete = "DiagnosticOk",
  CodeTourRecording = "DiagnosticError",
  CodeTourDescription = "Comment",
}

function M.setup()
  for group, spec in pairs(M.GROUPS) do
    spec = type(spec) == "table" and vim.deepcopy(spec) or { link = spec }
    spec.default = true
    vim.api.nvim_set_hl(0, group, spec)
  end
end

return M
