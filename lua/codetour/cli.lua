-- The :CodeTour command.

local M = {}

local function async(fn)
  return function(...)
    local args = { ... }
    require("codetour.async").run(function()
      fn(unpack(args))
    end)
  end
end

local function actions()
  return require("codetour.actions")
end

local function recorder()
  return require("codetour.recorder")
end

local function discovery()
  return require("codetour.discovery")
end

local function joined(args)
  local text = table.concat(args, " ")
  return text ~= "" and text or nil
end

-- Resolves the optional tour argument of a command.
local function tour_arg(args)
  local name = joined(args)
  if not name then
    return nil
  end
  discovery().ensure()
  local tour = actions().find_tour(name)
  if not tour then
    require("codetour.util").warn(("Unable to find a tour matching %q."):format(name))
    return false
  end
  return tour
end

local function with_tour(fn)
  return async(function(args)
    local tour = tour_arg(args)
    if tour ~= false then
      fn(tour or nil)
    end
  end)
end

local function complete_tours()
  discovery().ensure()
  local names = {}
  for _, tour in ipairs(require("codetour.state").tours) do
    names[#names + 1] = vim.fn.fnamemodify(tour.id, ":t:r")
  end
  return names
end

local function complete_files(arg)
  return vim.fn.getcompletion(arg, "file")
end

---@type table<string, { run: fun(args: string[], opts: table), complete?: fun(arg: string): string[], desc: string }>
M.subcommands = {
  start = {
    desc = "Start a tour: [tour] [step]",
    run = async(function(args)
      discovery().ensure()
      local step
      if #args > 0 and tonumber(args[#args]) then
        step = tonumber(table.remove(args)) - 1
      end
      local name = joined(args)
      if not name then
        return actions().select_tour(nil, nil, step)
      end
      local tour = actions().find_tour(name)
      if not tour then
        return require("codetour.util").warn(("Unable to find a tour matching %q."):format(name))
      end
      actions().start_tour(tour, step)
    end),
    complete = complete_tours,
  },
  ["end"] = {
    desc = "End the active tour",
    run = function()
      actions().end_tour()
    end,
  },
  next = {
    desc = "Go to the next step",
    run = function()
      actions().next()
    end,
  },
  prev = {
    desc = "Go to the previous step",
    run = function()
      actions().prev()
    end,
  },
  ["goto"] = {
    desc = "Go to a step: <number>",
    run = function(args)
      actions().goto_step(args[1])
    end,
  },
  resume = {
    desc = "Show the current step again",
    run = function()
      actions().resume()
    end,
  },
  open_file = {
    desc = "Open a tour file: [path]",
    run = async(function(args)
      actions().open_tour_file(joined(args))
    end),
    complete = complete_files,
  },
  open_url = {
    desc = "Open a tour from a URL: [url]",
    run = async(function(args)
      actions().open_tour_url(args[1])
    end),
  },
  tree = {
    desc = "Toggle the tour tree",
    run = function()
      require("codetour.tree").toggle()
    end,
  },
  links = {
    desc = "Pick a link of the current step",
    run = async(function()
      local links = require("codetour.player").links()
      if #links == 0 then
        return require("codetour.util").notify("The current step doesn't have any links.")
      end
      local link = require("codetour.async").select(links, {
        prompt = "Select a link",
        format_item = function(item)
          return item.label
        end,
      })
      if link then
        require("codetour.commands").run_action(link.action)
      end
    end),
  },
  start_at_marker = {
    desc = "Start the tour step on the cursor line",
    run = async(function()
      require("codetour.markers").start_at_cursor()
    end),
  },
  show_markers = {
    desc = "Show tour markers",
    run = function()
      require("codetour.markers").set_enabled(true)
    end,
  },
  hide_markers = {
    desc = "Hide tour markers",
    run = function()
      require("codetour.markers").set_enabled(false)
    end,
  },
  toggle_markers = {
    desc = "Toggle tour markers",
    run = function()
      require("codetour.markers").toggle()
    end,
  },
  reset_progress = {
    desc = "Reset the progress of [tour] or of every tour",
    run = with_tour(function(tour)
      require("codetour.storage").reset(tour)
      require("codetour.state").changed()
    end),
    complete = complete_tours,
  },
  validate = {
    desc = "Check tours for problems with the codetour CLI (listed in the quickfix list)",
    run = function(args)
      require("codetour.validate").run(joined(args))
    end,
    complete = complete_tours,
  },
  refresh = {
    desc = "Re-discover the workspace's tours",
    run = function()
      discovery().discover()
    end,
  },
  record = {
    desc = "Record a new tour: [title | path.tour]",
    run = async(function(args)
      recorder().record(joined(args))
    end),
  },
  add_step = {
    desc = "Add a step for the cursor line or [range]",
    run = function(_, opts)
      recorder().add_step(opts)
    end,
  },
  add_content_step = {
    desc = "Add a content step: [title]",
    run = async(function(args)
      recorder().add_content_step(joined(args))
    end),
  },
  add_directory_step = {
    desc = "Add a directory step: [directory]",
    run = async(function(args)
      recorder().add_directory_step(joined(args))
    end),
    complete = function(arg)
      return vim.fn.getcompletion(arg, "dir")
    end,
  },
  edit = {
    desc = "Edit [tour] (the active tour by default)",
    run = with_tour(function(tour)
      recorder().edit(tour)
    end),
    complete = complete_tours,
  },
  preview = {
    desc = "Stop editing the current step",
    run = function()
      recorder().preview()
    end,
  },
  delete_step = {
    desc = "Delete the current step or step [number]",
    run = async(function(args)
      local number = tonumber(args[1])
      recorder().delete_steps(nil, number and { number - 1 } or nil)
    end),
  },
  move_step_up = {
    desc = "Move the current step up",
    run = function()
      recorder().move_step(-1)
    end,
  },
  move_step_down = {
    desc = "Move the current step down",
    run = function()
      recorder().move_step(1)
    end,
  },
  change_step_title = {
    desc = "Change the current step's title: [title]",
    run = async(function(args)
      recorder().change_step_title(nil, nil, #args > 0 and table.concat(args, " ") or nil)
    end),
  },
  change_step_icon = {
    desc = "Change the current step's icon: [icon]",
    run = async(function(args)
      recorder().change_step_icon(nil, nil, args[1])
    end),
  },
  change_step_line = {
    desc = "Change the current step's line: [line]",
    run = async(function(args)
      recorder().change_step_line(args[1])
    end),
  },
  change_step_selection = {
    desc = "Set the current step's selection to [range] (no range clears it)",
    run = function(_, opts)
      recorder().change_step_selection(opts)
    end,
  },
  change_title = {
    desc = "Change the tour's title: [title]",
    run = async(function(args)
      recorder().change_title(nil, joined(args))
    end),
  },
  change_description = {
    desc = "Change the tour's description: [description]",
    run = async(function(args)
      recorder().change_description(nil, joined(args))
    end),
  },
  change_ref = {
    desc = "Change the git ref of [tour]",
    run = with_tour(function(tour)
      recorder().change_ref(tour)
    end),
    complete = complete_tours,
  },
  make_primary = {
    desc = "Make [tour] the primary tour",
    run = with_tour(function(tour)
      recorder().make_primary(tour)
    end),
    complete = complete_tours,
  },
  unmake_primary = {
    desc = "Stop [tour] from being the primary tour",
    run = with_tour(function(tour)
      recorder().unmake_primary(tour)
    end),
    complete = complete_tours,
  },
  delete_tour = {
    desc = "Delete [tour]",
    run = with_tour(function(tour)
      recorder().delete_tours(tour and { tour } or nil)
    end),
    complete = complete_tours,
  },
  export = {
    desc = "Export the tour to [path] with file contents embedded",
    run = async(function(args)
      recorder().export_tour(nil, joined(args))
    end),
    complete = complete_files,
  },
}

M.subcommands.stop = M.subcommands["end"]

function M.run(opts)
  local args = vim.deepcopy(opts.fargs)
  local name = table.remove(args, 1)
  if not name then
    return require("codetour.tree").toggle()
  end
  local subcommand = M.subcommands[name]
  if not subcommand then
    return require("codetour.util").error(("Unknown subcommand %q. See :help codetour-commands."):format(name))
  end
  subcommand.run(args, { range = opts.range, line1 = opts.line1, line2 = opts.line2, bang = opts.bang })
end

function M.complete(arg_lead, cmdline, _)
  local words = vim.split(cmdline:gsub("^%s*%S*CodeTour!?%s*", ""), "%s+")
  if #words <= 1 then
    local names = vim.tbl_keys(M.subcommands)
    table.sort(names)
    return vim.tbl_filter(function(name)
      return vim.startswith(name, arg_lead)
    end, names)
  end
  local subcommand = M.subcommands[words[1]]
  if subcommand and subcommand.complete then
    return vim.tbl_filter(function(item)
      return vim.startswith(item, arg_lead)
    end, subcommand.complete(arg_lead))
  end
  return {}
end

return M
