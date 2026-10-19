-- Decides whether a tour may run shell commands.
--
-- Tours can send text to a terminal (`>>` lines and `codetour.sendTextToTerminal`)
-- or run `:make`, so a tour from somewhere you don't know is as dangerous as any
-- script. Unlike VS Code, Neovim has no workspace trust, so the plugin asks
-- before running such a command from a tour it hasn't seen. "Always trust" is
-- remembered by the tour file's content hash: editing the file asks again.

local config = require("codetour.config")
local util = require("codetour.util")

local M = {}

local MAX_PREVIEW = 600

--- Asks a question with numbered choices; returns the index (0 when dismissed).
--- Replaceable in tests.
function M.confirm(message, choices, default)
  return vim.fn.confirm(message, choices, default, "Warning")
end

local function read()
  local content = util.read_file(config.get().trust_file)
  if not content or content == "" then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, content)
  return ok and type(decoded) == "table" and decoded or {}
end

--- A tour that is a local file (not a URL, or a tour that isn't saved yet).
local function file_path(tour)
  local id = tour and tour.id
  if type(id) ~= "string" or util.is_url(id) then
    return nil
  end
  if vim.uv.fs_stat(id) == nil then
    return nil
  end
  return id
end

local function fingerprint(path)
  local content = util.read_file(path)
  return content and vim.fn.sha256(content)
end

--- Whether the tour's file was trusted and hasn't changed since.
function M.is_trusted(tour)
  local path = file_path(tour)
  if not path then
    return false
  end
  local hash = fingerprint(path)
  return hash ~= nil and read()[path] == hash
end

--- Trusts the tour's current content.
function M.trust(tour)
  local path = file_path(tour)
  local hash = path and fingerprint(path)
  if not hash then
    return false
  end
  local trusted = read()
  trusted[path] = hash
  local ok, err = util.write_file(config.get().trust_file, vim.json.encode(trusted))
  if not ok then
    util.error("Unable to save trusted tours: " .. tostring(err))
  end
  return ok
end

--- Forgets a trusted tour (or every tour without an argument).
function M.revoke(tour)
  if tour == nil then
    util.write_file(config.get().trust_file, "{}")
    return
  end
  local path = file_path(tour) or tour.id
  local trusted = read()
  trusted[path] = nil
  util.write_file(config.get().trust_file, vim.json.encode(trusted))
end

local function preview(what)
  what = tostring(what)
  if #what > MAX_PREVIEW then
    what = what:sub(1, MAX_PREVIEW) .. "…"
  end
  return what
end

--- Whether `tour` may run `what` (the text that would be executed).
---@param tour? codetour.Tour
---@param what string
function M.allow(tour, what)
  local mode = config.get().trust
  if mode == "always" then
    return true
  end
  if mode == "never" then
    util.warn(("Not running a command from a tour (`trust = \"never\"`): %s"):format(preview(what)))
    return false
  end
  if M.is_trusted(tour) then
    return true
  end

  local title = tour and tour.title or "A tour"
  local message = ("%s wants to run:\n\n%s\n\nOnly run commands from tours you trust."):format(title, preview(what))

  -- Tours that aren't a local file (opened from a URL, or unsaved) can't be
  -- identified by content, so they're asked about every time.
  if file_path(tour) then
    local choice = M.confirm(message, "&Run once\n&Always trust this tour\n&Cancel", 3)
    if choice == 2 then
      M.trust(tour)
    end
    return choice == 1 or choice == 2
  end
  return M.confirm(message, "&Run once\n&Cancel", 2) == 1
end

return M
