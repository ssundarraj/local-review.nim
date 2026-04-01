local M = {}

local function normalize(path)
  return vim.fs.normalize(path)
end

function M.current_file(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr or 0)
  if path == nil or path == "" then
    return nil, "Current buffer has no file path."
  end
  return normalize(path)
end

function M.repo_root(path)
  local target = path or vim.api.nvim_buf_get_name(0)
  if target == nil or target == "" then
    target = vim.uv.cwd()
  end

  local directory = vim.fn.fnamemodify(target, ":p:h")
  local result = vim.fn.systemlist({ "git", "-C", directory, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or result[1] == nil or result[1] == "" then
    return nil, "Not inside a git repository."
  end

  return normalize(result[1])
end

function M.relative_path(repo_root, absolute_path)
  local root = normalize(repo_root)
  local path = normalize(absolute_path)
  local prefix = root .. "/"

  if path == root then
    return "."
  end

  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end

  return vim.fn.fnamemodify(path, ":t")
end

function M.comment_context(bufnr)
  local absolute_path, file_err = M.current_file(bufnr)
  if not absolute_path then
    return nil, file_err
  end

  local repo_root, repo_err = M.repo_root(absolute_path)
  if not repo_root then
    return nil, repo_err
  end

  return {
    absolute_path = absolute_path,
    repo_root = repo_root,
    relative_path = M.relative_path(repo_root, absolute_path),
    bufnr = bufnr or 0,
  }
end

return M
