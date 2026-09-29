local helpers = require("tests.helpers")

describe("codetour.tree", function()
  local root, state, tree, ui

  before_each(function()
    helpers.reset()
    root = helpers.workspace({
      ["src/a.js"] = "a\nb\nc\n",
      [".tours/a.tour"] = helpers.tour({
        title = "Alpha",
        isPrimary = true,
        description = "About alpha",
        steps = {
          { title = "Intro", description = "Hello" },
          { file = "src/a.js", line = 2, description = "B" },
          { directory = "src", description = "## Sources" },
        },
      }),
      [".tours/b.tour"] = helpers.tour({ title = "Beta", steps = { { description = "only" } } }),
    })
    state = helpers.setup()
    tree = require("codetour.tree")
    ui = helpers.stub_ui()
  end)

  local function lines()
    return helpers.lines(tree.buffer())
  end

  local function row_of(text)
    for i, line in ipairs(lines()) do
      if line:find(text, 1, true) then
        return i
      end
    end
  end

  local function press(keys, text)
    vim.api.nvim_set_current_win(tree.window())
    if text then
      vim.api.nvim_win_set_cursor(0, { assert(row_of(text), text), 0 })
    end
    helpers.feed(keys)
  end

  local function descriptions()
    local ns = vim.api.nvim_get_namespaces().codetour_tree
    local result = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(tree.buffer(), ns, 0, -1, { details = true })) do
      if mark[4].virt_text then
        result[#result + 1] = vim.trim(mark[4].virt_text[1][1])
      end
    end
    return result
  end

  it("lists the tours in a side panel", function()
    local win = tree.open()
    assert.equals(win, tree.window())
    assert.equals("codetour-tree", vim.bo[tree.buffer()].filetype)
    assert.same({ "▸ ○ Alpha", "▸ ○ Beta" }, lines())
    assert.same({ "3 steps (Primary)", "1 step" }, descriptions())
    assert.is_true(vim.wo[win].winfixwidth)
  end)

  it("shows how to get started when there are no tours", function()
    helpers.workspace({})
    helpers.setup()
    tree.open()
    assert.equals("No tours found in this workspace.", lines()[1])
    assert.is_truthy(row_of("+ to record a tour"))
  end)

  it("expands and collapses tours", function()
    tree.open()
    press("<CR>", "Alpha")
    assert.same({ "▾ ○ Alpha", "    ¶ #1 - Intro", "    • #2 - src/a.js", "    ▪ #3 - Sources", "▸ ○ Beta" }, lines())
    press("o", "Alpha")
    assert.same({ "▸ ○ Alpha", "▸ ○ Beta" }, lines())
  end)

  it("starts a tour at the selected step and follows the active step", function()
    helpers.setup({ player = { focus = false } })
    tree.open()
    press("<CR>", "Alpha")
    press("<CR>", "#2 - src/a.js")
    assert.equals("Alpha", state.active.tour.title)
    assert.equals(1, state.active.step)
    assert.equals("▾ ▶ Alpha", lines()[1])
    assert.equals("    ▶ #2 - src/a.js", lines()[3])

    require("codetour.actions").next()
    assert.equals(4, vim.api.nvim_win_get_cursor(tree.window())[1])
    assert.equals("    ✓ #2 - src/a.js", lines()[3])
  end)

  it("marks recording and completed tours", function()
    require("codetour.storage").complete_step(state.tours[2], 0)
    tree.open()
    assert.equals("▸ ✓ Beta", lines()[2])
    helpers.run(function()
      require("codetour.recorder").edit(state.tours[1], 0)
    end)
    vim.cmd("stopinsert")
    assert.equals("▾ ● Alpha", lines()[1])
  end)

  it("starts tours with `s` and ends them with `S`", function()
    tree.open()
    press("s", "Beta")
    assert.equals("Beta", state.active.tour.title)
    press("S")
    assert.is_nil(state.active)
  end)

  it("renames tours and steps", function()
    tree.open()
    ui.inputs = { "Alpha 2" }
    press("r", "Alpha")
    assert.equals("Alpha 2", helpers.read_json(root .. "/.tours/a.tour").title)

    press("<CR>", "Alpha 2")
    ui.inputs = { "Second" }
    press("r", "#2 - src/a.js")
    assert.equals("Second", helpers.read_json(root .. "/.tours/a.tour").steps[2].title)
    assert.is_truthy(row_of("#2 - Second"))
  end)

  it("moves steps up and down", function()
    tree.open()
    press("<CR>", "Alpha")
    press("J", "#1 - Intro")
    local steps = helpers.read_json(root .. "/.tours/a.tour").steps
    assert.equals("B", steps[1].description)
    assert.equals("Hello", steps[2].description)
    assert.equals("    ¶ #2 - Intro", vim.api.nvim_get_current_line())
    press("K")
    assert.equals("Hello", helpers.read_json(root .. "/.tours/a.tour").steps[1].description)
  end)

  it("deletes the selected steps", function()
    tree.open()
    press("<CR>", "Alpha")
    ui.selects = { "Delete 2 Steps" }
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    helpers.feed("Vjd")
    local steps = helpers.read_json(root .. "/.tours/a.tour").steps
    assert.equals(1, #steps)
    assert.equals("## Sources", steps[1].description)
  end)

  it("toggles the primary tour", function()
    tree.open()
    press("p", "Beta")
    assert.is_true(helpers.read_json(root .. "/.tours/b.tour").isPrimary)
    assert.is_nil(helpers.read_json(root .. "/.tours/a.tour").isPrimary)
    assert.same({ "3 steps", "1 step (Primary)" }, descriptions())
  end)

  it("peeks at step descriptions and shows help", function()
    tree.open()
    press("<CR>", "Alpha")
    press("<Tab>", "#3 - Sources")
    local float
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        float = win
      end
    end
    assert.is_not_nil(float)
    assert.equals("## Sources", helpers.lines(vim.api.nvim_win_get_buf(float))[1])
    vim.api.nvim_win_close(float, true)

    press("?")
    local found = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        found = helpers.text(vim.api.nvim_win_get_buf(win)):find("Move the step down", 1, true) ~= nil
      end
    end
    assert.is_true(found)
  end)

  it("moves files opened in the tree window to a code window", function()
    tree.open()
    local win = tree.window()
    vim.cmd.edit(root .. "/src/a.js")
    vim.wait(200, function()
      return vim.api.nvim_win_get_buf(win) == tree.buffer()
    end)
    assert.equals(tree.buffer(), vim.api.nvim_win_get_buf(win))
    assert.equals(root .. "/src/a.js", vim.api.nvim_buf_get_name(0))
    assert.are_not.equal(win, vim.api.nvim_get_current_win())
  end)

  it("closes with `q` and toggles", function()
    tree.open()
    press("q")
    assert.is_nil(tree.window())
    tree.toggle()
    assert.is_not_nil(tree.window())
    tree.toggle()
    assert.is_nil(tree.window())
  end)

  it("updates when tours change", function()
    tree.open()
    helpers.write(root .. "/.tours/c.tour", helpers.tour({ title = "Gamma", steps = {} }))
    press("R")
    assert.equals("▸ ○ Gamma", lines()[3])
  end)
end)
