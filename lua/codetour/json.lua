-- Order-preserving JSON codec.
--
-- Tour files are checked into repositories and are frequently edited by hand,
-- so re-saving one must not shuffle its keys or change its formatting.
-- `vim.json` loses key order and escapes "/" so this module implements a
-- small decoder that remembers key order and an encoder whose output matches
-- `JSON.stringify(value, null, 2)` (which is what the VS Code extension uses).

local M = {}

M.null = vim.NIL

-- Side tables keyed by table identity, so decoded values stay plain tables.
local key_order = setmetatable({}, { __mode = "k" })
local array_tables = setmetatable({}, { __mode = "k" })

--- Marks `t` as a JSON array (needed to encode empty arrays as `[]`).
function M.array(t)
  t = t or {}
  array_tables[t] = true
  key_order[t] = nil
  return t
end

--- Marks `t` as a JSON object whose keys are emitted in `keys` order first.
function M.object(t, keys)
  t = t or {}
  array_tables[t] = nil
  key_order[t] = keys and vim.list_extend({}, keys) or {}
  return t
end

function M.is_array(t)
  if array_tables[t] then
    return true
  end
  if key_order[t] then
    return false
  end
  -- Unmarked tables: empty ones are treated as arrays because the only empty
  -- containers in the tour schema are `steps` and `commands`.
  return next(t) == nil or vim.islist(t)
end

--- Returns the keys of an object in encoding order.
function M.keys(t, preferred)
  local seen, keys = {}, {}
  for _, k in ipairs(key_order[t] or {}) do
    if t[k] ~= nil and not seen[k] then
      seen[k] = true
      keys[#keys + 1] = k
    end
  end

  local extra = {}
  for k in pairs(t) do
    if type(k) == "string" and not seen[k] then
      extra[#extra + 1] = k
    end
  end

  local rank = {}
  for i, k in ipairs(preferred or {}) do
    rank[k] = i
  end
  table.sort(extra, function(a, b)
    local ra, rb = rank[a] or math.huge, rank[b] or math.huge
    if ra ~= rb then
      return ra < rb
    end
    return a < b
  end)

  return vim.list_extend(keys, extra)
end

--- Deep copy that preserves key order and array markers.
function M.copy(value)
  if type(value) ~= "table" or value == M.null then
    return value
  end
  local result = {}
  for k, v in pairs(value) do
    result[k] = M.copy(v)
  end
  if array_tables[value] then
    array_tables[result] = true
  end
  if key_order[value] then
    key_order[result] = vim.list_extend({}, key_order[value])
  end
  return result
end

-- Decoding ---------------------------------------------------------------

local ESCAPES = {
  ['"'] = '"',
  ["\\"] = "\\",
  ["/"] = "/",
  b = "\b",
  f = "\f",
  n = "\n",
  r = "\r",
  t = "\t",
}

local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40
    )
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end

--- Decodes a JSON string.
---@param str string
---@param opts? { jsonc?: boolean } allow comments and trailing commas
function M.decode(str, opts)
  local jsonc = opts and opts.jsonc
  local pos = 1

  if str:sub(1, 3) == "\239\187\191" then
    pos = 4
  end

  local function fail(msg)
    local before = str:sub(1, pos - 1)
    local _, newlines = before:gsub("\n", "")
    local column = pos - (before:match(".*()\n") or 0)
    error(("invalid JSON at line %d, column %d: %s"):format(newlines + 1, column, msg), 0)
  end

  local function skip()
    while true do
      local _, e = str:find("^[ \t\r\n]+", pos)
      if e then
        pos = e + 1
      end
      if not jsonc then
        return
      end
      local two = str:sub(pos, pos + 1)
      if two == "//" then
        local nl = str:find("\n", pos, true)
        pos = nl and nl + 1 or #str + 1
      elseif two == "/*" then
        local _, close = str:find("*/", pos + 2, true)
        if not close then
          fail("unterminated comment")
        end
        pos = close + 1
      else
        return
      end
    end
  end

  local parse_value

  local function parse_string()
    pos = pos + 1
    local parts = {}
    while true do
      local s = str:find('["\\]', pos)
      if not s then
        fail("unterminated string")
      end
      parts[#parts + 1] = str:sub(pos, s - 1)
      if str:sub(s, s) == '"' then
        pos = s + 1
        return table.concat(parts)
      end
      local esc = str:sub(s + 1, s + 1)
      if ESCAPES[esc] then
        parts[#parts + 1] = ESCAPES[esc]
        pos = s + 2
      elseif esc == "u" then
        local hex = str:sub(s + 2, s + 5)
        if not hex:match("^%x%x%x%x$") then
          pos = s
          fail("invalid unicode escape")
        end
        local cp = tonumber(hex, 16)
        pos = s + 6
        if cp >= 0xD800 and cp <= 0xDBFF and str:sub(pos, pos + 1) == "\\u" then
          local low = tonumber(str:sub(pos + 2, pos + 5), 16)
          if low and low >= 0xDC00 and low <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
            pos = pos + 6
          end
        end
        parts[#parts + 1] = utf8_char(cp)
      else
        pos = s
        fail("invalid escape sequence")
      end
    end
  end

  local function parse_number()
    local num = str:match("^-?%d+%.?%d*[eE][-+]?%d+", pos) or str:match("^-?%d+%.?%d*", pos)
    if not num then
      fail("unexpected character '" .. str:sub(pos, pos) .. "'")
    end
    pos = pos + #num
    return tonumber(num)
  end

  local function parse_array()
    local result = M.array({})
    pos = pos + 1
    skip()
    if str:sub(pos, pos) == "]" then
      pos = pos + 1
      return result
    end
    while true do
      result[#result + 1] = parse_value()
      skip()
      local c = str:sub(pos, pos)
      pos = pos + 1
      if c == "]" then
        return result
      elseif c ~= "," then
        pos = pos - 1
        fail("expected ',' or ']'")
      end
      skip()
      if jsonc and str:sub(pos, pos) == "]" then
        pos = pos + 1
        return result
      end
    end
  end

  local function parse_object()
    local result, keys = {}, {}
    pos = pos + 1
    key_order[result] = keys
    skip()
    if str:sub(pos, pos) == "}" then
      pos = pos + 1
      return result
    end
    while true do
      if str:sub(pos, pos) ~= '"' then
        fail("expected string key")
      end
      local key = parse_string()
      skip()
      if str:sub(pos, pos) ~= ":" then
        fail("expected ':'")
      end
      pos = pos + 1
      if result[key] == nil then
        keys[#keys + 1] = key
      end
      result[key] = parse_value()
      skip()
      local c = str:sub(pos, pos)
      pos = pos + 1
      if c == "}" then
        return result
      elseif c ~= "," then
        pos = pos - 1
        fail("expected ',' or '}'")
      end
      skip()
      if jsonc and str:sub(pos, pos) == "}" then
        pos = pos + 1
        return result
      end
    end
  end

  parse_value = function()
    skip()
    local c = str:sub(pos, pos)
    if c == "{" then
      return parse_object()
    elseif c == "[" then
      return parse_array()
    elseif c == '"' then
      return parse_string()
    elseif str:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif str:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif str:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return M.null
    elseif c == "" then
      fail("unexpected end of input")
    end
    return parse_number()
  end

  local value = parse_value()
  skip()
  if pos <= #str then
    fail("unexpected trailing characters")
  end
  return value
end

-- Encoding ---------------------------------------------------------------

local CHAR_ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function encode_string(s)
  return '"'
    .. s:gsub('[%z\1-\31"\\]', function(c)
      return CHAR_ESCAPES[c] or ("\\u%04x"):format(c:byte())
    end)
    .. '"'
end

local function encode_number(n)
  if n ~= n or n == math.huge or n == -math.huge then
    return "null"
  end
  if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
    return ("%d"):format(n)
  end
  for precision = 15, 17 do
    local s = ("%." .. precision .. "g"):format(n)
    if tonumber(s) == n then
      return s
    end
  end
  return tostring(n)
end

--- Encodes a value the same way as `JSON.stringify(value, null, 2)`.
---@param value any
---@param opts? { preferred_keys?: string[] } order for keys not seen when decoding
function M.encode(value, opts)
  local preferred = opts and opts.preferred_keys

  local function encode(v, indent)
    local t = type(v)
    if v == nil or v == M.null then
      return "null"
    elseif t == "boolean" then
      return tostring(v)
    elseif t == "number" then
      return encode_number(v)
    elseif t == "string" then
      return encode_string(v)
    elseif t ~= "table" then
      error("cannot encode value of type " .. t)
    end

    local inner = indent .. "  "
    local items = {}
    if M.is_array(v) then
      for i = 1, #v do
        items[#items + 1] = inner .. encode(v[i], inner)
      end
      if #items == 0 then
        return "[]"
      end
      return "[\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "]"
    end

    for _, k in ipairs(M.keys(v, preferred)) do
      local item = v[k]
      if type(item) ~= "function" then
        items[#items + 1] = inner .. encode_string(k) .. ": " .. encode(item, inner)
      end
    end
    if #items == 0 then
      return "{}"
    end
    return "{\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "}"
  end

  return encode(value, "")
end

return M
