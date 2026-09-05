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

local function normalize_removed_ids(data)
  if type(data.removed_ids) ~= "table" then
    data.removed_ids = {}
  end
  return data.removed_ids
end

local function acquire_lock(path)
  local lock_path = path .. ".lock"
  for _ = 1, 100 do
    local fd, err = vim.uv.fs_open(lock_path, "wx", 384)
    if fd then
      return fd, lock_path
    end
    if not err or not err:match("EEXIST") then
      return nil, string.format("Failed to lock review comments at %s: %s", path, err or "unknown error")
    end
    vim.wait(10)
  end
  return nil, string.format("Timed out waiting to lock review comments at %s", path)
end

local function release_lock(fd, lock_path)
  vim.uv.fs_close(fd)
  vim.uv.fs_unlink(lock_path)
end

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
  normalize_removed_ids(decoded)
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

local function filter_removed_comments(comments, removed_ids)
  local filtered = {}
  for _, comment in ipairs(comments) do
    if not removed_ids[comment.id] then
      table.insert(filtered, comment)
    end
  end
  return filtered
end

local function merge_removed_ids(save_removed_ids, disk_removed_ids)
  local merged = {}
  for id, removed in pairs(disk_removed_ids) do
    if removed then
      merged[id] = true
    end
  end
  for id, removed in pairs(save_removed_ids) do
    if removed then
      merged[id] = true
    end
  end
  return merged
end

---@param scope_root string
---@param data table
---@param opts { remove_ids: table<string, boolean>? }?
---@return boolean? ok, string? err
function M.save_scope(scope_root, data, opts)
  local path = M.scope_file(scope_root)
  data.scope_root = scope_root
  data.comments = type(data.comments) == "table" and data.comments or {}
  local removed_ids = normalize_removed_ids(data)
  if opts and opts.remove_ids then
    removed_ids = merge_removed_ids(removed_ids, opts.remove_ids)
    data.removed_ids = removed_ids
  end

  ensure_dir(vim.fn.fnamemodify(path, ":h"))

  local fd, lock_or_err = acquire_lock(path)
  if not fd then
    return nil, lock_or_err
  end

  local ok, result, err = xpcall(function()
    local file_readable = vim.fn.filereadable(path) == 1
    local known = last_known[scope_root]
    local current_hash = file_readable and file_hash(path) or nil

    if file_readable and (known == nil or current_hash ~= known.hash) then
      local disk = load_json(path)
      data.comments = merge_comments(data.comments, disk.comments)
      data.removed_ids = merge_removed_ids(data.removed_ids, disk.removed_ids)
    end

    data.comments = filter_removed_comments(data.comments, data.removed_ids)

    local tmp_path = path .. ".tmp"
    if vim.fn.writefile({ vim.json.encode(data) }, tmp_path) ~= 0 then
      return nil, string.format("Failed to save review comments to %s.", path)
    end
    local renamed, rename_err = os.rename(tmp_path, path)
    if not renamed then
      os.remove(tmp_path)
      return nil, string.format("Failed to save review comments to %s: %s", path, rename_err or "rename failed")
    end

    last_known[scope_root] = { hash = file_hash(path) }
    return true
  end, debug.traceback)
  release_lock(fd, lock_or_err)

  if not ok then
    return nil, tostring(result)
  end
  return result, err
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
