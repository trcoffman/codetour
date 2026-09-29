local json = require("codetour.json")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

describe("codetour.json", function()
  it("decodes JSON values", function()
    local value = json.decode('{"a": 1, "b": [true, false, null], "c": {"d": "e"}, "f": -1.5e2}')
    assert.equals(1, value.a)
    assert.equals(true, value.b[1])
    assert.equals(false, value.b[2])
    assert.equals(vim.NIL, value.b[3])
    assert.equals("e", value.c.d)
    assert.equals(-150, value.f)
  end)

  it("encodes like JSON.stringify(value, null, 2)", function()
    local value = json.decode('{"title":"T","steps":[{"file":"a.js","line":3}],"empty":[],"obj":{}}')
    assert.equals(
      table.concat({
        "{",
        '  "title": "T",',
        '  "steps": [',
        "    {",
        '      "file": "a.js",',
        '      "line": 3',
        "    }",
        "  ],",
        '  "empty": [],',
        '  "obj": {}',
        "}",
      }, "\n"),
      json.encode(value)
    )
  end)

  it("preserves the key order of decoded objects", function()
    local source = '{\n  "zeta": 1,\n  "alpha": 2,\n  "mid": {\n    "b": 1,\n    "a": 2\n  }\n}'
    assert.equals(source, json.encode(json.decode(source)))
  end)

  it("round-trips the repository's own tour file byte for byte", function()
    local fd = assert(io.open(root .. "/.tours/intro.tour", "rb"))
    local source = fd:read("*a")
    fd:close()
    assert.equals(source, json.encode(json.decode(source)))
  end)

  it("appends new keys after the existing ones", function()
    local value = json.decode('{"b": 1, "a": 2}')
    value.c = 3
    value.a = 4
    assert.equals('{\n  "b": 1,\n  "a": 4,\n  "c": 3\n}', json.encode(value))
  end)

  it("orders several new keys by the preferred key list", function()
    local value = json.decode('{"x": 1}')
    value.line = 2
    value.file = "f"
    assert.equals(
      '{\n  "x": 1,\n  "file": "f",\n  "line": 2\n}',
      json.encode(value, { preferred_keys = { "file", "line" } })
    )
  end)

  it("drops keys that were set to nil", function()
    local value = json.decode('{"a": 1, "b": 2}')
    value.a = nil
    assert.equals('{\n  "b": 2\n}', json.encode(value))
  end)

  it("escapes strings like JSON.stringify", function()
    local encoded = json.encode("quote\" backslash\\ newline\n tab\t slash/ é 😀 \1 \127")
    assert.equals('"quote\\" backslash\\\\ newline\\n tab\\t slash/ é 😀 \\u0001 \127"', encoded)
  end)

  it("decodes unicode escapes, including surrogate pairs", function()
    assert.equals("é😀/", json.decode('"\\u00e9\\ud83d\\ude00\\/"'))
  end)

  it("formats numbers without a trailing .0", function()
    assert.equals("[\n  12,\n  -3,\n  0.5,\n  1.25\n]", json.encode(json.array({ 12, -3, 0.5, 1.25 })))
  end)

  it("keeps empty arrays and objects distinct", function()
    local value = json.decode('{"a": [], "b": {}}')
    assert.equals('{\n  "a": [],\n  "b": {}\n}', json.encode(value))
  end)

  it("strips a byte order mark", function()
    assert.equals(1, json.decode('\239\187\191{"a": 1}').a)
  end)

  it("supports comments and trailing commas in JSONC mode", function()
    local value = json.decode('{\n // comment\n "a": 1, /* block */\n "b": [1, 2,],\n}', { jsonc = true })
    assert.equals(1, value.a)
    assert.same({ 1, 2 }, { value.b[1], value.b[2] })
    assert.has_error(function()
      json.decode('{"a": 1,}')
    end)
  end)

  it("reports the line and column of syntax errors", function()
    local ok, err = pcall(json.decode, '{\n  "a": 1,\n  "b": }')
    assert.is_false(ok)
    assert.matches("line 3, column 8", err)
  end)

  it("copies values together with their key order", function()
    local value = json.decode('{"b": {"y": 1, "x": 2}, "a": []}')
    local copy = json.copy(value)
    assert.are_not.equal(value.b, copy.b)
    assert.equals(json.encode(value), json.encode(copy))
  end)

  it("lets objects declare their key order", function()
    local value = json.object({ title = "T", steps = json.array(), ["$schema"] = "s" }, { "$schema", "title", "steps" })
    assert.equals('{\n  "$schema": "s",\n  "title": "T",\n  "steps": []\n}', json.encode(value))
  end)
end)
