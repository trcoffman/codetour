local helpers = require("tests.helpers")

describe("codetour.util", function()
  local util

  before_each(function()
    helpers.reset()
    util = require("codetour.util")
  end)

  describe("tour titles", function()
    it("strips numeric prefixes like the VS Code extension", function()
      assert.equals("Intro", util.tour_title({ title = "1 - Intro" }))
      assert.equals("Intro", util.tour_title({ title = "#12 - Intro" }))
      -- Matches VS Code, which only keeps the text up to the next dash.
      assert.equals("Tree", util.tour_title({ title = "2 - Tree-View" }))
      assert.equals("1: Intro", util.tour_title({ title = "1: Intro" }))
      assert.equals("Plain", util.tour_title({ title = "Plain" }))
    end)

    it("extracts tour numbers", function()
      assert.equals(3, util.tour_number({ title = "3 - Three" }))
      assert.equals(3, util.tour_number({ title = "#3  - Three" }))
      assert.is_nil(util.tour_number({ title = "Three" }))
    end)
  end)

  describe("step labels", function()
    local tour = {
      title = "T",
      steps = {
        { title = "Explicit", description = "# Heading" },
        { description = "## Heading text\nbody" },
        { markerTitle = "Marker", description = "text", file = "a.js" },
        { file = "src/my%20file.js", description = "text" },
        { directory = "src", description = "text" },
        { uri = "https://example.com/x", description = "" },
      },
    }

    it("prefers the title, then a heading, then the marker title, then the path", function()
      assert.equals("#1 - Explicit", util.step_label(tour, 0))
      assert.equals("#2 - Heading text", util.step_label(tour, 1))
      assert.equals("#3 - Marker", util.step_label(tour, 2))
      assert.equals("#4 - src/my file.js", util.step_label(tour, 3))
      assert.equals("#5 - src", util.step_label(tour, 4))
      assert.equals("#6 - https://example.com/x", util.step_label(tour, 5))
    end)

    it("can omit the step number and the file fallback", function()
      assert.equals("Explicit", util.step_label(tour, 0, false))
      assert.equals("", util.step_label(tour, 3, false, false))
    end)
  end)

  describe("step markers", function()
    it("uses the tour's stepMarker or its number", function()
      assert.equals("MARK", util.step_marker_prefix({ title = "T", stepMarker = "MARK", steps = {} }))
      assert.equals("CT2", util.step_marker_prefix({ title = "2 - T", steps = {} }))
      assert.is_nil(util.step_marker_prefix({ title = "T", steps = {} }))
    end)

    it("only applies to file steps without a line", function()
      local tour = { title = "1 - T", steps = { { file = "a" }, { file = "a", line = 2 }, { description = "" } } }
      assert.equals("CT1.1", util.step_marker(tour, 0))
      assert.is_nil(util.step_marker(tour, 1))
      assert.is_nil(util.step_marker(tour, 2))
    end)
  end)

  describe("paths", function()
    it("normalizes and joins paths", function()
      assert.equals("/a/c", util.normalize("/a/b/../c"))
      assert.equals("/a/b", util.normalize("/a/./b/"))
      assert.equals("/root/src/x.js", util.join("/root", "./src/x.js"))
      assert.equals("/root/x.js", util.join("/root/src", "../x.js"))
      assert.equals("/abs/x.js", util.join("/root", "/abs/x.js"))
    end)

    it("computes relative paths like Node's path.relative", function()
      assert.equals("src/x.js", util.relative("/root", "/root/src/x.js"))
      assert.equals("../other/x.js", util.relative("/root/app", "/root/other/x.js"))
      assert.equals("", util.relative("/root", "/root"))
    end)

    it("detects URLs", function()
      assert.is_true(util.is_url("https://example.com/a.tour"))
      assert.is_false(util.is_url("/tmp/a.tour"))
      assert.is_false(util.is_url("file:///tmp/a.tour"))
    end)
  end)

  describe("workspace roots", function()
    it("defaults to the current directory", function()
      local root = helpers.workspace({})
      assert.same({ root }, util.roots())
    end)

    it("uses the configured roots and assigns tours to the containing root", function()
      require("codetour.config").setup({ roots = { "/ws/a", "/ws/b" } })
      assert.same({ "/ws/a", "/ws/b" }, util.roots())
      assert.equals("/ws/b", util.tour_root({ id = "/ws/b/.tours/x.tour" }))
      assert.equals("/ws/a", util.tour_root({ id = "/elsewhere/x.tour" }))
      assert.equals("/ws/a", util.tour_root({ id = "https://example.com/x.tour" }))
    end)
  end)

  describe("UTF-16 columns", function()
    local line = "aé😀b"

    it("converts byte offsets to UTF-16 offsets", function()
      assert.equals(0, util.byte_to_utf16(line, 0))
      assert.equals(1, util.byte_to_utf16(line, 1))
      assert.equals(2, util.byte_to_utf16(line, 3))
      assert.equals(4, util.byte_to_utf16(line, 7))
      assert.equals(5, util.byte_to_utf16(line, 8))
    end)

    it("converts UTF-16 offsets to byte offsets", function()
      assert.equals(0, util.utf16_to_byte(line, 0))
      assert.equals(1, util.utf16_to_byte(line, 1))
      assert.equals(3, util.utf16_to_byte(line, 2))
      assert.equals(7, util.utf16_to_byte(line, 4))
      assert.equals(8, util.utf16_to_byte(line, 99))
    end)

    it("round-trips selections through VS Code positions", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x😀yz", "abc" })
      local selection = util.make_selection(buf, 0, 5, 1, 2)
      assert.same({ line = 1, character = 4 }, selection.start)
      assert.same({ line = 2, character = 3 }, selection["end"])
      assert.same({ 0, 5, 1, 2 }, { util.selection_range(buf, selection) })
    end)
  end)
end)
