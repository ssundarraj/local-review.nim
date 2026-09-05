-- Last-write-wins concurrency smoke test for storage.lua.
--
-- Simulates two Neovim instances sharing the same storage_dir:
--   1. Instance A loads the scope, adds comment-a, and keeps the data in memory.
--   2. Instance B (spawned in a separate headless nvim) loads the same scope,
--      adds comment-b, and saves.
--   3. Instance A saves its (stale) in-memory state.
--
-- A proper last-write-wins merge should detect the disk change, reload the
-- disk state, and union both comments so that neither is lost.

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

local storage_dir = vim.fn.tempname() .. "_lww_smoke"
vim.fn.mkdir(storage_dir, "p")

require("local_review").setup({ storage_dir = storage_dir })

local scope_root = "/tmp/local_review_lww_repo"
local storage = require("local_review.storage")

-- Instance A: load and add comment-a.
local data_a = storage.load_scope(scope_root)
table.insert(data_a.comments, {
  id = "comment-a",
  body = "from instance A",
  absolute_path = "/tmp/a.txt",
})

-- Instance B: separate headless nvim process adding comment-b.
local b_script = string.format(
  [[
vim.opt.runtimepath:append("%s")
require("local_review").setup({ storage_dir = "%s" })

local scope_root = "%s"
local storage = require("local_review.storage")
local data = storage.load_scope(scope_root)
table.insert(data.comments, {
  id = "comment-b",
  body = "from instance B",
  absolute_path = "/tmp/b.txt",
})
storage.save_scope(scope_root, data)
]],
  plugin_root,
  storage_dir,
  scope_root
)

local b_path = vim.fn.tempname() .. "_instance_b.lua"
vim.fn.writefile(vim.split(b_script, "\n"), b_path)

local result = vim
  .system({
    "nvim",
    "--headless",
    "--clean",
    "-u",
    "NONE",
    "-l",
    b_path,
  })
  :wait()

if result.code ~= 0 then
  error(string.format("Instance B failed: %s", result.stderr or "unknown error"))
end

-- Instance A: save its stale state. The storage layer should merge, not clobber.
local ok, err = storage.save_scope(scope_root, data_a)
if not ok then
  error(err or "Instance A failed to save")
end

-- Verify both comments survived.
local final = storage.load_scope(scope_root)
local ids = {}
for _, comment in ipairs(final.comments) do
  ids[comment.id] = true
end

assert(ids["comment-a"], "comment-a from instance A was lost")
assert(ids["comment-b"], "comment-b from instance B was lost")

print("PASS: both comments survived concurrent saves")
