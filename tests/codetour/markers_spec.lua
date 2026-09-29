local helpers = require("tests.helpers")

describe("codetour.markers", function()
  local root, state, markers

  before_each(function()
    helpers.reset()
    root = helpers.workspace({
      ["src/a.js"] = "one\ntwo\nthree\nfour\nfive\n",
      ["src/b.js"] = "other\n",
      [".tours/a.tour"] = helpers.tour({
        title = "Alpha",
        steps = {
          { file = "src/a.js", line = 2, description = "line" },
          { file = "src/a.js", pattern = "^fo+ur$", description = "pattern" },
          {
            file = "src/a.js",
            selection = { start = { line = 5, character = 1 }, ["end"] = { line = 5, character = 3 } },
            description = "selection",
          },
          { file = "src/b.js", line = 1, description = "other file" },
        },
      }),
      [".tours/b.tour"] = helpers.tour({
        title = "Beta",
        steps = { { description = "content" }, { file = "src/a.js", line = 2, description = "shared line" } },
      }),
    })
    state = helpers.setup()
    markers = require("codetour.markers")
  end)

  local function signs(buf)
    local ns = markers.namespace()
    return vim.tbl_map(function(mark)
      return { mark[2], mark[4].sign_text }
    end, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))
  end

  local function open(path)
    vim.cmd.edit(root .. "/" .. path)
    return vim.api.nvim_get_current_buf()
  end

  it("places signs on lines that belong to tour steps", function()
    local buf = open("src/a.js")
    assert.same({ { 1, "◆ " }, { 1, "◆ " }, { 3, "◆ " }, { 4, "◆ " } }, signs(buf))
    assert.same({ { 0, "◆ " } }, signs(open("src/b.js")))
  end)

  it("updates when a tour changes", function()
    local buf = open("src/b.js")
    state.tours[1].steps[4].line = nil
    require("codetour.tourfile").save(state.tours[1])
    assert.same({}, signs(buf))
  end)

  it("can be hidden and shown again", function()
    local buf = open("src/a.js")
    markers.set_enabled(false)
    assert.same({}, signs(buf))
    markers.toggle()
    assert.equals(4, #signs(buf))
  end)

  it("respects the show_markers option and workspace setting", function()
    helpers.setup({ show_markers = false })
    assert.same({}, signs(open("src/a.js")))

    helpers.reset()
    helpers.write(root .. "/.vscode/settings.json", '{ "codetour.showMarkers": false }')
    vim.cmd.cd(root)
    helpers.setup()
    assert.same({}, signs(open("src/a.js")))
  end)

  it("uses the configured sign and optional virtual text", function()
    helpers.setup({ markers = { sign = "T", virtual_text = true } })
    local buf = open("src/b.js")
    local mark = vim.api.nvim_buf_get_extmarks(buf, markers.namespace(), 0, -1, { details = true })[1]
    assert.equals("T ", mark[4].sign_text)
    assert.equals("CodeTour: Alpha (Step #4)", mark[4].virt_text[1][1])
  end)

  it("starts the tour step on the cursor line", function()
    open("src/a.js")
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    helpers.run(function()
      markers.start_at_cursor()
    end)
    assert.equals("Alpha", state.active.tour.title)
    assert.equals(1, state.active.step)
  end)

  it("asks which tour to start when several steps share a line", function()
    open("src/a.js")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local ui = helpers.stub_ui()
    ui.selects = { "CodeTour: Beta" }
    helpers.run(function()
      markers.start_at_cursor()
    end)
    assert.equals("Beta", state.active.tour.title)
    assert.equals(1, state.active.step)
  end)

  it("says so when there is no step on the line", function()
    open("src/a.js")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    helpers.run(function()
      markers.start_at_cursor()
    end)
    assert.is_nil(state.active)
    assert.is_true(helpers.has_notification("no tour step on this line"))
  end)
end)
