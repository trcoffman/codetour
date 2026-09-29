-- Editing helpers shared by the recorder.

local regex = require("codetour.regex")

local M = {}

--- The pattern the VS Code recorder uses to anchor a step to a line's
--- content. Returns nil unless the line is non-blank and unique in the file.
---@param lines string[]
---@param row integer 0-based
function M.line_pattern(lines, row)
  local text = vim.trim(lines[row + 1] or "")
  if text == "" then
    return nil
  end
  local pattern = "^[^\\S\\n]*" .. regex.escape(text)
  local compiled = regex.compile(pattern)
  if not compiled then
    return nil
  end
  local matches = 0
  for _, line in ipairs(lines) do
    if compiled:match_str(line) then
      matches = matches + 1
    end
  end
  return matches == 1 and pattern or nil
end

return M
