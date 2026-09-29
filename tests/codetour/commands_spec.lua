local helpers = require("tests.helpers")

describe("codetour.commands", function()
  local root, state, actions, commands

  before_each(function()
    helpers.reset()
    root = helpers.workspace({
      ["src/a.js"] = "function a() {\n}\n// end\n",
      [".tours/a.tour"] = helpers.tour({
        title = "Alpha",
        steps = {
          { description = "one" },
          { description = "two" },
          { file = "src/a.js", line = 2, description = "insert" },
          {
            file = "src/a.js",
            selection = { start = { line = 3, character = 4 }, ["end"] = { line = 3, character = 7 } },
            description = "replace",
          },
        },
      }),
      [".tours/b.tour"] = helpers.tour({ title = "Beta", steps = { { description = "b1" }, { description = "b2" } } }),
    })
    state = helpers.setup()
    actions = require("codetour.actions")
    commands = require("codetour.commands")
  end)

  it("runs the codetour commands used by links", function()
    actions.start_tour(state.tours[1])
    commands.execute("codetour.nextTourStep", {})
    assert.equals(1, state.active.step)
    commands.execute("codetour.previousTourStep", {})
    assert.equals(0, state.active.step)
    commands.execute("codetour.navigateToStep", { 3 })
    assert.equals(2, state.active.step)
    commands.execute("codetour.startTourByTitle", { "Beta", 2 })
    assert.equals("Beta", state.active.tour.title)
    assert.equals(1, state.active.step)
    commands.execute("codetour.finishTour", {})
    assert.is_nil(state.active)
  end)

  it("opens URLs and files with vscode.open", function()
    local opened = helpers.stub_open()
    commands.execute("vscode.open", { "https://example.com" })
    assert.same({ "https://example.com" }, opened)
    commands.execute("vscode.open", { "src/a.js" })
    assert.equals(root .. "/src/a.js", vim.api.nvim_buf_get_name(0))
  end)

  it("uses commands configured by the user", function()
    local calls = {}
    helpers.setup({
      commands = {
        ["my.fn"] = function(...)
          table.insert(calls, { ... })
        end,
        ["my.ex"] = "let g:codetour_test = 42",
      },
    })
    commands.execute("my.fn", { 1, "x" })
    commands.execute("my.ex", {})
    assert.same({ { 1, "x" } }, calls)
    assert.equals(42, vim.g.codetour_test)
  end)

  it("warns about unknown commands", function()
    commands.execute("workbench.action.unknown", {})
    assert.is_true(helpers.has_notification("isn't available in Neovim"))
  end)

  it("runs link actions", function()
    local opened = helpers.stub_open()
    commands.run_action({ type = "url", url = "https://a.b" })
    commands.run_action({ type = "file", path = root .. "/logo.png", image = true })
    assert.same({ "https://a.b", root .. "/logo.png" }, opened)
    commands.run_action({ type = "file", path = root .. "/src/a.js" })
    assert.equals(root .. "/src/a.js", vim.api.nvim_buf_get_name(0))
  end)

  it("focuses views, reporting unknown ones", function()
    local focused = false
    helpers.setup({
      views = {
        custom = function()
          focused = true
        end,
      },
    })
    assert.is_true(commands.focus_view("custom"))
    assert.is_true(focused)
    assert.is_false(commands.focus_view("does.not.exist"))
    assert.is_true(helpers.has_notification("attempting to focus a view which isn't available: does.not.exist"))
    assert.is_true(commands.focus_view("problems"))
  end)

  it("runs shell commands in a reusable terminal that closes with the tour", function()
    actions.start_tour(state.tours[1])
    local win = vim.api.nvim_get_current_win()
    commands.send_to_terminal("echo codetour-$((40 + 2))")
    local term = commands.terminal()
    assert.is_true(vim.api.nvim_buf_is_valid(term.buf))
    assert.equals(win, vim.api.nvim_get_current_win())
    assert.is_true(vim.wait(5000, function()
      return helpers.text(term.buf):find("codetour%-42") ~= nil
    end))

    commands.send_to_terminal("echo again")
    assert.equals(term.buf, commands.terminal().buf)

    actions.end_tour()
    assert.is_false(vim.api.nvim_buf_is_valid(term.buf))
  end)

  it("inserts code snippets at the step's line and keeps the step in place", function()
    actions.start_tour(state.tours[1], 2)
    commands.insert_code("const x = 1;\nconst y = 2;\n")
    local buf = require("codetour.player").step_buffer()
    assert.same({ "function a() {", "const x = 1;", "const y = 2;", "}", "// end" }, helpers.lines(buf))
    assert.equals(4, helpers.read_json(root .. "/.tours/a.tour").steps[3].line)
  end)

  it("replaces the step's selection with the snippet", function()
    actions.start_tour(state.tours[1], 3)
    commands.insert_code("END")
    assert.equals("// END", helpers.lines(require("codetour.player").step_buffer())[3])
  end)
end)
