local M = {}

local context = require("local_review.context")

local function opts()
  return require("local_review").get_opts()
end

local function ensure_dir(path)
  vim.fn.mkdir(path, "p")
end

local function repo_key(repo_root)
  return vim.fn.sha256(repo_root)
end

function M.repo_file(repo_root)
  local base = opts().storage_dir
  return string.format("%s/%s.json", base, repo_key(repo_root))
end

function M.load_repo(repo_root)
  local path = M.repo_file(repo_root)
  if vim.fn.filereadable(path) == 0 then
    return { comments = {} }
  end

  local lines = vim.fn.readfile(path)
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(decoded) ~= "table" then
    return { comments = {} }
  end

  decoded.comments = type(decoded.comments) == "table" and decoded.comments or {}
  return decoded
end

function M.save_repo(repo_root, data)
  local path = M.repo_file(repo_root)
  ensure_dir(vim.fn.fnamemodify(path, ":h"))
  if vim.fn.writefile({ vim.json.encode(data) }, path) ~= 0 then
    return nil, string.format("Failed to save review comments to %s.", path)
  end

  return true
end

function M.delete_repo(repo_root)
  local path = M.repo_file(repo_root)
  if vim.fn.filereadable(path) == 1 then
    return vim.fn.delete(path) == 0
  end

  return true
end

function M.for_current_repo()
  local repo_root, err = context.repo_root()
  if not repo_root then
    return nil, err
  end

  return {
    repo_root = repo_root,
    data = M.load_repo(repo_root),
  }
end

return M
