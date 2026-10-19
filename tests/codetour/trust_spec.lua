local helpers = require("tests.helpers")

describe("codetour.trust", function()
  local root, state, actions, commands, trust, ran, answers, asked

  local function tour_path()
    return root .. "/.tours/a.tour"
  end

  local function run(text)
    commands.execute("codetour.sendTextToTerminal", { text or "echo hi" })
  end

  before_each(function()
    helpers.reset()
    root = helpers.workspace({
      [".tours/a.tour"] = helpers.tour({ title = "Alpha", steps = { { description = "one" }, { description = "two" } } }),
    })
    state = helpers.setup()
    actions = require("codetour.actions")
    commands = require("codetour.commands")
    trust = require("codetour.trust")

    ran, asked, answers = {}, {}, {}
    commands.send_to_terminal = function(text)
      table.insert(ran, text)
    end
    trust.confirm = function(message, choices, default)
      table.insert(asked, { message = message, choices = choices, default = default })
      return table.remove(answers, 1) or default
    end
    actions.start_tour(state.tours[1])
  end)

  after_each(function()
    package.loaded["codetour.commands"] = nil
    package.loaded["codetour.trust"] = nil
  end)

  it("asks before running shell text and shows what would run", function()
    answers = { 1 }
    run("rm -rf build")
    assert.same({ "rm -rf build" }, ran)
    assert.equals(1, #asked)
    assert.is_truthy(asked[1].message:find("Alpha", 1, true))
    assert.is_truthy(asked[1].message:find("rm -rf build", 1, true))
  end)

  it("doesn't run anything when the prompt is cancelled or dismissed", function()
    answers = { 3 }
    run()
    answers = { 0 }
    run()
    assert.same({}, ran)
  end)

  it("asks again after \"Run once\"", function()
    answers = { 1, 1 }
    run("one")
    run("two")
    assert.equals(2, #asked)
    assert.same({ "one", "two" }, ran)
  end)

  it("remembers \"Always trust\" until the tour file changes", function()
    answers = { 2 }
    run("first")
    assert.is_true(trust.is_trusted(state.active.tour))

    run("second")
    assert.equals(1, #asked)
    assert.same({ "first", "second" }, ran)

    local file = assert(io.open(tour_path(), "ab"))
    file:write("\n")
    file:close()
    assert.is_false(trust.is_trusted(state.active.tour))
    answers = { 3 }
    run("third")
    assert.equals(2, #asked)
    assert.same({ "first", "second" }, ran)
  end)

  it("can forget a trusted tour", function()
    answers = { 2 }
    run()
    trust.revoke(state.active.tour)
    assert.is_false(trust.is_trusted(state.active.tour))
  end)

  it("also asks before running :make", function()
    commands.builtin["workbench.action.tasks.build"] = function()
      table.insert(ran, "make")
    end
    answers = { 3 }
    commands.execute("workbench.action.tasks.build", {})
    assert.same({}, ran)
    assert.is_truthy(asked[1].message:find("makeprg", 1, true))
  end)

  it("never remembers tours that aren't a local file", function()
    state.active.tour.id = "https://example.com/a.tour"
    answers = { 1, 1 }
    run()
    run()
    assert.equals(2, #asked)
    assert.equals("&Run once\n&Cancel", asked[1].choices)
    assert.is_false(trust.is_trusted(state.active.tour))
  end)

  it("doesn't ask for navigation commands", function()
    commands.execute("codetour.nextTourStep", {})
    assert.equals(0, #asked)
  end)

  it("runs everything with trust = \"always\" and nothing with \"never\"", function()
    require("codetour.config").setup({ trust = "always" })
    run("a")
    assert.same({ "a" }, ran)
    assert.equals(0, #asked)

    require("codetour.config").setup({ trust = "never" })
    run("b")
    assert.same({ "a" }, ran)
    assert.equals(0, #asked)
    assert.is_true(helpers.has_notification("trust = \"never\""))
  end)

  it("doesn't check commands mapped in the config", function()
    require("codetour.config").setup({
      commands = {
        ["codetour.sendTextToTerminal"] = function(text)
          table.insert(ran, "mine:" .. text)
        end,
      },
    })
    run("x")
    assert.same({ "mine:x" }, ran)
    assert.equals(0, #asked)
  end)

  it("treats an unknown trust value like \"prompt\"", function()
    require("codetour.config").setup({ trust = "yes please" })
    answers = { 3 }
    run()
    assert.equals(1, #asked)
    assert.same({}, ran)
  end)
end)
