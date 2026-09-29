local when = require("codetour.when")

describe("codetour.when", function()
  local linux = { isLinux = true, isMac = false, isWindows = false, isWeb = false, isNeovim = true }

  local function eval(expr, ctx)
    return (when.matches(expr, ctx or linux))
  end

  it("evaluates the platform variables", function()
    assert.is_true(eval("isLinux"))
    assert.is_false(eval("isMac"))
    assert.is_true(eval("!isWindows"))
    assert.is_true(eval("isMac || isLinux"))
    assert.is_false(eval("isMac && isLinux"))
    assert.is_true(eval("isNeovim"))
    assert.is_false(eval("isWeb"))
  end)

  it("provides a context for the current platform", function()
    local ctx = when.context()
    assert.is_true(ctx.isNeovim)
    assert.is_false(ctx.isWeb)
    local platforms = (ctx.isLinux and 1 or 0) + (ctx.isMac and 1 or 0) + (ctx.isWindows and 1 or 0)
    assert.is_true(platforms <= 1)
  end)

  it("treats unknown identifiers as undefined", function()
    assert.is_false(eval("isVSCode"))
    assert.is_true(eval("!isVSCode"))
    assert.is_false(eval("a.b.c"))
  end)

  it("respects operator precedence and parentheses", function()
    assert.is_true(eval("isLinux || isMac && isWindows"))
    assert.is_false(eval("(isLinux || isMac) && isWindows"))
    assert.is_true(eval("!(isMac || isWindows)"))
  end)

  it("supports comparisons, arithmetic and literals", function()
    assert.is_true(eval("1 + 2 * 3 == 7"))
    assert.is_true(eval("10 / 4 > 2"))
    assert.is_true(eval("7 % 4 === 3"))
    assert.is_true(eval("'a' == \"a\""))
    assert.is_true(eval("'abc' != 'abd'"))
    assert.is_true(eval("2 >= 2 && 1 <= 1 && 1 < 2"))
    assert.is_true(eval("'a' + 'b' == 'ab'"))
    assert.is_false(eval("null"))
    assert.is_true(eval("true"))
    assert.is_false(eval("0"))
    assert.is_false(eval("''"))
  end)

  it("supports `in`, member access, arrays and the ternary operator", function()
    local ctx = { user = { name = "ada" }, list = { "x", "y" } }
    assert.is_true(eval("'ad' in user.name", ctx))
    assert.is_true(eval("'y' in list", ctx))
    assert.is_false(eval("'z' in list", ctx))
    assert.is_true(eval("user['name'] == 'ada'", ctx))
    assert.is_true(eval("list[1] == 'y'", ctx))
    assert.is_true(eval("'b' in ['a', 'b']", ctx))
    assert.is_true(eval("user.name == 'ada' ? true : false", ctx))
    assert.is_false(eval("user.name == 'bob' ? true : false", ctx))
  end)

  it("reports syntax errors as not matching", function()
    for _, expr in ipairs({ "isLinux &&", "(isLinux", "isLinux ^ 2", "'unterminated" }) do
      local ok, err = when.matches(expr, linux)
      assert.is_false(ok, expr)
      assert.is_string(err, expr)
    end
  end)
end)
