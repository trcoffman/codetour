-- Evaluates a tour's `when` clause.
--
-- The VS Code extension evaluates these with jexl, so this implements the
-- subset of jexl/JavaScript expression syntax that is useful for conditions:
-- literals, identifiers, member access, `!`, `&&`, `||`, comparisons, `in`,
-- arithmetic and the ternary operator.

local M = {}

local OPERATORS = {
  "===",
  "!==",
  "==",
  "!=",
  "<=",
  ">=",
  "&&",
  "||",
  "//",
  "!",
  "<",
  ">",
  "+",
  "-",
  "*",
  "/",
  "%",
  "(",
  ")",
  "[",
  "]",
  ".",
  "?",
  ":",
  ",",
}

local KEYWORDS = { ["true"] = true, ["false"] = false }

local function tokenize(src)
  local tokens, i = {}, 1
  while i <= #src do
    local c = src:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c:match("[%a_$]") then
      local ident = src:match("^[%w_$]+", i)
      tokens[#tokens + 1] = { kind = "ident", value = ident }
      i = i + #ident
    elseif c:match("%d") or (c == "." and src:sub(i + 1, i + 1):match("%d")) then
      local num = src:match("^%d*%.?%d+[eE][-+]?%d+", i) or src:match("^%d*%.?%d+", i)
      tokens[#tokens + 1] = { kind = "value", value = tonumber(num) }
      i = i + #num
    elseif c == '"' or c == "'" then
      local j, parts = i + 1, {}
      while true do
        local ch = src:sub(j, j)
        if ch == "" then
          error("unterminated string", 0)
        elseif ch == "\\" then
          parts[#parts + 1] = src:sub(j + 1, j + 1)
          j = j + 2
        elseif ch == c then
          break
        else
          parts[#parts + 1] = ch
          j = j + 1
        end
      end
      tokens[#tokens + 1] = { kind = "value", value = table.concat(parts) }
      i = j + 1
    else
      local matched
      for _, op in ipairs(OPERATORS) do
        if src:sub(i, i + #op - 1) == op then
          matched = op
          break
        end
      end
      if not matched then
        error("unexpected character '" .. c .. "'", 0)
      end
      tokens[#tokens + 1] = { kind = "op", value = matched }
      i = i + #matched
    end
  end
  return tokens
end

--- JavaScript truthiness.
function M.truthy(v)
  return not (v == nil or v == false or v == 0 or v == "" or v ~= v or v == vim.NIL)
end

local function loose_equals(a, b)
  if a == vim.NIL then
    a = nil
  end
  if b == vim.NIL then
    b = nil
  end
  if type(a) == type(b) then
    return a == b
  end
  if a == nil or b == nil then
    return false
  end
  local function num(v)
    if type(v) == "boolean" then
      return v and 1 or 0
    end
    return tonumber(v)
  end
  local na, nb = num(a), num(b)
  return na ~= nil and na == nb
end

local function contains(haystack, needle)
  if type(haystack) == "string" and type(needle) == "string" then
    return haystack:find(needle, 1, true) ~= nil
  elseif type(haystack) == "table" then
    for _, v in ipairs(haystack) do
      if loose_equals(v, needle) then
        return true
      end
    end
  end
  return false
end

local function arith(op, a, b)
  if op == "+" and (type(a) == "string" or type(b) == "string") then
    return tostring(a == nil and "undefined" or a) .. tostring(b == nil and "undefined" or b)
  end
  a, b = tonumber(a) or 0, tonumber(b) or 0
  if op == "+" then
    return a + b
  elseif op == "-" then
    return a - b
  elseif op == "*" then
    return a * b
  elseif op == "/" then
    return a / b
  elseif op == "//" then
    return math.floor(a / b)
  end
  return math.fmod(a, b)
end

local function compare(op, a, b)
  if a == nil or b == nil then
    return false
  end
  if type(a) ~= type(b) then
    a, b = tonumber(a), tonumber(b)
    if not a or not b then
      return false
    end
  end
  if op == "<" then
    return a < b
  elseif op == "<=" then
    return a <= b
  elseif op == ">" then
    return a > b
  end
  return a >= b
end

--- Evaluates `expr` against `context`.
---@return any value
function M.evaluate(expr, context)
  local tokens = tokenize(expr)
  local pos = 1

  local function peek(value)
    local tok = tokens[pos]
    return tok and tok.kind == "op" and tok.value == value
  end

  local function expect(value)
    if not peek(value) then
      error("expected '" .. value .. "'", 0)
    end
    pos = pos + 1
  end

  local ternary

  local function primary()
    local tok = tokens[pos]
    if not tok then
      error("unexpected end of expression", 0)
    end
    pos = pos + 1
    if tok.kind == "value" then
      return tok.value
    elseif tok.kind == "ident" then
      if KEYWORDS[tok.value] ~= nil then
        return KEYWORDS[tok.value]
      elseif tok.value == "null" or tok.value == "undefined" then
        return nil
      end
      return context[tok.value]
    elseif tok.value == "(" then
      local value = ternary()
      expect(")")
      return value
    elseif tok.value == "[" then
      local list = {}
      while not peek("]") do
        list[#list + 1] = ternary()
        if not peek(",") then
          break
        end
        pos = pos + 1
      end
      expect("]")
      return list
    end
    error("unexpected '" .. tostring(tok.value) .. "'", 0)
  end

  local function postfix()
    local value = primary()
    while true do
      if peek(".") then
        pos = pos + 1
        local tok = tokens[pos]
        if not tok or tok.kind ~= "ident" then
          error("expected property name", 0)
        end
        pos = pos + 1
        value = type(value) == "table" and value[tok.value] or nil
      elseif peek("[") then
        pos = pos + 1
        local key = ternary()
        expect("]")
        if type(value) == "table" then
          value = value[type(key) == "number" and key + 1 or key]
        else
          value = nil
        end
      else
        return value
      end
    end
  end

  local function unary()
    if peek("!") then
      pos = pos + 1
      return not M.truthy(unary())
    elseif peek("-") then
      pos = pos + 1
      return -(tonumber(unary()) or 0)
    end
    return postfix()
  end

  local function binary(next_level, ops, apply)
    return function()
      local left = next_level()
      while true do
        local tok = tokens[pos]
        if not (tok and tok.kind == "op" and ops[tok.value]) then
          if not (tok and tok.kind == "ident" and ops[tok.value]) then
            return left
          end
        end
        pos = pos + 1
        left = apply(tok.value, left, next_level())
      end
    end
  end

  local multiplicative = binary(unary, { ["*"] = true, ["/"] = true, ["//"] = true, ["%"] = true }, arith)
  local additive = binary(multiplicative, { ["+"] = true, ["-"] = true }, arith)
  local relational = binary(
    additive,
    { ["<"] = true, ["<="] = true, [">"] = true, [">="] = true, ["in"] = true },
    function(op, a, b)
      if op == "in" then
        return contains(b, a)
      end
      return compare(op, a, b)
    end
  )
  local equality = binary(
    relational,
    { ["=="] = true, ["!="] = true, ["==="] = true, ["!=="] = true },
    function(op, a, b)
      local equal = loose_equals(a, b)
      if op == "!=" or op == "!==" then
        return not equal
      end
      return equal
    end
  )
  local logical_and = binary(equality, { ["&&"] = true }, function(_, a, b)
    return M.truthy(a) and M.truthy(b)
  end)
  local logical_or = binary(logical_and, { ["||"] = true }, function(_, a, b)
    return M.truthy(a) or M.truthy(b)
  end)

  ternary = function()
    local condition = logical_or()
    if peek("?") then
      pos = pos + 1
      local consequent = ternary()
      expect(":")
      local alternate = ternary()
      if M.truthy(condition) then
        return consequent
      end
      return alternate
    end
    return condition
  end

  local value = ternary()
  if pos <= #tokens then
    error("unexpected '" .. tostring(tokens[pos].value) .. "'", 0)
  end
  return value
end

--- The variables available to `when` clauses.
function M.context()
  local sysname = vim.uv.os_uname().sysname
  return {
    isLinux = sysname == "Linux",
    isMac = sysname == "Darwin",
    isWindows = sysname:find("Windows") ~= nil,
    isWeb = false,
    isNeovim = true,
  }
end

--- Returns whether a `when` clause is satisfied.
---@return boolean
---@return string|nil err
function M.matches(expr, context)
  local ok, result = pcall(M.evaluate, expr, context or M.context())
  if not ok then
    return false, result
  end
  return M.truthy(result)
end

return M
