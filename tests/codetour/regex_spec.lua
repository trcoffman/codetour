local regex = require("codetour.regex")

local function matches(pattern, text)
  local compiled, err = regex.compile(pattern)
  assert(compiled, ("pattern %q failed to compile: %s"):format(pattern, tostring(err)))
  return compiled:match_str(text) ~= nil
end

describe("codetour.regex", function()
  it("translates the patterns written by the VS Code recorder", function()
    local pattern = "^[^\\S\\n]*" .. regex.escape("function foo(a, b) {")
    assert.is_true(matches(pattern, "function foo(a, b) {"))
    assert.is_true(matches(pattern, "  \tfunction foo(a, b) {"))
    assert.is_false(matches(pattern, "x function foo(a, b) {"))
    assert.is_false(matches(pattern, "function fooXa, b) {"))
  end)

  it("escapes the same characters as the VS Code recorder", function()
    assert.equals("a\\.b\\*c\\+\\?\\^\\$\\{\\}\\(\\)\\|\\[\\]\\\\", regex.escape("a.b*c+?^${}()|[]\\"))
  end)

  it("matches escaped special characters literally", function()
    for _, text in ipairs({ "a.b", "x*y", "f(x)", "[1]", "a|b", "$var", "^x", "{y}", "c\\d", "a+b", "q?" }) do
      assert.is_true(matches("^" .. regex.escape(text) .. "$", text), text)
    end
    assert.is_false(matches("a\\.b", "axb"))
  end)

  it("treats characters that are special to Vim literally", function()
    for _, text in ipairs({ "<div>", "a=b", "x@y", "50%", "a&b", "~/x", "a/b", "'q'", '"q"', "a-b", "#x", "a b", "x,y", "a:b;c", "!x" }) do
      assert.is_true(matches(regex.escape(text), text), text)
    end
    assert.is_true(matches("{abc", "{abc"))
  end)

  it("keeps the dot of step markers as a wildcard", function()
    assert.is_true(matches("CT1.2", "// CT1.2 - Setup"))
    assert.is_true(matches("CT1.2", "CT1x2"))
    assert.is_false(matches("CT1.2", "CT1.3"))
  end)

  it("supports shorthand classes, anchors and word boundaries", function()
    assert.is_true(matches("^\\d+$", "123"))
    assert.is_false(matches("^\\d+$", "12a"))
    assert.is_true(matches("\\w+\\s\\w+", "hello world"))
    assert.is_true(matches("\\bfoo\\b", "a foo b"))
    assert.is_false(matches("\\bfoo\\b", "afoob"))
    assert.is_true(matches("\\D\\W\\S", "a b"))
  end)

  it("supports quantifiers, including lazy and bounded ones", function()
    assert.is_true(matches("^a{2,3}$", "aaa"))
    assert.is_false(matches("^a{2,3}$", "a"))
    assert.is_true(matches("^a{2}$", "aa"))
    assert.is_true(matches("a.*?b", "axxb"))
    assert.is_true(matches("^x+?y??$", "xx"))
    assert.is_true(matches("colou?r", "color"))
  end)

  it("supports groups, alternation and lookarounds", function()
    assert.is_true(matches("^(?:ab)+$", "abab"))
    assert.is_true(matches("^(cat|dog)s$", "dogs"))
    assert.is_true(matches("^(?<name>\\w+)=", "key=value"))
    assert.is_true(matches("foo(?=bar)", "foobar"))
    assert.is_false(matches("foo(?=bar)", "foobaz"))
    assert.is_true(matches("foo(?!bar)", "foobaz"))
    assert.is_false(matches("foo(?!bar)", "foobar"))
    assert.is_true(matches("(?<=\\$)\\d+", "$42"))
    assert.is_false(matches("(?<!\\$)\\b\\d+", "$42"))
    assert.is_true(matches("^(a)\\1$", "aa"))
  end)

  it("supports character classes", function()
    assert.is_true(matches("^[a-z]+$", "abc"))
    assert.is_false(matches("^[a-z]+$", "aBc"))
    assert.is_true(matches("^[^0-9]+$", "abc"))
    assert.is_true(matches("^[\\d\\s]+$", "1 2 3"))
    assert.is_true(matches("^[.]$", "."))
    assert.is_false(matches("^[.]$", "x"))
    assert.is_true(matches("^[\\]x]+$", "]x]"))
    assert.is_true(matches("^[a\\-z]+$", "a-z"))
    assert.is_true(matches("^[\\x41]$", "A"))
  end)

  it("supports hex and unicode escapes", function()
    assert.is_true(matches("\\x41\\u00e9", "Aé"))
  end)

  it("is case sensitive", function()
    assert.is_false(matches("abc", "ABC"))
  end)

  it("rejects unsupported syntax", function()
    for _, pattern in ipairs({ "\\p{L}", "(abc", "abc)", "[abc", "[\\S]" }) do
      local result, err = regex.to_vim(pattern)
      assert.is_nil(result, pattern)
      assert.is_string(err)
    end
  end)

  it("finds the first matching line", function()
    assert.equals(1, regex.find_line({ "a", "foo 1", "foo 2" }, "^foo"))
    assert.is_nil(regex.find_line({ "a" }, "^foo"))
    assert.is_nil(regex.find_line({ "a" }, "(unbalanced"))
  end)
end)
