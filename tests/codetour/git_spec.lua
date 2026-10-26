local helpers = require("tests.helpers")

describe("tours pinned to a git ref", function()
  if vim.fn.executable("git") ~= 1 then
    pending("git is not installed")
    return
  end

  local root, state, actions, first, player

  before_each(function()
    helpers.reset()
    root = helpers.workspace({ ["src/a.js"] = "version 1\n" })
    helpers.git(root, "init", "-q", "-b", "main")
    helpers.git(root, "add", ".")
    helpers.git(root, "commit", "-q", "-m", "first")
    first = helpers.git(root, "rev-parse", "HEAD")
    helpers.git(root, "tag", "v1")
    helpers.write(root .. "/src/a.js", "version 2\n")
    helpers.git(root, "commit", "-q", "-am", "second")
    state = helpers.setup()
    actions = require("codetour.actions")
    player = require("codetour.player")
  end)

  local function start(ref)
    local tour = require("codetour.tourfile").parse(
      helpers.tour({ title = "Pinned", ref = ref, steps = { { file = "src/a.js", line = 1, description = "" } } }),
      root .. "/.tours/pinned.tour"
    )
    actions.start_tour(tour)
    return player.view().buf
  end

  it("shows files as of the tour's commit", function()
    local buf = start(first)
    assert.equals(("codetour://%s/src/a.js"):format(first), vim.api.nvim_buf_get_name(buf))
    assert.same({ "version 1" }, helpers.lines(buf))
    assert.is_false(vim.bo[buf].modifiable)
    assert.equals("javascript", vim.bo[buf].filetype)
  end)

  it("shows files as of a tag", function()
    local buf = start("v1")
    assert.same({ "version 1" }, helpers.lines(buf))
  end)

  it("uses the working tree when the ref is checked out", function()
    for _, ref in ipairs({ "main", helpers.git(root, "rev-parse", "HEAD"), "HEAD" }) do
      local buf = start(ref)
      assert.equals(root .. "/src/a.js", vim.api.nvim_buf_get_name(buf), ref)
    end
  end)

  describe("with ref = last-edit", function()
    local tour_path

    local function start_last_edit()
      local tour = require("codetour.tourfile").parse(
        helpers.tour({ title = "Pinned", ref = "last-edit", steps = { { file = "src/a.js", line = 1, description = "" } } }),
        tour_path
      )
      actions.start_tour(tour)
      return player.view().buf
    end

    before_each(function()
      tour_path = root .. "/.tours/pinned.tour"
      helpers.write(
        tour_path,
        helpers.tour({ title = "Pinned", ref = "last-edit", steps = { { file = "src/a.js", line = 1, description = "" } } })
      )
    end)

    local function commit_tour_then_change_code()
      helpers.git(root, "add", ".")
      helpers.git(root, "commit", "-q", "-m", "tour")
      helpers.write(root .. "/src/a.js", "version 3\n")
      helpers.git(root, "commit", "-q", "-am", "third")
    end

    it("shows the working tree until the tour is committed", function()
      local buf = start_last_edit()
      assert.equals(root .. "/src/a.js", vim.api.nvim_buf_get_name(buf))
    end)

    it("shows files as of the commit that last modified the tour", function()
      commit_tour_then_change_code()
      local buf = start_last_edit()
      assert.same({ "version 2" }, helpers.lines(buf))
      assert.is_false(vim.bo[buf].modifiable)
    end)

    it("uses the working tree when the tour has uncommitted changes", function()
      commit_tour_then_change_code()
      helpers.write(tour_path, helpers.read(tour_path) .. "\n")
      local buf = start_last_edit()
      assert.equals(root .. "/src/a.js", vim.api.nvim_buf_get_name(buf))
    end)

    it("uses the working tree when the tour is the latest commit", function()
      helpers.git(root, "add", ".")
      helpers.git(root, "commit", "-q", "-m", "tour")
      local buf = start_last_edit()
      assert.equals(root .. "/src/a.js", vim.api.nvim_buf_get_name(buf))
    end)

    it("follows the tour when history is rewritten", function()
      commit_tour_then_change_code()
      local before = helpers.git(root, "rev-parse", "HEAD~1")
      helpers.git(
        root,
        "rebase",
        "-q",
        "--exec",
        "git -c user.name=Tests -c user.email=tests@example.com -c commit.gpgsign=false commit -q --amend -m rewritten",
        "HEAD~2"
      )
      assert.not_equals(before, helpers.git(root, "rev-parse", "HEAD~1"))
      local buf = start_last_edit()
      assert.same({ "version 2" }, helpers.lines(buf))
    end)

    it("exports the pinned version", function()
      commit_tour_then_change_code()
      local tour = require("codetour.tourfile").parse(helpers.read(tour_path), tour_path)
      local exported = vim.json.decode(require("codetour.tourfile").export(tour))
      assert.equals("version 2\n", exported.steps[1].contents)
    end)

    it("shows the working tree for tours without a file", function()
      local tour = require("codetour.tourfile").parse(
        helpers.tour({ title = "Remote", ref = "last-edit", steps = {} }),
        "https://example.com/pinned.tour"
      )
      assert.is_nil(require("codetour.git").tour_ref(tour))
    end)
  end)

  it("embeds the pinned version when exporting", function()
    local tour = require("codetour.tourfile").parse(
      helpers.tour({ title = "Pinned", ref = first, steps = { { file = "src/a.js", line = 1, description = "" } } }),
      root .. "/.tours/pinned.tour"
    )
    local exported = vim.json.decode(require("codetour.tourfile").export(tour))
    assert.equals("version 1\n", exported.steps[1].contents)
    assert.is_nil(exported.ref)
  end)

  it("offers the branch, commit and tags when recording", function()
    local ui = helpers.stub_ui()
    ui.selects = { "Current commit" }
    helpers.run(function()
      require("codetour.recorder").record("Recorded")
    end)
    assert.same({
      "None — Allow the tour to apply to all versions of this repository",
      "Current branch (main) — Allow the tour to apply to all versions of this branch",
      "Current commit — Keep the tour associated with a specific commit",
      "Last commit that modified the tour — Keep the tour associated with the most recent commit that modified the tour",
      "Tag: v1 — Keep the tour associated with a specific tag",
    }, ui.items[1])
    local saved = helpers.read(root .. "/.tours/recorded.tour")
    assert.equals(helpers.git(root, "rev-parse", "HEAD"), vim.json.decode(saved).ref)
    assert.matches('"steps": %[%],\n  "ref": ', saved)
  end)

  it("changes the ref of a tour", function()
    helpers.write(root .. "/.tours/t.tour", helpers.tour({ title = "T", ref = "v1", steps = {} }))
    require("codetour.discovery").discover()
    local ui = helpers.stub_ui()
    ui.selects = { "None" }
    helpers.run(function()
      require("codetour.recorder").change_ref(state.tours[1])
    end)
    assert.is_nil(helpers.read_json(root .. "/.tours/t.tour").ref)
  end)
end)
