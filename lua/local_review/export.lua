local M = {}

local context = require("local_review.context")
local comments = require("local_review.comments")
local export_indent_width = 3
local export_indent = string.rep(" ", export_indent_width)

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO)
end

local function export_lines(repo_root)
  local repo_comments = comments.list_repo_comments(repo_root)
  if #repo_comments == 0 then
    return {
      "No review comments found for this repository.",
    }
  end

  local lines = {
    "Please address the following feedback",
    "",
  }

  for index, comment in ipairs(repo_comments) do
    lines[#lines + 1] = string.format("%d. %s:%d", index, comment.relative_path, comment.line)
    -- Indent every rendered line so multi-line comments stay aligned
    lines[#lines + 1] = export_indent .. comment.body:gsub("\n", "\n" .. export_indent)
    lines[#lines + 1] = ""
  end

  return lines
end

function M.repo_export_text(repo_root)
  return table.concat(export_lines(repo_root), "\n")
end

function M.open_repo_export()
  local repo_root, err = context.repo_root()
  if not repo_root then
    notify(err, vim.log.levels.WARN)
    return
  end

  io.write(M.repo_export_text(repo_root) .. "\n")
end

return M
