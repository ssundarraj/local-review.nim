local M = {}

local defaults = {
  marker_text = "●",
  marker_hl = "DiagnosticHint",
  storage_dir = vim.fs.joinpath(vim.fn.stdpath("state"), "local-review"),
  keymaps = {},
}

local state = {
  configured = false,
  opts = vim.deepcopy(defaults),
}

local function command(name, rhs, opts)
  vim.api.nvim_create_user_command(name, rhs, opts or {})
end

local function map(mode, lhs, rhs, desc)
  if lhs == nil or lhs == "" then
    return
  end

  vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true })
end

local function visual_safe_cmd(command_name)
  return function()
    local mode = vim.api.nvim_get_mode().mode
    if mode:match("^[vV\22]") then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    end
    vim.cmd(command_name)
  end
end

local function refresh_current_buffer(bufnr)
  require("local_review.markers").refresh(bufnr or vim.api.nvim_get_current_buf())
end

function M.setup(opts)
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  if not state.configured then
    command("LocalReviewComment", function()
      require("local_review.ui").open_current_line()
    end, {})

    command("LocalReviewDelete", function()
      require("local_review.comments").delete_current_line()
    end, {})

    command("LocalReviewNext", function()
      require("local_review.comments").jump(1)
    end, {})

    command("LocalReviewPrev", function()
      require("local_review.comments").jump(-1)
    end, {})

    command("LocalReviewExport", function()
      require("local_review.export").open_repo_export()
    end, {})

    command("LocalReviewClearRepo", function()
      require("local_review.comments").clear_repo()
    end, {})

    vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost", "BufWritePost", "FileChangedShellPost" }, {
      group = vim.api.nvim_create_augroup("local-review-refresh", { clear = true }),
      callback = function(event)
        refresh_current_buffer(event.buf)
      end,
    })

    state.configured = true
  end

  map({ "n", "x" }, state.opts.keymaps.comment, visual_safe_cmd("LocalReviewComment"), "Local Review: Comment")
  map({ "n", "x" }, state.opts.keymaps.delete, visual_safe_cmd("LocalReviewDelete"), "Local Review: Delete")
  map({ "n", "x" }, state.opts.keymaps.next, visual_safe_cmd("LocalReviewNext"), "Local Review: Next")
  map({ "n", "x" }, state.opts.keymaps.prev, visual_safe_cmd("LocalReviewPrev"), "Local Review: Prev")
  map({ "n", "x" }, state.opts.keymaps.export, visual_safe_cmd("LocalReviewExport"), "Local Review: Export")
end

function M.get_opts()
  return state.opts
end

return M
