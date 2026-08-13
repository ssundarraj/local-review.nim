local M = {}

local function opts()
  return require("local_review").get_opts()
end

local function ensure_dir(path)
  vim.fn.mkdir(path, "p")
end

local function scope_key(scope_root)
  return vim.fn.sha256(scope_root)
end

---@class LocalReviewStorageState
---@field hash string|nil

---Per-scope in-memory fingerprint of the file that was last loaded or saved
---by this process. Used to detect concurrent modifications by another Neovim
---instance or external process.
---@type table<string, LocalReviewStorageState>
local last_known = {}

local function file_hash(path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end

  local lines = vim.fn.readfile(path)
  return vim.fn.sha256(table.concat(lines, "\n"))
end

local function load_json(path)
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

function M.scope_file(scope_root)
  local base = opts().storage_dir
  return string.format("%s/%s.json", base, scope_key(scope_root))
end

function M.load_scope(scope_root)
  local path = M.scope_file(scope_root)
  local data = load_json(path)

  -- Record the disk fingerprint so subsequent writes can detect clobbering.
  last_known[scope_root] = { hash = file_hash(path) }

  return data
end

---Union two comment lists by comment id, preferring `save_comments` when ids
---overlap and preserving the order of `save_comments` before appending any
---disk-only comments.
---@param save_comments table
---@param disk_comments table
---@return table
local function merge_comments(save_comments, disk_comments)
  local by_id = {}

  for _, comment in ipairs(disk_comments or {}) do
    if type(comment) == "table" and type(comment.id) == "string" and comment.id ~= "" then
      by_id[comment.id] = comment
    end
  end

  -- Prefer the version being saved for duplicate ids.
  for _, comment in ipairs(save_comments or {}) do
    if type(comment) == "table" and type(comment.id) == "string" and comment.id ~= "" then
      by_id[comment.id] = comment
    end
  end

  local merged = {}

  -- Keep the caller's comment order first.
  for _, comment in ipairs(save_comments or {}) do
    if by_id[comment.id] then
      table.insert(merged, by_id[comment.id])
      by_id[comment.id] = nil
    end
  end

  -- Append comments that exist only on disk.
  for _, comment in ipairs(disk_comments or {}) do
    if by_id[comment.id] then
      table.insert(merged, by_id[comment.id])
      by_id[comment.id] = nil
    end
  end

  return merged
end

function M.save_scope(scope_root, data)
  local path = M.scope_file(scope_root)
  data.scope_root = scope_root
  data.comments = type(data.comments) == "table" and data.comments or {}

  ensure_dir(vim.fn.fnamemodify(path, ":h"))

  local file_readable = vim.fn.filereadable(path) == 1
  local known = last_known[scope_root]
  local current_hash = file_readable and file_hash(path) or nil

  if file_readable and (known == nil or current_hash ~= known.hash) then
    -- The file changed on disk since we last touched it. Merge instead of
    -- overwriting. If the disk state is corrupt or unreadable, fall back to
    -- the plain overwrite below.
    local disk = load_json(path)
    if disk and type(disk.comments) == "table" then
      data.comments = merge_comments(data.comments, disk.comments)
    end
  end

  if vim.fn.writefile({ vim.json.encode(data) }, path) ~= 0 then
    return nil, string.format("Failed to save review comments to %s.", path)
  end

  -- Remember the fingerprint of the file we just produced.
  last_known[scope_root] = { hash = file_hash(path) }

  return true
end

function M.delete_scope(scope_root)
  local path = M.scope_file(scope_root)
  last_known[scope_root] = nil

  if vim.fn.filereadable(path) == 1 then
    return vim.fn.delete(path) == 0
  end

  return true
end

function M.list_scopes()
  local base = opts().storage_dir
  ensure_dir(base)

  local paths = vim.fn.glob(vim.fs.joinpath(base, "*.json"), false, true)
  local scopes = {}
  for _, path in ipairs(paths) do
    local data = load_json(path)
    local scope_root = data.scope_root
    if type(scope_root) == "string" and scope_root ~= "" then
      table.insert(scopes, {
        scope_root = scope_root,
        path = path,
        data = data,
      })
    end
  end

  return scopes
end

return M
