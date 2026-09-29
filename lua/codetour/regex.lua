-- Translates the JavaScript regular expressions used by tour files
-- (`step.pattern`, step markers) into Vim "very magic" patterns.
--
-- Only the subset of JS syntax that shows up in tours is supported; anything
-- else makes `to_vim` return nil plus an error message.

local M = {}

local CLASS_SHORTHANDS = {
  d = "0-9",
  w = "0-9A-Za-z_",
  s = " \\t\\r\\x0c\\x0b",
}

local SIMPLE_ESCAPES = {
  d = "\\d",
  D = "\\D",
  w = "\\w",
  W = "\\W",
  s = "\\s",
  S = "\\S",
  n = "\\n",
  t = "\\t",
  r = "\\r",
  f = "%x0c",
  v = "%x0b",
  ["0"] = "%x00",
  b = "%(<|>)",
}

local function literal(c)
  if c:match("^[%w_]$") or c:byte() >= 0x80 then
    return c
  end
  return "\\" .. c
end

-- Parses a `[...]` class starting at `i` (the "[") and returns the Vim
-- collection plus the index after the closing "]".
local function parse_class(p, i)
  local j = i + 1
  local negated = p:sub(j, j) == "^"
  if negated then
    j = j + 1
  end

  -- `[^\S\n]` (and friends) is what the VS Code recorder emits to mean
  -- "whitespace other than a newline". Vim collections can't contain `\S`, so
  -- rewrite the common negated forms up front.
  local rest = p:sub(j)
  for _, form in ipairs({ "\\S\\n]", "\\S\\r\\n]", "\\S\\n\\r]", "\\S]" }) do
    if negated and rest:sub(1, #form) == form then
      return "[" .. CLASS_SHORTHANDS.s .. "]", j + #form
    end
  end

  local items = {}
  local first = true
  while true do
    local c = p:sub(j, j)
    if c == "" then
      return nil, "unterminated character class"
    elseif c == "]" and not first then
      break
    elseif c == "\\" then
      local n = p:sub(j + 1, j + 1)
      if CLASS_SHORTHANDS[n] then
        items[#items + 1] = CLASS_SHORTHANDS[n]
      elseif n == "D" or n == "W" or n == "S" then
        return nil, "negated shorthand \\" .. n .. " inside a character class is not supported"
      elseif n == "n" then
        -- Tours are matched one line at a time, so a newline never occurs.
        items[#items + 1] = ""
      elseif n == "t" or n == "r" then
        items[#items + 1] = "\\" .. n
      elseif n == "f" then
        items[#items + 1] = "\\x0c"
      elseif n == "v" then
        items[#items + 1] = "\\x0b"
      elseif n == "x" and p:sub(j + 2, j + 3):match("^%x%x$") then
        items[#items + 1] = "\\x" .. p:sub(j + 2, j + 3)
        j = j + 2
      elseif n == "u" and p:sub(j + 2, j + 5):match("^%x%x%x%x$") then
        items[#items + 1] = "\\u" .. p:sub(j + 2, j + 5)
        j = j + 4
      elseif n == "]" or n == "\\" or n == "^" or n == "-" then
        items[#items + 1] = "\\" .. n
      elseif n == "" then
        return nil, "trailing backslash"
      else
        items[#items + 1] = n
      end
      j = j + 2
    else
      items[#items + 1] = c
      j = j + 1
    end
    first = false
  end

  local body = table.concat(items)
  if body == "" then
    -- `[]` never matches and `[^]` matches anything (outside of newlines).
    return negated and "." or "%(x)@!x", j + 1
  end
  return "[" .. (negated and "^" or "") .. body .. "]", j + 1
end

local GROUP_PREFIXES = {
  { "(?:", "%(", ")" },
  { "(?=", "%(", ")@=" },
  { "(?!", "%(", ")@!" },
  { "(?<=", "%(", ")@<=" },
  { "(?<!", "%(", ")@<!" },
}

--- Converts a JavaScript regular expression source into a Vim pattern.
---@param pattern string
---@return string|nil vim_pattern
---@return string|nil err
function M.to_vim(pattern)
  local out = { "\\v\\C" }
  local groups = {}
  local i, n = 1, #pattern

  local function quantifier_suffix()
    -- Lazy quantifiers: `*?`, `+?`, `??`, `{n,m}?`
    if pattern:sub(i, i) == "?" then
      i = i + 1
      return true
    end
    return false
  end

  while i <= n do
    local c = pattern:sub(i, i)
    if c == "\\" then
      local e = pattern:sub(i + 1, i + 1)
      i = i + 2
      if e == "" then
        return nil, "trailing backslash"
      elseif SIMPLE_ESCAPES[e] then
        out[#out + 1] = SIMPLE_ESCAPES[e]
      elseif e == "B" or e == "c" or e == "k" or e == "p" or e == "P" then
        return nil, "unsupported escape \\" .. e
      elseif e == "x" and pattern:sub(i, i + 1):match("^%x%x$") then
        out[#out + 1] = "%x" .. pattern:sub(i, i + 1)
        i = i + 2
      elseif e == "u" and pattern:sub(i, i + 3):match("^%x%x%x%x$") then
        out[#out + 1] = "%u" .. pattern:sub(i, i + 3)
        i = i + 4
      elseif e:match("%d") then
        out[#out + 1] = "\\" .. e
      else
        out[#out + 1] = literal(e)
      end
    elseif c == "[" then
      local class, next_i = parse_class(pattern, i)
      if not class then
        return nil, next_i
      end
      out[#out + 1] = class
      i = next_i
    elseif c == "(" then
      local matched = false
      for _, prefix in ipairs(GROUP_PREFIXES) do
        if pattern:sub(i, i + #prefix[1] - 1) == prefix[1] then
          out[#out + 1] = prefix[2]
          groups[#groups + 1] = prefix[3]
          i = i + #prefix[1]
          matched = true
          break
        end
      end
      if not matched then
        local name = pattern:match("^%(%?<([%a_][%w_]*)>", i)
        if name then
          i = i + #name + 4
        elseif pattern:sub(i + 1, i + 1) == "?" then
          return nil, "unsupported group syntax"
        else
          i = i + 1
        end
        out[#out + 1] = "("
        groups[#groups + 1] = ")"
      end
    elseif c == ")" then
      local close = table.remove(groups)
      if not close then
        return nil, "unbalanced parenthesis"
      end
      out[#out + 1] = close
      i = i + 1
    elseif c == "*" or c == "+" or c == "?" then
      i = i + 1
      if quantifier_suffix() then
        out[#out + 1] = ({ ["*"] = "{-}", ["+"] = "{-1,}", ["?"] = "{-0,1}" })[c]
      else
        out[#out + 1] = c
      end
    elseif c == "{" then
      local body = pattern:match("^{(%d+,?%d*)}", i)
      if body then
        i = i + #body + 2
        out[#out + 1] = "{" .. (quantifier_suffix() and "-" or "") .. body .. "}"
      else
        out[#out + 1] = "\\{"
        i = i + 1
      end
    elseif c == "." or c == "^" or c == "$" or c == "|" then
      out[#out + 1] = c
      i = i + 1
    else
      out[#out + 1] = literal(c)
      i = i + 1
    end
  end

  if #groups > 0 then
    return nil, "unbalanced parenthesis"
  end

  return table.concat(out)
end

local cache = {}

--- Returns a compiled `vim.regex` for a JavaScript pattern (cached).
---@return any|nil regex
---@return string|nil err
function M.compile(pattern)
  local cached = cache[pattern]
  if cached then
    return cached.regex, cached.err
  end

  local vim_pattern, err = M.to_vim(pattern)
  local regex
  if vim_pattern then
    local ok, result = pcall(vim.regex, vim_pattern)
    if ok then
      regex = result
    else
      err = tostring(result)
    end
  end

  cache[pattern] = { regex = regex, err = err }
  return regex, err
end

--- Finds the first line in `lines` matching a JavaScript pattern.
---@return integer|nil line 0-based line index
function M.find_line(lines, pattern)
  local regex = M.compile(pattern)
  if not regex then
    return nil
  end
  for index, line in ipairs(lines) do
    if regex:match_str(line) then
      return index - 1
    end
  end
end

--- Escapes a string so that it matches literally in a JavaScript regex.
--- Mirrors `str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")`.
function M.escape(str)
  return (str:gsub("[%.%*%+%?%^%$%{%}%(%)|%[%]\\]", "\\%0"))
end

return M
