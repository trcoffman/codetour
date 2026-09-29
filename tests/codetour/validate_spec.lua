local helpers = require("tests.helpers")

local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

describe(":CodeTour validate", function()
  local root

  before_each(function()
    helpers.reset()
    root = helpers.workspace({
      ["src/a.js"] = "one\ntwo\n",
      [".tours/t.tour"] = '{\n  "title": "T",\n  "steps": [\n    {"file": "nope.js", "line": 1, "description": "x"}\n  ]\n}',
    })
  end)

  -- A stand-in for the CLI that records its arguments and prints `output`.
  local function fake_cli(output, code)
    local script = root .. "/fake-cli.sh"
    helpers.write(
      script,
      ('#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/args.txt"\ncat <<\'JSON\'\n%s\nJSON\nexit %d\n'):format(root, output, code or 0)
    )
    return { "sh", script }
  end

  local function validate()
    local done, problems = false, nil
    require("codetour.validate").run(nil, function(result)
      done, problems = true, result
    end)
    assert.is_true(vim.wait(10000, function()
      return done
    end))
    return problems
  end

  it("lists the CLI's problems in the quickfix list", function()
    helpers.setup({
      cli = fake_cli(vim.json.encode({
        errors = 1,
        warnings = 1,
        tours = 1,
        problems = {
          { severity = "error", file = ".tours/t.tour", line = 4, step = 1, message = "step #1: file not found: nope.js" },
          { severity = "warning", file = ".tours/t.tour", line = 1, message = "a warning" },
        },
      })),
    })
    validate()
    assert.same({ "--json", "--root", root, "validate" }, vim.split(vim.trim(helpers.read(root .. "/args.txt")), "\n"))
    local qf = vim.fn.getqflist({ items = 0, title = 0 })
    assert.equals("CodeTour", qf.title)
    assert.equals(2, #qf.items)
    assert.equals("E", qf.items[1].type)
    assert.equals(4, qf.items[1].lnum)
    assert.equals(root .. "/.tours/t.tour", vim.api.nvim_buf_get_name(qf.items[1].bufnr))
    assert.equals("step #1: file not found: nope.js", qf.items[1].text)
  end)

  it("says so when there are no problems", function()
    helpers.setup({ cli = fake_cli('{"errors": 0, "warnings": 0, "tours": 2, "problems": []}') })
    validate()
    assert.is_true(helpers.has_notification("No problems found in 2 tours"))
  end)

  it("reports CLI errors", function()
    helpers.setup({ cli = fake_cli('{"error": "boom"}', 1) })
    assert.is_nil(validate())
    assert.is_true(helpers.has_notification("codetour validate failed: boom"))
  end)

  it("explains how to get the CLI when it's missing", function()
    helpers.setup()
    local command = require("codetour.validate").command
    require("codetour.validate").command = function()
      return nil, "The codetour CLI wasn't found."
    end
    assert.is_nil(validate())
    require("codetour.validate").command = command
    assert.is_true(helpers.has_notification("The codetour CLI wasn't found"))
  end)

  it("works with the real CLI when it's built", function()
    if not (vim.uv.fs_stat(repo .. "/dist/cli.js") and vim.fn.executable("node") == 1) then
      return pending("build the CLI with `npm run build` to run this test")
    end
    helpers.setup({ cli = { "node", repo .. "/dist/cli.js" } })
    local problems = validate()
    assert.equals(1, #problems)
    assert.equals("step #1: file not found: nope.js", problems[1].message)
    assert.equals(4, vim.fn.getqflist()[1].lnum)
  end)
end)
