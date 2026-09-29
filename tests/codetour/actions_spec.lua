local helpers = require("tests.helpers")

local function steps(n)
  local list = {}
  for i = 1, n do
    list[i] = { description = "Step " .. i }
  end
  return list
end

describe("codetour.actions", function()
  local root, state, actions, storage

  before_each(function()
    helpers.reset()
    root = helpers.workspace({
      [".tours/a.tour"] = helpers.tour({ title = "Alpha", description = "The first", steps = steps(3) }),
      [".tours/b.tour"] = helpers.tour({ title = "Beta", steps = steps(2), nextTour = "Alpha" }),
      [".tours/empty.tour"] = helpers.tour({ title = "Empty", steps = {} }),
    })
    state = helpers.setup()
    actions = require("codetour.actions")
    storage = require("codetour.storage")
  end)

  local function find(title)
    for _, tour in ipairs(state.tours) do
      if tour.title == title then
        return tour
      end
    end
  end

  local function events()
    local list = {}
    vim.api.nvim_create_autocmd("User", {
      pattern = { "CodeTourStepChanged", "CodeTourEnded" },
      callback = function(ev)
        table.insert(list, { ev.match, ev.data.tour.title, ev.data.step })
      end,
    })
    return list
  end

  it("starts a tour at a step, clamping out of range steps", function()
    actions.start_tour(find("Alpha"), 1)
    assert.equals(1, state.active.step)
    actions.start_tour(find("Alpha"), 99)
    assert.equals(2, state.active.step)
    actions.start_tour(find("Empty"))
    assert.equals(-1, state.active.step)
  end)

  it("navigates between steps and fires events", function()
    local fired = events()
    actions.start_tour(find("Alpha"))
    actions.next()
    actions.next()
    actions.next()
    actions.prev()
    actions.end_tour()
    assert.same({
      { "CodeTourStepChanged", "Alpha", 0 },
      { "CodeTourStepChanged", "Alpha", 1 },
      { "CodeTourStepChanged", "Alpha", 2 },
      { "CodeTourStepChanged", "Alpha", 1 },
      { "CodeTourEnded", "Alpha" },
    }, fired)
    assert.is_true(helpers.has_notification("This is the last step"))
  end)

  it("records progress when moving forward and finishing", function()
    local tour = find("Alpha")
    actions.start_tour(tour)
    actions.next()
    actions.next()
    assert.is_true(storage.is_complete(tour, 0))
    assert.is_true(storage.is_complete(tour, 1))
    assert.is_false(storage.is_complete(tour))
    actions.finish()
    assert.is_true(storage.is_complete(tour))
    assert.is_nil(state.active)

    local saved = helpers.read_json(require("codetour.config").get().state_file)
    assert.same({ 0, 1, 2 }, saved.progress[tour.id])

    storage.reset(tour)
    assert.is_false(storage.is_complete(tour, 0))
  end)

  it("finishes a tour by starting the next one", function()
    actions.start_tour(find("Beta"), 1)
    actions.finish("Alpha")
    assert.equals("Alpha", state.active.tour.title)
    assert.equals(0, state.active.step)
  end)

  it("navigates to a 1-based step", function()
    actions.start_tour(find("Alpha"))
    actions.goto_step(3)
    assert.equals(2, state.active.step)
    actions.goto_step(9)
    assert.equals(2, state.active.step)
  end)

  it("starts tours by title", function()
    actions.start_by_title("Beta", 2)
    assert.equals("Beta", state.active.tour.title)
    assert.equals(1, state.active.step)
  end)

  it("selects the only tour without asking", function()
    local ui = helpers.stub_ui()
    helpers.run(function()
      actions.select_tour({ find("Beta") })
    end)
    assert.equals("Beta", state.active.tour.title)
    assert.same({}, ui.prompts)
  end)

  it("asks which tour to start when there are several", function()
    local ui = helpers.stub_ui()
    ui.selects = { "Beta" }
    helpers.run(function()
      actions.select_tour()
    end)
    assert.equals("Beta", state.active.tour.title)
    assert.same({ "Alpha — The first", "Beta", "Empty" }, ui.items[1])
  end)

  it("starts the primary tour by default", function()
    local tours = {
      { id = "x", title = "Other", steps = steps(1) },
      { id = "y", title = "Primary", isPrimary = true, steps = steps(1) },
    }
    helpers.run(function()
      actions.start_default_tour(root, tours)
    end)
    assert.equals("Primary", state.active.tour.title)

    tours = { { id = "x", title = "2 - Two", steps = steps(1) }, { id = "y", title = "#1 - One", steps = steps(1) } }
    helpers.run(function()
      actions.start_default_tour(root, tours)
    end)
    assert.equals("#1 - One", state.active.tour.title)
  end)

  it("offers to start a tour once per workspace", function()
    helpers.setup({ prompt_for_workspace_tours = true })
    local ui = helpers.stub_ui()
    ui.selects = { "Start CodeTour" }
    ui.selects[2] = "Alpha"
    helpers.run(function()
      actions.prompt_for_tour()
    end)
    assert.equals("Alpha", state.active.tour.title)
    assert.matches("guided tours", ui.prompts[1])

    actions.end_tour()
    helpers.run(function()
      actions.prompt_for_tour()
    end)
    assert.is_nil(state.active)
    assert.equals(2, #ui.prompts)
  end)

  it("only notifies about the workspace's tours at startup", function()
    helpers.setup({ prompt_for_workspace_tours = true })
    local ui = helpers.stub_ui()
    vim.api.nvim_list_uis = function()
      return { {} }
    end
    require("codetour").on_startup()
    vim.wait(100, function()
      return helpers.has_notification("guided tours")
    end)
    assert.is_true(helpers.has_notification("Run :CodeTour start"))
    assert.same({}, ui.prompts)
    assert.is_nil(state.active)
    assert.is_true(storage.was_prompted(root))
  end)

  it("doesn't prompt when disabled", function()
    local ui = helpers.stub_ui()
    helpers.run(function()
      actions.prompt_for_tour()
    end)
    assert.same({}, ui.prompts)
  end)

  it("finds tours by title or file name", function()
    assert.equals("Alpha", actions.find_tour("Alpha").title)
    assert.equals("Alpha", actions.find_tour("alpha").title)
    assert.equals("Beta", actions.find_tour("b").title)
    assert.equals("Beta", actions.find_tour("b.tour").title)
    assert.equals("Beta", actions.find_tour(".tours/b").title)
    assert.equals("Alpha", actions.find_tour("alp").title)
    -- Ambiguous parts of titles don't match ("e" is in Beta and Empty).
    assert.is_nil(actions.find_tour("e"))
    assert.is_nil(actions.find_tour("zzz"))
  end)

  it("opens tour files", function()
    local path = root .. "/elsewhere/mine.tour"
    helpers.write(path, helpers.tour({ title = "Mine", steps = steps(1) }))
    helpers.run(function()
      actions.open_tour_file(path)
    end)
    assert.equals("Mine", state.active.tour.title)
    assert.equals(path, state.active.tour.id)

    helpers.write(root .. "/bad.tour", "nope")
    helpers.run(function()
      actions.open_tour_file(root .. "/bad.tour")
    end)
    assert.is_true(helpers.has_notification("doesn't appear to be a valid tour"))
  end)

  it("opens tours from a URL as read-only tours", function()
    local path = root .. "/remote.tour"
    helpers.write(path, helpers.tour({ title = "Remote", steps = steps(1) }))
    local url = vim.uri_from_fname(path)
    local ui = helpers.stub_ui()
    ui.inputs = { url }
    helpers.run(function()
      actions.open_tour_url()
    end)
    assert.equals("Remote", state.active.tour.title)
    assert.equals(url, state.active.tour.id)
    assert.is_false(state.active.can_edit)
  end)

  it("describes the active tour for statuslines", function()
    local codetour = require("codetour")
    assert.equals("", codetour.status())
    actions.start_tour(find("Alpha"), 1)
    assert.equals("CodeTour: #2 of 3 (Alpha)", codetour.status())
    state.recording = true
    assert.equals("Recording CodeTour: #2 of 3 (Alpha)", codetour.status())
  end)

  it("resumes the current step", function()
    actions.start_tour(find("Alpha"))
    require("codetour.player").hide()
    actions.resume()
    assert.is_true(require("codetour.player").is_visible())
  end)
end)
