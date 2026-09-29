local helpers = require("tests.helpers")

describe("codetour.recorder", function()
  local root, state, actions, recorder, ui

  before_each(function()
    helpers.reset()
    root = helpers.workspace({
      ["src/a.js"] = "const a = 1;\nfunction run() {\n  return a;\n}\nconst a = 1;\n",
      ["src/b.js"] = "b\n",
    })
    state = helpers.setup()
    actions = require("codetour.actions")
    recorder = require("codetour.recorder")
    ui = helpers.stub_ui()
  end)

  local function editor()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf) == "codetour://edit" then
        return buf
      end
    end
  end

  local function save_editor(text)
    local buf = assert(editor(), "the step editor isn't open")
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
  end

  local function record(title)
    local tour
    helpers.run(function()
      tour = recorder.record(title)
    end)
    return tour
  end

  local function open(path, line)
    -- Like a user would, go back to a code window first.
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(win).relative == "" then
        vim.api.nvim_set_current_win(win)
        break
      end
    end
    vim.cmd.edit(root .. "/" .. path)
    vim.api.nvim_win_set_cursor(0, { line or 1, 0 })
  end

  local function tour_file(name)
    return helpers.read(root .. "/.tours/" .. name .. ".tour")
  end

  it("creates the tour file and starts recording", function()
    record("My First Tour!")
    assert.equals(
      '{\n  "$schema": "https://aka.ms/codetour-schema",\n  "title": "My First Tour!",\n  "steps": []\n}',
      tour_file("my-first-tour")
    )
    assert.is_true(state.recording)
    assert.equals("My First Tour!", state.active.tour.title)
    assert.equals(-1, state.active.step)
    assert.equals(1, #state.tours)
  end)

  it("asks for the title and handles existing tours", function()
    record("Dup")
    actions.end_tour()
    ui.inputs = { "Dup", "Other" }
    ui.selects = { "Re-enter title" }
    record()
    assert.is_not_nil(tour_file("other"))
    assert.equals("Dup", ui.last_input.default)

    actions.end_tour()
    ui.selects = { "Overwrite existing tour" }
    record("Dup")
    assert.equals("Dup", state.active.tour.title)
  end)

  it("uses the custom tour directory for new tours", function()
    helpers.setup({ custom_tour_directory = "docs/tours" })
    record("Custom")
    assert.is_not_nil(helpers.read(root .. "/docs/tours/custom.tour"))
  end)

  it("asks which root to save to in multi-root workspaces", function()
    local other = helpers.workspace({})
    helpers.setup({ roots = { root, other } })
    ui = helpers.stub_ui()
    ui.selects = { 2 }
    record("Second")
    assert.is_not_nil(helpers.read(other .. "/.tours/second.tour"))
  end)

  it("adds line steps once their description is saved", function()
    record("Steps")
    open("src/a.js", 3)
    recorder.add_step()
    assert.equals(0, state.active.step)
    assert.is_true(state.editing)
    -- Nothing is written until the description is saved.
    assert.matches('"steps": %[%]', tour_file("steps"))

    save_editor("Returns **a**")
    assert.is_false(state.editing)
    assert.equals(
      table.concat({
        "{",
        '  "$schema": "https://aka.ms/codetour-schema",',
        '  "title": "Steps",',
        '  "steps": [',
        "    {",
        '      "file": "src/a.js",',
        '      "description": "Returns **a**",',
        '      "line": 3',
        "    }",
        "  ]",
        "}",
      }, "\n"),
      tour_file("steps")
    )
    assert.is_true(require("codetour.player").is_visible())
  end)

  it("inserts new steps after the current step", function()
    record("Order")
    open("src/a.js", 1)
    recorder.add_step()
    save_editor("first")
    open("src/a.js", 2)
    recorder.add_step()
    save_editor("second")
    actions.goto_step(1)
    recorder.edit()
    recorder.preview()
    open("src/b.js", 1)
    recorder.add_step()
    save_editor("between")
    local tour = helpers.read_json(root .. "/.tours/order.tour")
    assert.same({ "first", "between", "second" }, vim.tbl_map(function(s)
      return s.description
    end, tour.steps))
  end)

  it("discards a new step when the editor is closed without saving", function()
    record("Cancel")
    open("src/a.js", 1)
    recorder.add_step()
    vim.cmd("stopinsert")
    vim.api.nvim_win_close(require("codetour.player").view().float, true)
    vim.wait(100, function()
      return not state.editing
    end)
    assert.same({}, state.active.tour.steps)
    assert.equals(-1, state.active.step)
  end)

  it("anchors steps by pattern in pattern mode when the line is unique", function()
    helpers.setup({ record_mode = "pattern" })
    record("Pattern")
    open("src/a.js", 2)
    recorder.add_step()
    save_editor("run")
    open("src/a.js", 1)
    recorder.add_step()
    save_editor("duplicate line")
    local steps = helpers.read_json(root .. "/.tours/pattern.tour").steps
    assert.equals("^[^\\S\\n]*function run\\(\\) \\{", steps[1].pattern)
    assert.is_nil(steps[1].line)
    assert.equals(1, steps[2].line)
    assert.is_nil(steps[2].pattern)
  end)

  it("adds selection steps with VS Code (UTF-16, 1-based) positions", function()
    helpers.write(root .. "/src/u.js", "x😀yz\nabc\n")
    record("Selection")
    open("src/u.js", 1)
    -- Select from "y" (after the emoji) to "b" in characterwise visual mode.
    vim.cmd("normal! v\27")
    vim.fn.setpos("'<", { 0, 1, 6, 0 })
    vim.fn.setpos("'>", { 0, 2, 2, 0 })
    recorder.add_step({ range = 2, line1 = 1, line2 = 2 })
    save_editor("sel")
    local step = helpers.read_json(root .. "/.tours/selection.tour").steps[1]
    assert.same({ start = { line = 1, character = 4 }, ["end"] = { line = 2, character = 3 } }, step.selection)
    assert.is_nil(step.line)
    assert.equals(
      '    {\n      "file": "src/u.js",\n      "selection": {\n        "start": {\n          "line": 1,',
      helpers.read(root .. "/.tours/selection.tour"):match("    {\n.-\"line\": 1,")
    )
  end)

  it("selects whole lines for linewise and explicit ranges", function()
    record("Lines")
    open("src/a.js", 1)
    recorder.add_step({ range = 2, line1 = 2, line2 = 4 })
    save_editor("function")
    local step = helpers.read_json(root .. "/.tours/lines.tour").steps[1]
    assert.same({ start = { line = 2, character = 1 }, ["end"] = { line = 4, character = 2 } }, step.selection)
  end)

  it("adds content steps", function()
    record("Content")
    ui.inputs = { "Introduction" }
    helpers.run(function()
      recorder.add_content_step()
    end)
    assert.equals("Introduction", ui.last_input.default)
    save_editor("Welcome!")
    local step = helpers.read_json(root .. "/.tours/content.tour").steps[1]
    assert.same({ title = "Introduction", description = "Welcome!" }, step)
    assert.matches('"title": "Introduction",\n      "description"', tour_file("content"))
  end)

  it("adds directory steps", function()
    record("Dirs")
    helpers.run(function()
      recorder.add_directory_step("src")
    end)
    save_editor("Sources")
    assert.same({ directory = "src", description = "Sources" }, helpers.read_json(root .. "/.tours/dirs.tour").steps[1])
  end)

  it("refuses to add steps when not recording", function()
    helpers.write(root .. "/.tours/t.tour", helpers.tour({ title = "T", steps = { { description = "x" } } }))
    require("codetour.discovery").discover()
    actions.start_tour(state.tours[1])
    open("src/a.js", 1)
    recorder.add_step()
    assert.equals(1, #state.active.tour.steps)
    assert.is_true(helpers.has_notification("aren't recording"))
  end)

  describe("existing tours", function()
    local path

    before_each(function()
      path = root .. "/.tours/edit.tour"
      helpers.write(
        path,
        '{\n  "title": "Edit me",\n  "steps": [\n    {\n      "file": "src/a.js",\n      "description": "one",\n      "line": 1\n    },\n    {\n      "file": "src/a.js",\n      "description": "two",\n      "line": 2\n    },\n    {\n      "file": "src/a.js",\n      "description": "three",\n      "line": 3\n    }\n  ]\n}'
      )
      helpers.write(root .. "/.tours/next.tour", helpers.tour({ title = "Next", nextTour = "Edit me", steps = { { description = "n" } } }))
      require("codetour.discovery").discover()
    end)

    local function tour()
      return require("codetour.discovery").find_by_id(path)
    end

    local function descriptions()
      return vim.tbl_map(function(s)
        return s.description
      end, helpers.read_json(path).steps)
    end

    it("edits a step description", function()
      helpers.run(function()
        recorder.edit(tour(), 1)
      end)
      assert.is_true(state.editing)
      assert.same({ "two" }, helpers.lines(editor()))
      save_editor("TWO\n\nmore")
      assert.same({ "one", "TWO\n\nmore", "three" }, descriptions())
      -- The file keeps its format; `$schema` is added like VS Code does.
      assert.matches('^{\n  "%$schema": "https://aka.ms/codetour%-schema",\n  "title": "Edit me",', helpers.read(path))
    end)

    it("blocks navigation while the description has unsaved changes", function()
      helpers.run(function()
        recorder.edit(tour(), 0)
      end)
      vim.api.nvim_buf_set_lines(editor(), 0, -1, false, { "changed" })
      actions.next()
      assert.equals(0, state.active.step)
      assert.is_true(helpers.has_notification("unsaved changes"))
    end)

    it("switches back to preview", function()
      helpers.run(function()
        recorder.edit(tour(), 0)
      end)
      recorder.preview()
      assert.is_false(state.editing)
      assert.is_true(state.recording)
      assert.equals("preview", require("codetour.player").view().mode)
    end)

    it("moves steps and follows the active step", function()
      actions.start_tour(tour(), 0)
      recorder.move_step(1)
      assert.same({ "two", "one", "three" }, descriptions())
      assert.equals(1, state.active.step)
      recorder.move_step(-1, state.active.tour, 2)
      assert.same({ "two", "three", "one" }, descriptions())
      assert.equals(2, state.active.step)
    end)

    it("deletes steps after confirming", function()
      actions.start_tour(tour(), 2)
      ui.selects = { "Delete 2 Steps" }
      helpers.run(function()
        recorder.delete_steps(state.active.tour, { 0, 1 })
      end)
      assert.same({ "three" }, descriptions())
      assert.equals(0, state.active.step)

      ui.selects = { "Cancel" }
      helpers.run(function()
        recorder.delete_steps()
      end)
      assert.same({ "three" }, descriptions())
    end)

    it("changes step titles, icons and lines", function()
      actions.start_tour(tour(), 0)
      ui.inputs = { "Setup", "🚀", "5" }
      helpers.run(function()
        recorder.change_step_title()
        recorder.change_step_icon()
        recorder.change_step_line()
      end)
      local step = helpers.read_json(path).steps[1]
      assert.same({ file = "src/a.js", description = "one", line = 5, title = "Setup", icon = "🚀" }, step)

      ui.inputs = { "", "" }
      helpers.run(function()
        recorder.change_step_title()
        recorder.change_step_line()
      end)
      step = helpers.read_json(path).steps[1]
      assert.is_nil(step.title)
      assert.is_nil(step.line)
    end)

    it("changes and clears the step selection", function()
      actions.start_tour(tour(), 0)
      open("src/a.js", 1)
      recorder.change_step_selection({ range = 2, line1 = 2, line2 = 3 })
      assert.same({ start = { line = 2, character = 1 }, ["end"] = { line = 3, character = 12 } }, helpers.read_json(path).steps[1].selection)
      recorder.change_step_selection({ range = 0 })
      assert.is_nil(helpers.read_json(path).steps[1].selection)
    end)

    it("reloads buffers showing the tour file", function()
      vim.cmd.edit(path)
      local buf = vim.api.nvim_get_current_buf()
      vim.cmd.enew()
      ui.inputs = { "Reloaded" }
      helpers.run(function()
        recorder.change_title(tour())
      end)
      assert.matches('"title": "Reloaded"', helpers.text(buf))
    end)

    it("renames tours and updates references to them", function()
      ui.inputs = { "Edited" }
      helpers.run(function()
        recorder.change_title(tour())
      end)
      assert.equals("Edited", helpers.read_json(path).title)
      assert.equals("Edited", helpers.read_json(root .. "/.tours/next.tour").nextTour)
    end)

    it("changes the description", function()
      ui.inputs = { "About this tour" }
      helpers.run(function()
        recorder.change_description(tour())
      end)
      assert.equals("About this tour", helpers.read_json(path).description)
      assert.matches('"description": "About this tour"\n}$', helpers.read(path))
    end)

    it("makes a single tour primary", function()
      recorder.make_primary(tour())
      assert.is_true(helpers.read_json(path).isPrimary)
      local other = require("codetour.discovery").find_by_id(root .. "/.tours/next.tour")
      recorder.make_primary(other)
      assert.is_nil(helpers.read_json(path).isPrimary)
      assert.is_true(helpers.read_json(root .. "/.tours/next.tour").isPrimary)
      recorder.unmake_primary(other)
      assert.is_nil(helpers.read_json(root .. "/.tours/next.tour").isPrimary)
    end)

    it("deletes tours after confirming", function()
      actions.start_tour(tour(), 0)
      ui.selects = { "Delete Tour" }
      helpers.run(function()
        recorder.delete_tours({ tour() })
      end)
      assert.is_nil(helpers.read(path))
      assert.is_nil(state.active)
      assert.equals(1, #state.tours)
    end)

    it("exports tours with the file contents embedded", function()
      local out = root .. "/exported.tour"
      helpers.run(function()
        recorder.export_tour(tour(), out)
      end)
      local exported = helpers.read_json(out)
      assert.equals(helpers.read(root .. "/src/a.js"), exported.steps[1].contents)
      assert.is_nil(exported.id)
      assert.matches('"line": 1,\n      "contents": ', helpers.read(out))
    end)

    it("doesn't edit read-only tours", function()
      actions.start_tour(tour(), 0, { can_edit = false })
      helpers.run(function()
        recorder.edit()
      end)
      assert.is_false(state.recording)
      assert.is_true(helpers.has_notification("can't be edited"))
    end)
  end)

  it("offers to export tours saved outside the workspace when recording ends", function()
    local out = root .. "/share/mine.tour"
    record(out)
    assert.equals("mine", state.active.tour.title)
    open("src/b.js", 1)
    recorder.add_step()
    save_editor("b")
    ui.selects = { "Export Tour" }
    actions.end_tour()
    vim.wait(500, function()
      return (helpers.read(out) or ""):find('"contents"') ~= nil
    end)
    assert.equals("b\n", helpers.read_json(out).steps[1].contents)
  end)

  describe("completion", function()
    it("completes well-known commands after `command:`", function()
      local completion = require("codetour.completion")
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "[Run](command:codetour.se" })
      vim.api.nvim_win_set_cursor(0, { 1, 25 })
      assert.equals(14, completion.omnifunc(1, ""))
      local words = vim.tbl_map(function(item)
        return item.word
      end, completion.omnifunc(0, "codetour.se"))
      assert.same({ 'codetour.sendTextToTerminal?["shellCommand"]' }, words)
      assert.equals(7, #completion.omnifunc(0, ""))
    end)
  end)
end)
