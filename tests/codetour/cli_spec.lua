local helpers = require("tests.helpers")

describe(":CodeTour", function()
  local root, state

  before_each(function()
    helpers.reset()
    root = helpers.workspace({
      ["src/a.js"] = "a\nb\nc\n",
      [".tours/getting-started.tour"] = helpers.tour({
        title = "Getting Started",
        steps = { { description = "one" }, { description = "two" }, { file = "src/a.js", line = 1, description = "three" } },
      }),
      [".tours/other.tour"] = helpers.tour({ title = "Other", steps = { { description = "x" } } }),
    })
    state = helpers.setup()
  end)

  it("starts tours by name and step", function()
    vim.cmd("CodeTour start getting-started 2")
    assert.equals("Getting Started", state.active.tour.title)
    assert.equals(1, state.active.step)
    vim.cmd("CodeTour next")
    assert.equals(2, state.active.step)
    vim.cmd("CodeTour prev")
    vim.cmd("CodeTour goto 1")
    assert.equals(0, state.active.step)
    vim.cmd("CodeTour end")
    assert.is_nil(state.active)

    vim.cmd("CodeTour start Getting Started")
    assert.equals(0, state.active.step)
  end)

  it("asks which tour to start without a name", function()
    local ui = helpers.stub_ui()
    ui.selects = { "Other" }
    vim.cmd("CodeTour start")
    vim.wait(100, function()
      return state.active ~= nil
    end)
    assert.equals("Other", state.active.tour.title)
  end)

  it("reports unknown subcommands and tours", function()
    vim.cmd("CodeTour nope")
    assert.is_true(helpers.has_notification('Unknown subcommand "nope"'))
    vim.cmd("CodeTour start missing")
    assert.is_true(helpers.has_notification('Unable to find a tour matching "missing"'))
  end)

  it("toggles the tree without arguments", function()
    vim.cmd("CodeTour")
    assert.is_not_nil(require("codetour.tree").window())
    vim.cmd("CodeTour")
    assert.is_nil(require("codetour.tree").window())
  end)

  it("completes subcommands and tour names", function()
    local complete = require("codetour.cli").complete
    assert.same({ "start", "start_at_marker", "stop" }, complete("st", "CodeTour st", 11))
    assert.same({ "getting-started" }, complete("g", "CodeTour start g", 16))
    assert.same({ "getting-started", "other" }, complete("", "CodeTour edit ", 14))
    assert.same({}, complete("", "CodeTour next ", 14))
  end)

  it("passes ranges to add_step", function()
    local ui = helpers.stub_ui()
    ui.selects = { "None" }
    vim.cmd("CodeTour record Ranged")
    vim.wait(100, function()
      return state.recording
    end)
    vim.cmd.edit(root .. "/src/a.js")
    vim.cmd("2,3CodeTour add_step")
    local step = state.active.tour.steps[1]
    assert.same({ line = 2, character = 1 }, step.selection.start)
    assert.same({ line = 3, character = 2 }, step.selection["end"])
  end)

  it("adds a line step for a single line address", function()
    vim.cmd("CodeTour record Counted")
    vim.cmd.edit(root .. "/src/a.js")
    vim.cmd("3CodeTour add_step")
    local step = state.active.tour.steps[1]
    assert.equals(3, step.line)
    assert.is_nil(step.selection)
  end)

  it("resets progress", function()
    local storage = require("codetour.storage")
    storage.complete_step(state.tours[1], 0)
    vim.cmd("CodeTour reset_progress getting-started")
    assert.is_false(storage.has_progress(state.tours[1]))
  end)

  it("toggles markers", function()
    vim.cmd("CodeTour hide_markers")
    assert.is_false(state.show_markers)
    vim.cmd("CodeTour show_markers")
    assert.is_true(state.show_markers)
    vim.cmd("CodeTour toggle_markers")
    assert.is_false(state.show_markers)
  end)

  it("treats tour files as JSON", function()
    assert.equals("json", vim.filetype.match({ filename = "intro.tour" }))
  end)

  it("reports its health", function()
    vim.cmd("checkhealth codetour")
    local text = helpers.text(0)
    assert.matches("codetour.nvim", text)
    assert.matches("2 tour%(s%) found", text)
  end)
end)
