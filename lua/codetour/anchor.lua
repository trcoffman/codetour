-- Works out which line a step is attached to, from a file's lines. Shared by
-- the player, the validator and the command-line tool.

local regex = require("codetour.regex")
local util = require("codetour.util")

local M = {}

---@alias codetour.AnchorKind "line"|"selection"|"pattern"|"marker"|"end"|"none"

--- Returns the 0-based line a step is shown at and how it was found.
---   line/selection: from `step.line` / `step.selection`
---   pattern/marker: the first line matching `step.pattern` / the step marker
---   end:            file steps that can't be located go to the end of the file
---   none:           steps without a file (content and directory steps)
---@param tour codetour.Tour
---@param index integer 0-based step index
---@param lines string[]
---@return integer line
---@return codetour.AnchorKind kind
---@return string|nil problem why the step couldn't be located
---@return "unsupported"|"unmatched"|nil problem_kind
function M.resolve(tour, index, lines)
  local step = tour.steps[index + 1]
  local count = math.max(#lines, 1)
  local function clamp(line)
    return math.max(0, math.min(line, count - 1))
  end

  if step.line then
    return clamp(step.line - 1), "line"
  elseif step.selection then
    return clamp(step.selection["end"].line - 1), "selection"
  end

  if not (step.file or step.uri or step.contents) then
    return 0, "none"
  end

  -- Like VS Code, patterns and step markers only apply to `file` steps.
  local pattern, kind
  if step.file then
    pattern, kind = step.pattern, "pattern"
    if not pattern then
      pattern, kind = util.step_marker(tour, index), "marker"
    end
  end
  if pattern then
    local what = kind == "marker" and "step marker" or "pattern"
    local _, err = regex.compile(pattern)
    if err then
      return count - 1, "end", ("%s %q isn't supported: %s"):format(what, pattern, err), "unsupported"
    end
    local line = regex.find_line(lines, pattern)
    if line then
      return line, kind
    end
    return count - 1, "end", ("%s %q doesn't match any line"):format(what, pattern), "unmatched"
  end

  -- Steps without a line are shown at the end of the file (like VS Code).
  return count - 1, "end"
end

--- Splits file contents into lines (without the empty line after a final
--- newline).
function M.lines(content)
  local lines = vim.split(content or "", "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

return M
