local helpers = require("tests.helpers")

describe("codetour.player", function()
  local root, state, actions, player

  before_each(function()
    helpers.reset()
    root = helpers.workspace({
      ["src/app.js"] = helpers.lines_of(80) .. "function main() {}\n" .. helpers.lines_of(20, "tail %d"),
      ["src/unicode.js"] = "const s = 'é😀x';\n",
      ["src/lib/util.js"] = "",
      [".tours/tour.tour"] = helpers.tour({
        title = "1 - Basics",
        steps = {
          { title = "Welcome", description = "## Hello\n\nIntro [#3]" },
          { file = "src/app.js", line = 30, description = "Line step" },
          { file = "src/app.js", pattern = "^function main", description = "Pattern step" },
          { file = "src/app.js", description = "End of file" },
          {
            file = "src/unicode.js",
            selection = { start = { line = 1, character = 12 }, ["end"] = { line = 1, character = 15 } },
            description = "Selection",
          },
          { directory = "src", description = "Directory step" },
        },
      }),
      [".tours/next.tour"] = helpers.tour({ title = "2 - Next", steps = { { description = "Second tour" } } }),
    })
    state = helpers.setup()
    actions = require("codetour.actions")
    player = require("codetour.player")
  end)

  local function view()
    return player.view()
  end

  local function float_text()
    return helpers.text(view().float_buf)
  end

  local function float_config()
    return vim.api.nvim_win_get_config(view().float)
  end

  it("shows content steps as a markdown page in the code window", function()
    vim.cmd.edit(root .. "/src/app.js")
    local code_win = vim.api.nvim_get_current_win()
    vim.wo[code_win].number = true
    actions.start_tour(state.tours[1], 0)
    local v = view()
    assert.is_nil(v.float)
    assert.equals(code_win, v.win)
    assert.equals(code_win, vim.api.nvim_get_current_win())
    assert.equals("codetour://CodeTour", vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code_win)))
    assert.matches("^## Hello\n\nIntro %[#3%]%(codetour:1%)", helpers.text(v.buf))
    assert.equals("markdown", vim.bo[v.buf].filetype)
    assert.is_true(player.is_visible())
    assert.matches("^%%#CodeTourTitle# Step #1 of 6 %(Basics%) %%%*%%=.* n next ", vim.wo[code_win].winbar)
    assert.is_false(vim.wo[code_win].number)

    -- The page's window options don't carry over to the code.
    actions.next()
    assert.equals(root .. "/src/app.js", vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code_win)))
    assert.is_true(vim.wo[code_win].number)
    assert.equals("", vim.wo[code_win].winbar)
    assert.is_not_nil(view().float)
  end)

  it("goes back to the previous buffer when the page is hidden", function()
    vim.cmd.edit(root .. "/src/app.js")
    local code_win = vim.api.nvim_get_current_win()
    actions.start_tour(state.tours[1], 0)
    helpers.feed("q")
    assert.equals(root .. "/src/app.js", vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code_win)))
    assert.is_false(player.is_visible())
    assert.is_not_nil(state.active)
  end)

  it("opens file steps at their line and reserves space for the step window", function()
    actions.start_tour(state.tours[1], 1)
    local v = view()
    assert.equals(root .. "/src/app.js", vim.api.nvim_buf_get_name(v.buf))
    assert.equals(29, v.line)
    assert.same({ 30, 0 }, vim.api.nvim_win_get_cursor(v.win))

    local ns = vim.api.nvim_get_namespaces().codetour_player
    local marks = vim.api.nvim_buf_get_extmarks(v.buf, ns, 0, -1, { details = true })
    local virt_lines = marks[1][4].virt_lines
    assert.equals(29, marks[1][2])
    assert.equals(vim.api.nvim_win_get_height(v.float) + 2, #virt_lines)
  end)

  it("only reserves space in the window showing the step", function()
    if not vim.api.nvim__ns_set then
      return
    end
    actions.start_tour(state.tours[1], 1)
    local v = view()
    vim.api.nvim_set_current_win(v.win)
    vim.cmd("vsplit")
    local other = vim.api.nvim_get_current_win()
    assert.equals(v.buf, vim.api.nvim_win_get_buf(other))
    local function fill(win)
      return vim.api.nvim_win_text_height(win, {}).fill
    end
    assert.is_true(fill(v.win) > 0)
    assert.equals(0, fill(other))
  end)

  it("scrolls so the step line and its window are both visible", function()
    helpers.setup({ player = { max_height = 30 } })
    local long = {}
    for i = 1, 25 do
      long[i] = "line " .. i
    end
    local t = require("codetour.tourfile").parse(
      helpers.tour({ title = "Tall", steps = { { file = "src/app.js", line = 60, description = table.concat(long, "\n") } } }),
      root .. "/.tours/tall.tour"
    )
    actions.start_tour(t)
    local v = view()
    local top, bottom = vim.fn.line("w0", v.win), vim.api.nvim_win_get_height(v.win)
    local float_rows = vim.api.nvim_win_get_height(v.float) + 2
    -- Rows from the top of the window to the end of the step window.
    local used = vim.api.nvim_win_text_height(v.win, { start_row = top - 1, end_row = v.line }).all + float_rows
    assert.is_true(used <= bottom, ("step window ends at row %d of %d"):format(used, bottom))
  end)

  it("locates steps by pattern and puts steps without a line at the end", function()
    actions.start_tour(state.tours[1], 2)
    assert.equals(80, view().line)
    actions.next()
    assert.equals(vim.api.nvim_buf_line_count(view().buf) - 1, view().line)
  end)

  it("highlights the step's selection using UTF-16 columns", function()
    actions.start_tour(state.tours[1], 4)
    local v = view()
    local ns = vim.api.nvim_get_namespaces().codetour_player
    local marks = vim.api.nvim_buf_get_extmarks(v.buf, ns, 0, -1, { details = true })
    local selection
    for _, mark in ipairs(marks) do
      if mark[4].hl_group == "CodeTourSelection" then
        selection = mark
      end
    end
    assert.is_not_nil(selection)
    -- Characters 12-15 (1-based, UTF-16) are "é😀" which span bytes 11-17.
    assert.same({ 0, 11, 0, 17 }, { selection[2], selection[3], selection[4].end_row, selection[4].end_col })
    assert.same({ 1, 11 }, vim.api.nvim_win_get_cursor(v.win))
  end)

  it("lists the directory of directory steps", function()
    local revealed
    require("codetour.config").get().on_directory_step = function(path)
      revealed = path
    end
    actions.start_tour(state.tours[1], 5)
    assert.equals("codetour://src", vim.api.nvim_buf_get_name(view().buf))
    assert.same({ "src/", "src/lib/", "src/app.js", "src/unicode.js" }, helpers.lines(view().buf))
    assert.equals(0, view().line)
    assert.equals(root .. "/src", revealed)
  end)

  it("adds navigation links like the VS Code comment thread", function()
    actions.start_tour(state.tours[1], 0)
    -- Steps without a title or heading get a plain "Next"/"Previous" label.
    assert.matches("\n%-%-%-\n%[Next%]%(codetour:%d%) →$", float_text())

    actions.goto_step(2)
    assert.matches("← %[Previous %(Welcome%)%]%(codetour:%d%) | %[Next%]%(codetour:%d%) →$", float_text())

    actions.goto_step(6)
    assert.matches("← %[Previous%]%(codetour:%d%) | %[Next Tour %(Next%)%]%(codetour:%d%)$", float_text())

    actions.start_tour(state.tours[2], 0)
    assert.matches("← %[Previous Tour %(Basics%)%]%(codetour:%d%) | %[Finish Tour%]%(codetour:%d%)$", float_text())
  end)

  it("activates links with <CR> and cycles through them with <Tab>", function()
    actions.start_tour(state.tours[1], 0)
    player.focus()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    helpers.feed("<Tab>")
    assert.same({ 3, 6 }, vim.api.nvim_win_get_cursor(0))
    helpers.feed("<CR>")
    assert.equals(2, state.active.step)
  end)

  it("navigates with the step window's keymaps", function()
    actions.start_tour(state.tours[1], 0)
    assert.equals(view().win, vim.api.nvim_get_current_win())
    helpers.feed("n")
    assert.equals(1, state.active.step)
    assert.equals(view().float, vim.api.nvim_get_current_win())
    helpers.feed("p")
    assert.equals(0, state.active.step)
    assert.equals(view().win, vim.api.nvim_get_current_win())
    helpers.feed("q")
    assert.is_false(player.is_visible())
    assert.is_not_nil(state.active)
    actions.resume()
    assert.is_true(player.is_visible())
    helpers.feed("Q")
    assert.is_nil(state.active)
  end)

  it("keeps the cursor line of the step rendered", function()
    actions.start_tour(state.tours[1], 1)
    assert.equals("nc", vim.wo[view().float].concealcursor)
    actions.prev()
    assert.equals("nc", vim.wo[view().win].concealcursor)
    helpers.run(function()
      require("codetour.recorder").edit()
    end)
    vim.cmd("stopinsert")
    -- The step editor shows the raw markdown, over an empty page.
    assert.equals(0, vim.wo[view().float].conceallevel)
    assert.same({ "" }, helpers.lines(view().buf))
    assert.equals("", vim.wo[view().win].winbar)
  end)

  it("opens links with gx and jumps back with <C-o>", function()
    actions.start_tour(state.tours[1], 0)
    actions.next()
    local code_win = view().win
    vim.api.nvim_set_current_win(view().float)
    helpers.feed("<C-o>")
    assert.equals(code_win, vim.api.nvim_get_current_win())
    assert.equals("codetour://CodeTour", vim.api.nvim_buf_get_name(0))

    actions.goto_step(1)
    player.focus()
    vim.api.nvim_win_set_cursor(0, { 3, 7 })
    helpers.feed("gx")
    assert.equals(2, state.active.step)
  end)

  it("moves files opened in the step window (e.g. by a picker) to the code window", function()
    actions.start_tour(state.tours[1], 5)
    local v = view()
    local code_win = v.win
    assert.is_true(vim.b[v.buf].snacks_main)
    local file = vim.fn.bufadd(root .. "/src/unicode.js")
    vim.fn.bufload(file)
    -- What snacks.nvim does when the step window is its target.
    vim.api.nvim_set_current_win(v.float)
    vim.cmd("buffer " .. file)
    vim.api.nvim_win_set_cursor(0, { 1, 3 })
    vim.wait(200, function()
      return vim.api.nvim_get_current_win() == code_win
    end)
    assert.equals(code_win, vim.api.nvim_get_current_win())
    assert.equals(file, vim.api.nvim_win_get_buf(code_win))
    assert.same({ 1, 3 }, vim.api.nvim_win_get_cursor(code_win))
    assert.is_false(player.is_visible())
    assert.is_not_nil(state.active)
  end)

  it("keeps the focus in place when `player.focus` is off", function()
    helpers.setup({ player = { focus = false } })
    local win = vim.api.nvim_get_current_win()
    actions.start_tour(state.tours[1], 1)
    assert.equals(win, vim.api.nvim_get_current_win())
    assert.equals(win, view().win)
  end)

  it("respects player.max_width", function()
    helpers.setup({ player = { max_width = 30 } })
    actions.start_tour(state.tours[1], 1)
    assert.equals(28, float_config().width)
  end)

  it("hides the step window while another buffer is shown", function()
    actions.start_tour(state.tours[1], 1)
    local v = view()
    vim.api.nvim_set_current_win(v.win)
    vim.cmd.enew()
    vim.wait(100, function()
      return float_config().hide
    end)
    assert.is_true(float_config().hide)
    vim.cmd("buffer " .. v.buf)
    vim.wait(100, function()
      return not float_config().hide
    end)
    assert.is_false(float_config().hide)
  end)

  it("hides the step window while its line is scrolled out of view", function()
    actions.start_tour(state.tours[1], 1)
    local v = view()
    vim.api.nvim_set_current_win(v.win)
    vim.api.nvim_win_set_cursor(v.win, { 90, 0 })
    vim.cmd("normal! zt")
    vim.wait(100, function()
      return float_config().hide
    end)
    assert.is_true(float_config().hide)
  end)

  it("shortens the step window instead of covering code when it doesn't fit", function()
    actions.start_tour(state.tours[1], 1)
    local v = view()
    local full = vim.api.nvim_win_get_height(v.float)
    vim.api.nvim_set_current_win(v.win)
    -- Scroll so that only a few rows are left below the step line.
    local height = vim.api.nvim_win_get_height(v.win)
    vim.fn.winrestview({ topline = v.line + 1 - (height - 5) })
    vim.api.nvim_exec_autocmds("WinScrolled", {})
    vim.wait(200, function()
      return vim.api.nvim_win_get_height(v.float) < full
    end)
    assert.equals(2, vim.api.nvim_win_get_height(v.float))
    assert.is_false(vim.api.nvim_win_get_config(v.float).hide)

    -- With room again, the full step window comes back.
    vim.fn.winrestview({ topline = v.line + 1 })
    vim.api.nvim_exec_autocmds("WinScrolled", {})
    vim.wait(200, function()
      return vim.api.nvim_win_get_height(v.float) == full
    end)
    assert.equals(full, vim.api.nvim_win_get_height(v.float))
  end)

  it("runs step commands and focuses views when navigating to a step", function()
    local calls = {}
    helpers.setup({
      commands = {
        ["my.command"] = function(...)
          table.insert(calls, { ... })
        end,
      },
      views = {
        ["my.view"] = function()
          table.insert(calls, "view")
        end,
      },
    })
    local t = require("codetour.tourfile").parse(
      helpers.tour({
        title = "Commands",
        steps = { { description = "x", commands = { 'my.command?["a", 2]', "my.command" }, view = "my.view" } },
      }),
      root .. "/.tours/commands.tour"
    )
    actions.start_tour(t)
    assert.same({ "view", { "a", 2 }, {} }, calls)
  end)

  it("edits embedded file contents and saves them into the tour", function()
    local path = root .. "/exported.tour"
    helpers.write(
      path,
      helpers.tour({
        title = "Exported",
        steps = { { file = "notes.txt", contents = "one\ntwo\n", line = 2, description = "Embedded" } },
      })
    )
    actions.start_tour_by_path(path)
    local buf = view().buf
    assert.equals("codetour://tour/notes.txt", vim.api.nvim_buf_get_name(buf))
    assert.same({ "one", "two" }, helpers.lines(buf))
    assert.equals(1, view().line)

    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "ONE" })
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    assert.equals("ONE\ntwo\n", helpers.read_json(path).steps[1].contents)
    assert.is_false(vim.bo[buf].modified)
  end)

  describe("with long steps", function()
    local long = ("Paragraph.\n\n"):rep(8)

    local function start(steps)
      local t = require("codetour.tourfile").parse(helpers.tour({ title = "Long", steps = steps }), root .. "/.tours/long.tour")
      actions.start_tour(t)
      -- Enter the code window (that makes Neovim apply 'scrolloff') and let
      -- the step window settle.
      vim.api.nvim_set_current_win(view().win)
      vim.wait(200)
      return view()
    end

    for _, so in ipairs({ 0, 10 }) do
      it(("keeps the end of a selection that doesn't fit and its step window on screen (scrolloff=%d)"):format(so), function()
        vim.o.scrolloff = so
        local v = start({
          {
            file = "src/app.js",
            selection = { start = { line = 50, character = 1 }, ["end"] = { line = 101, character = 10 } },
            description = long,
          },
        })
        assert.equals(100, v.line)
        local top, cursor = vim.fn.line("w0"), vim.fn.line(".")
        assert.equals(101, vim.fn.line("w$"))
        assert.is_true(cursor >= top + so and cursor <= 101)
        assert.is_false(float_config().hide)
        assert.is_true(v.height > 1)
        assert.equals(v.height, vim.api.nvim_win_get_height(v.float))
      end)
    end

    it("scrolls the step window out of view with the code", function()
      local v = start({ { file = "src/app.js", line = 60, description = long } })
      local total = v.height + 2
      -- The step's line, the top border and the first two lines of text are
      -- scrolled out of view.
      vim.fn.winrestview({ lnum = 61, topline = 61, topfill = total - 3 })
      player.relayout()
      local cfg = float_config()
      assert.is_false(cfg.hide)
      assert.equals("SW", cfg.anchor)
      assert.same({ 60, 0 }, cfg.bufpos)
      assert.is_nil(cfg.title)
      assert.equals(v.height - 2, cfg.height)
      assert.equals(3, vim.fn.line("w0", v.float))

      -- All of it.
      vim.fn.winrestview({ lnum = 75, topline = 61, topfill = 0 })
      player.relayout()
      assert.is_true(float_config().hide)

      -- Back, with room for all of it.
      vim.fn.winrestview({ lnum = 60, topline = 60, topfill = 0 })
      player.relayout()
      cfg = float_config()
      assert.is_false(cfg.hide)
      assert.equals("NW", cfg.anchor)
      assert.same({ 59, 0 }, cfg.bufpos)
      assert.is_not_nil(cfg.title)
      assert.equals(v.height, cfg.height)
      assert.equals(1, vim.fn.line("w0", v.float))
    end)

    it("leaves 'scrolloff' lines above the step's line", function()
      vim.o.scrolloff = 10
      local v = start({ { file = "src/app.js", line = 60, description = long } })
      assert.equals(60, vim.fn.line("."))
      assert.is_true(60 - vim.fn.line("w0") >= 10)
      assert.is_false(float_config().hide)
      assert.equals(v.height, vim.api.nvim_win_get_height(v.float))
    end)
  end)

  it("opens steps that use a file:// URI", function()
    local t = require("codetour.tourfile").parse(
      helpers.tour({ title = "Uri", steps = { { uri = vim.uri_from_fname(root .. "/src/app.js"), line = 3, description = "" } } }),
      root .. "/.tours/uri.tour"
    )
    actions.start_tour(t)
    assert.equals(root .. "/src/app.js", vim.api.nvim_buf_get_name(view().buf))
    assert.equals(2, view().line)
  end)

  it("closes its windows and scratch buffers when the tour ends", function()
    actions.start_tour(state.tours[1], 1)
    local float = view().float
    actions.end_tour()
    assert.is_false(vim.api.nvim_win_is_valid(float))

    actions.start_tour(state.tours[1], 0)
    local win = view().win
    actions.end_tour()
    assert.is_true(vim.api.nvim_win_is_valid(win))
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      assert.is_not.equals("codetour://CodeTour", vim.api.nvim_buf_get_name(buf))
    end
  end)

  it("lists the step's links", function()
    actions.start_tour(state.tours[1], 0)
    local labels = vim.tbl_map(function(link)
      return link.label
    end, player.links())
    assert.same({ "#3", "Next" }, labels)
  end)
end)
