local helpers = require("tests.helpers")

local function tour(title, extra)
  return helpers.tour(vim.tbl_extend("force", { title = title, steps = { { description = "d" } } }, extra or {}))
end

describe("codetour.discovery", function()
  before_each(helpers.reset)

  local function titles(state)
    return vim.tbl_map(function(t)
      return t.title
    end, state.tours)
  end

  it("finds tours in every well-known location", function()
    helpers.workspace({
      [".tours/a.tour"] = tour("A"),
      [".tours/nested/deeper/b.tour"] = tour("B"),
      [".vscode/tours/c.tour"] = tour("C"),
      [".github/tours/d.tour"] = tour("D"),
      [".tour"] = tour("E"),
      ["main.tour"] = tour("F"),
      [".vscode/main.tour"] = tour("G"),
      ["other/h.tour"] = tour("H"),
    })
    local state = helpers.setup()
    assert.same({ "A", "B", "C", "D", "E", "F", "G" }, titles(state))
  end)

  it("uses absolute paths as tour ids", function()
    local root = helpers.workspace({ [".tours/a.tour"] = tour("A") })
    local state = helpers.setup()
    assert.equals(root .. "/.tours/a.tour", state.tours[1].id)
  end)

  it("skips files that aren't tours", function()
    helpers.workspace({
      [".tours/ok.tour"] = tour("Ok"),
      [".tours/broken.tour"] = "{ not json",
      [".tours/README.md"] = "# Tours",
      [".tours/data.json"] = '{"name": "not a tour"}',
    })
    assert.same({ "Ok" }, titles(helpers.setup()))
  end)

  it("sorts tours by title like VS Code (ignoring case, symbols first)", function()
    helpers.workspace({
      [".tours/1.tour"] = tour("beta"),
      [".tours/2.tour"] = tour("Alpha"),
      [".tours/3.tour"] = tour("Gamma"),
      [".tours/4.tour"] = tour("🏃 Getting Started"),
      [".tours/5.tour"] = tour("2 - Two"),
    })
    assert.same({ "🏃 Getting Started", "2 - Two", "Alpha", "beta", "Gamma" }, titles(helpers.setup()))
  end)

  it("filters tours with a `when` clause", function()
    helpers.workspace({
      [".tours/1.tour"] = tour("Neovim", { when = "isNeovim" }),
      [".tours/2.tour"] = tour("Hidden", { when = "isWeb" }),
      [".tours/3.tour"] = tour("Invalid", { when = "isLinux &&" }),
      [".tours/4.tour"] = tour("Always"),
    })
    assert.same({ "Always", "Neovim" }, titles(helpers.setup()))
    assert.is_true(helpers.has_notification("Unable to evaluate the `when` clause"))
  end)

  it("discovers tours in a custom directory", function()
    helpers.workspace({ ["docs/tours/a.tour"] = tour("Custom") })
    assert.same({ "Custom" }, titles(helpers.setup({ custom_tour_directory = "docs/tours" })))
  end)

  it("reads codetour settings from .vscode/settings.json", function()
    helpers.workspace({
      ["docs/tours/a.tour"] = tour("Custom"),
      ["alt/b.tour"] = tour("Alt"),
      [".vscode/settings.json"] = '{\n  // comments are allowed\n  "codetour.customTourDirectory": "docs/tours",\n}',
    })
    assert.same({ "Custom" }, titles(helpers.setup()))
    -- Options passed to setup() win over workspace settings.
    assert.same({ "Alt" }, titles(helpers.setup({ custom_tour_directory = "alt" })))
    -- Workspace settings can be ignored altogether.
    assert.same({}, titles(helpers.setup({ vscode_settings = false })))
  end)

  it("discovers tours in every workspace root", function()
    local a = helpers.workspace({ [".tours/a.tour"] = tour("A") })
    local b = helpers.workspace({ [".tours/b.tour"] = tour("B") })
    local state = helpers.setup({ roots = { a, b } })
    assert.same({ "A", "B" }, titles(state))
    assert.equals(b, require("codetour.util").tour_root(state.tours[2]))
  end)

  it("resolves the titles of step markers", function()
    helpers.workspace({
      ["src/app.js"] = "// intro\n// CT1.1 - Setting things up\nfoo()\n// CT1.2: The loop\n",
      [".tours/a.tour"] = helpers.tour({
        title = "1 - Numbered",
        steps = { { file = "src/app.js", description = "" }, { file = "src/app.js", description = "" } },
      }),
      [".tours/b.tour"] = helpers.tour({
        title = "Custom marker",
        stepMarker = "TOUR",
        steps = { { file = "src/b.js", description = "" } },
      }),
      ["src/b.js"] = "x // TOUR.1 - Custom\n",
    })
    local state = helpers.setup()
    -- Tours are sorted by title: "1 - Numbered" comes first.
    assert.equals("Setting things up", state.tours[1].steps[1].markerTitle)
    assert.equals("The loop", state.tours[1].steps[2].markerTitle)
    assert.equals("Custom", state.tours[2].steps[1].markerTitle)
    assert.equals("#1 - Setting things up", require("codetour.util").step_label(state.tours[1], 0))
  end)

  it("updates the active tour when its file changes and ends it when deleted", function()
    local root = helpers.workspace({ [".tours/a.tour"] = tour("A") })
    local state = helpers.setup()
    require("codetour.actions").start_tour(state.tours[1])

    helpers.write(root .. "/.tours/a.tour", tour("A renamed"))
    require("codetour.discovery").discover()
    assert.equals("A renamed", state.active.tour.title)

    local ended = false
    vim.api.nvim_create_autocmd("User", {
      pattern = "CodeTourEnded",
      once = true,
      callback = function()
        ended = true
      end,
    })
    os.remove(root .. "/.tours/a.tour")
    require("codetour.discovery").discover()
    assert.is_nil(state.active)
    assert.is_true(ended)
  end)

  it("doesn't move the user's view when re-discovering", function()
    local root = helpers.workspace({
      ["src/a.js"] = "a\nb\n",
      [".tours/a.tour"] = helpers.tour({ title = "A", steps = { { file = "src/a.js", line = 2, description = "" } } }),
    })
    local state = helpers.setup({ player = { focus = false } })
    require("codetour.actions").start_tour(state.tours[1])
    vim.cmd.edit(root .. "/notes.txt")
    require("codetour.discovery").discover()
    assert.equals(root .. "/notes.txt", vim.api.nvim_buf_get_name(0))
  end)

  it("leaves the step window alone when the active tour didn't change", function()
    helpers.workspace({ [".tours/a.tour"] = tour("A") })
    local state = helpers.setup()
    require("codetour.actions").start_tour(state.tours[1])
    local float = require("codetour.player").view().float
    require("codetour.discovery").discover()
    assert.equals(float, require("codetour.player").view().float)
  end)

  it("re-discovers tours when a tour file is written from Neovim", function()
    local root = helpers.workspace({ [".tours/a.tour"] = tour("A") })
    local state = helpers.setup()
    vim.cmd.edit(root .. "/.tours/b.tour")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { tour("B") })
    vim.cmd("silent write")
    assert.same({ "A", "B" }, titles(state))
  end)
end)
