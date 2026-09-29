-- Git helpers used for tour refs (VS Code uses the built-in git extension).

local M = {}

local function git(cwd, args)
  if vim.fn.executable("git") ~= 1 then
    return nil
  end
  local ok, result = pcall(function()
    return vim.system(vim.list_extend({ "git", "-C", cwd }, args), { text = true }):wait(10000)
  end)
  if not ok or result.code ~= 0 then
    return nil, ok and result.stderr or result
  end
  return vim.trim(result.stdout or "")
end

local function dir_of(path)
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "directory" then
    return path
  end
  return vim.fs.dirname(path)
end

--- Returns information about the repository containing `path`.
---@return { root: string, branch?: string, commit?: string }|nil
function M.repository(path)
  local cwd = dir_of(path)
  local root = git(cwd, { "rev-parse", "--show-toplevel" })
  if not root or root == "" then
    return nil
  end
  local branch = git(cwd, { "symbolic-ref", "--quiet", "--short", "HEAD" })
  local commit = git(cwd, { "rev-parse", "HEAD" })
  return { root = require("codetour.util").normalize(root), branch = branch, commit = commit }
end

--- Lists the repository's tags, sorted.
function M.tags(path)
  local out = git(dir_of(path), { "tag", "--list" })
  if not out or out == "" then
    return {}
  end
  local tags = vim.split(out, "\n", { trimempty = true })
  table.sort(tags)
  return tags
end

--- Resolves a ref to a commit SHA.
function M.resolve(path, ref)
  return git(dir_of(path), { "rev-parse", "--verify", "--quiet", ref .. "^{commit}" })
end

--- Returns whether a tour pinned to `ref` should show `path` from git instead
--- of the working tree. Mirrors the checks in VS Code's getStepFileUri.
---@return boolean use_ref
---@return table|nil repository
function M.should_use_ref(path, ref)
  if not ref or ref == "" or ref == "HEAD" then
    return false
  end
  local repo = M.repository(path)
  if not repo or not repo.commit then
    return false
  end
  if repo.branch == ref or repo.commit == ref then
    return false
  end
  if M.resolve(path, ref) == repo.commit then
    return false
  end
  return true, repo
end

--- Reads `path` as of `ref`.
---@return string|nil content
---@return string|nil err
function M.show(path, ref, repo)
  repo = repo or M.repository(path)
  if not repo then
    return nil, "not a git repository"
  end
  local relative = require("codetour.util").relative(repo.root, require("codetour.util").realpath(path))
  if relative:sub(1, 3) == "../" then
    relative = require("codetour.util").relative(repo.root, path)
  end
  if vim.fn.executable("git") ~= 1 then
    return nil, "git is not installed"
  end
  local result = vim.system({ "git", "-C", repo.root, "show", ref .. ":" .. relative }, { text = true }):wait(10000)
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or "")
  end
  return result.stdout
end

return M
