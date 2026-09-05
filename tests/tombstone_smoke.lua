-- A stale writer must not resurrect a comment deleted by another process.

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

local storage_dir = vim.fn.tempname() .. "_tombstone_smoke"
vim.fn.mkdir(storage_dir, "p")

require("local_review").setup({ storage_dir = storage_dir })

local scope_root = "/tmp/local_review_tombstone_repo"
local storage = require("local_review.storage")

local seed = storage.load_scope(scope_root)
table.insert(seed.comments, {
  id = "comment-doomed",
  body = "will be removed",
  absolute_path = "/tmp/a.txt",
})
assert(storage.save_scope(scope_root, seed), "seed save failed")

-- Simulate process A loading the comment before process B deletes it.
local stale_data = storage.load_scope(scope_root)

local remover_script = string.format(
  [[
vim.opt.runtimepath:append("%s")
require("local_review").setup({ storage_dir = "%s" })
local storage = require("local_review.storage")
local data = storage.load_scope("%s")
data.comments = {}
assert(storage.save_scope("%s", data, { remove_ids = { ["comment-doomed"] = true } }))
]],
  plugin_root,
  storage_dir,
  scope_root,
  scope_root
)

local remover_path = vim.fn.tempname() .. "_remover.lua"
vim.fn.writefile(vim.split(remover_script, "\n"), remover_path)
local result = vim.system({ "nvim", "--headless", "--clean", "-u", "NONE", "-l", remover_path }):wait()
if result.code ~= 0 then
  error(string.format("Remover failed: %s", result.stderr or "unknown error"))
end

-- Process A now writes its old in-memory copy. The persisted tombstone wins.
assert(storage.save_scope(scope_root, stale_data), "stale save failed")

local final = storage.load_scope(scope_root)
for _, comment in ipairs(final.comments) do
  assert(comment.id ~= "comment-doomed", "deleted comment was resurrected")
end
assert(final.removed_ids["comment-doomed"], "deletion tombstone was not persisted")

print("PASS: tombstone prevents stale-write resurrection")
