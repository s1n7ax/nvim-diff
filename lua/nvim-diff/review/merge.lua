--- Merging the reviewed PR from its review: `:NvimDiffMerge [merge|squash|rebase]`
--- or `keymaps.review.merge`.
---
--- Without an argument (the key), a picker asks which of GitHub's methods to use; with
--- one, that method is used directly. Either way nothing is sent before a confirmation
--- says yes, and the head sent is the one the review shows — a push that lands in between
--- makes GitHub refuse rather than merge unseen code (`github/merge.lua`). On success the
--- review checks GitHub at once, which announces the merge and stops syncing.

local gh_merge = require("nvim-diff.github.merge")
local log = require("nvim-diff.core.log")

local M = {}

--- The words the command takes, to GitHub's method names.
---@type table<string, NvimDiff.GitHub.MergeMethod>
M.ARGS = {
  merge = "merge",
  squash = "squash",
  rebase = "rebase",
}

--- Asks whether to merge. Replaceable, so specs can answer without a prompt.
---@param prompt string
---@return boolean merge
function M.confirm(prompt)
  return vim.fn.confirm(prompt, "&Merge\n&Cancel", 2) == 1
end

---@param review NvimDiff.Review
---@return string
local function describe(review)
  return ("PR #%d"):format(review.number)
end

--- Confirm, then merge `review` with `method`. The review must still be open.
---@param review NvimDiff.Review
---@param method NvimDiff.GitHub.MergeMethod
---@return boolean merged False when cancelled, refused, or GitHub said no.
function M.run(review, method)
  local info = gh_merge.info(method)
  if not info then
    log.error("not a merge method: %s", vim.inspect(method))
    return false
  end
  if not review:is_valid() then
    log.error("the review has ended")
    return false
  end
  local prompt = ("%s %s?"):format(info.label, describe(review))
  if review.pr.head.oid then
    prompt = ("%s\nHead %s"):format(prompt, review.pr.head.oid:sub(1, 7))
  end
  if not M.confirm(prompt) then
    return false
  end
  if not review:is_valid() then
    log.error("the review has ended")
    return false
  end
  vim.notify(("nvim-diff: %s %s…"):format(info.label:lower(), describe(review)), vim.log.levels.INFO)
  vim.cmd.redraw()
  local result, err = gh_merge.merge(review.pr, method)
  if not result then
    ---@cast err NvimDiff.GitHub.Error
    log.error("%s not merged: %s", describe(review), err.message)
    return false
  end
  vim.notify(
    ("nvim-diff: %s %s%s"):format(
      describe(review),
      info.label:lower():gsub("^%l", string.upper),
      result.sha and ("d as " .. result.sha:sub(1, 7)) or "d"
    ),
    vim.log.levels.INFO
  )
  review:sync_now()
  return true
end

--- `:NvimDiffMerge [merge|squash|rebase]`. With no argument, a picker asks.
---@param arg string
function M.command(arg)
  local review = require("nvim-diff.views.review").get()
  if not review then
    vim.notify("nvim-diff: :NvimDiffMerge works in a PR review's tab (:NvimDiffPR)", vim.log.levels.ERROR)
    return
  end
  arg = vim.trim(arg or ""):lower()
  if arg ~= "" then
    local method = M.ARGS[arg]
    if not method then
      vim.notify(("nvim-diff: :NvimDiffMerge takes merge, squash or rebase, not %q"):format(arg), vim.log.levels.ERROR)
      return
    end
    M.run(review, method)
    return
  end
  vim.ui.select(gh_merge.METHODS, {
    prompt = ("Merge PR #%d"):format(review.number),
    format_item = function(row)
      return row.label
    end,
  }, function(row)
    if row and review:is_valid() then
      M.run(review, row.method)
    end
  end)
end

--- Completion for the command's one argument.
---@param arglead string
---@return string[]
function M.complete(arglead)
  local out = {}
  for _, word in ipairs({ "merge", "squash", "rebase" }) do
    if vim.startswith(word, arglead) then
      out[#out + 1] = word
    end
  end
  return out
end

return M
