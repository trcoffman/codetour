local markdown = require("codetour.markdown")

local tours = {
  { id = "/ws/.tours/intro.tour", title = "1 - Intro", steps = {} },
  { id = "/ws/.tours/tree.tour", title = "Tree View", steps = {} },
}
local ctx = { root = "/ws", tours = tours }

local function render(text)
  local b = markdown.render(text, ctx)
  return b:markdown(), b.actions
end

describe("codetour.markdown", function()
  it("leaves regular markdown alone", function()
    local text = "# Title\n\n**bold** and `code` with [a link](https://example.com) and ![img](./a.png)\n\n- item"
    local out, actions = render(text)
    assert.equals(text, out)
    assert.same({}, actions)
  end)

  it("turns `>>` lines into terminal commands", function()
    local out, actions = render("Run it:\n>> npm test -- --watch")
    assert.equals("Run it:\n> [npm test -- --watch](codetour:1)", out)
    assert.same({ type = "command", name = "codetour.sendTextToTerminal", args = { "npm test -- --watch" } }, actions[1])
  end)

  it("links step references", function()
    local out, actions = render("See [#2] and [the setup][#3].")
    assert.equals("See [#2](codetour:1) and [the setup](codetour:2).", out)
    assert.same({ 2 }, actions[1].args)
    assert.equals("codetour.navigateToStep", actions[2].name)
    assert.same({ 3 }, actions[2].args)
  end)

  it("links tour references by (stripped) title", function()
    local out, actions = render("Next: [Intro], [Tree View#4] or [custom][Intro#2].")
    assert.equals("Next: [1 - Intro](codetour:1), [Tree View](codetour:2) or [custom](codetour:3).", out)
    assert.same({ type = "command", name = "codetour.startTourByTitle", args = { "1 - Intro" } }, actions[1])
    assert.same({ "Tree View", 4 }, actions[2].args)
    assert.same({ "1 - Intro", 2 }, actions[3].args)
  end)

  it("leaves unknown references and checkboxes alone", function()
    local text = "- [ ] todo\n- [x] done\n[Unknown] [a][Unknown] [#x]"
    assert.equals(text, (render(text)))
  end)

  it("rewrites command links so renderers can parse them", function()
    local out, actions = render('[Run tests](command:codetour.sendTextToTerminal?["npm test"] "Run") and [Stop](command:codetour.endTour)')
    assert.equals("[Run tests](codetour:1) and [Stop](codetour:2)", out)
    assert.same({ "npm test" }, actions[1].args)
    assert.same({ type = "command", name = "codetour.endTour", args = {} }, actions[2])
  end)

  it("decodes URL-encoded command arguments", function()
    local _, actions = render("[x](command:codetour.startTourByTitle?%5B%22Tree%20View%22%5D)")
    assert.same({ "Tree View" }, actions[1].args)
  end)

  it("doesn't transform references inside code", function()
    local text = "`[#2]` and\n```\n[#3]\n>> not a command\n```"
    assert.equals(text, (render(text)))
  end)

  it("offers to insert fenced code that has a language", function()
    local out, actions = render("```js\nconst a = 1;\nconst b = 2;\n```\ntext\n```\nplain\n```\n~~~py\nx = 1\n~~~")
    assert.equals(
      "```js\nconst a = 1;\nconst b = 2;\n```\n↪ [Insert Code](codetour:1)\ntext\n```\nplain\n```\n~~~py\nx = 1\n~~~\n↪ [Insert Code](codetour:2)",
      out
    )
    assert.same({ "const a = 1;\nconst b = 2;" }, actions[1].args)
    assert.same({ "x = 1" }, actions[2].args)
  end)

  it("escapes brackets in generated labels", function()
    local b = markdown.builder()
    b:link("a [b] c", { type = "url", url = "x" })
    assert.equals("[a \\[b\\] c](codetour:1)", b:markdown())
  end)

  describe("links", function()
    local lines = {
      "Go [#2](codetour:1) or [docs](https://example.com/a_(b)) or https://example.org/x.",
      "`[not](a)` <https://auto.link> ![img](./i.png)",
      "```",
      "[inside](code)",
      "```",
    }

    it("finds links outside of code", function()
      local links = markdown.links(lines)
      local dests = vim.tbl_map(function(link)
        return link.dest
      end, links)
      assert.same({ "codetour:1", "https://example.com/a_(b)", "https://example.org/x", "https://auto.link", "./i.png" }, dests)
      assert.same({ row = 0, col = 3, end_col = 19 }, { row = links[1].row, col = links[1].col, end_col = links[1].end_col })
    end)

    it("finds the link under the cursor", function()
      assert.equals("codetour:1", markdown.link_at(lines, 0, 5).dest)
      assert.is_nil(markdown.link_at(lines, 0, 0))
      assert.equals("https://example.org/x", markdown.link_at(lines, 0, 70).dest)
    end)
  end)

  describe("resolve", function()
    it("resolves every kind of destination", function()
      local actions = { { type = "command", name = "x", args = {} } }
      assert.equals(actions[1], markdown.resolve("codetour:1", { actions = actions }))
      assert.same({ type = "url", url = "https://a.b" }, markdown.resolve("https://a.b", ctx))
      assert.same({ type = "file", path = "/ws/src/a b.js" }, markdown.resolve("./src/a%20b.js", ctx))
      assert.same({ type = "file", path = "/ws/docs/x.md" }, markdown.resolve("docs/x.md", ctx))
      assert.same({ type = "file", path = "/tmp/x" }, markdown.resolve("file:///tmp/x", ctx))
      assert.same({ type = "command", name = "codetour.navigateToStep", args = { 2 } }, markdown.resolve("command:codetour.navigateToStep?2", ctx))
      assert.is_nil(markdown.resolve("#anchor", ctx))
    end)

    it("parses step commands", function()
      assert.same({ type = "command", name = "a.b", args = {} }, markdown.parse_command("a.b"))
      assert.same({ type = "command", name = "a.b", args = { 2 } }, markdown.parse_command("a.b?2"))
      assert.same({ type = "command", name = "a.b", args = { "x", 1 } }, markdown.parse_command('a.b?["x", 1]'))
      assert.same({ type = "command", name = "a.b", args = { "raw" } }, markdown.parse_command("a.b?raw"))
    end)
  end)
end)
