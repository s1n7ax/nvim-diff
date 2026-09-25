--- A PR review verdict: Approve, Request changes or Comment, with an optional summary body.
---
--- One REST call, `POST /repos/{owner}/{repo}/pulls/{n}/reviews`, carrying `event`,
--- `commit_id` and `body` and **never** a `comments` array: inline comments were already
--- posted one at a time, so the review carries only the verdict. `event` is never omitted —
--- without it GitHub creates a PENDING review instead, the batching model the user ruled out.
---
--- `commit_id` is the head the reviewer was looking at (`NvimDiff.GitHub.PR.head.oid`, what
--- the worktree is checked out at). A push that lands mid-review then shows on GitHub as an
--- approval of the older commit — which is what the reviewer actually approved.
---
--- GitHub requires a body for `REQUEST_CHANGES` and `COMMENT` (a 422 otherwise); that is
--- checked here, before anything is sent. Approving your own PR is a 422 too; its message
--- comes back as the error's message.

local cmd = require("nvim-diff.github.cmd")
local errors = require("nvim-diff.github.error")

local M = {}

---@alias NvimDiff.GitHub.ReviewEvent "APPROVE"|"REQUEST_CHANGES"|"COMMENT"

--- Every verdict, in the order a picker offers them, with its name for people.
---@type { event: NvimDiff.GitHub.ReviewEvent, label: string, needs_body: boolean }[]
M.EVENTS = {
  { event = "APPROVE", label = "Approve", needs_body = false },
  { event = "REQUEST_CHANGES", label = "Request changes", needs_body = true },
  { event = "COMMENT", label = "Comment", needs_body = true },
}

--- The `M.EVENTS` row for `event`.
---@param event string
---@return { event: NvimDiff.GitHub.ReviewEvent, label: string, needs_body: boolean }?
function M.info(event)
  for _, row in ipairs(M.EVENTS) do
    if row.event == event then
      return row
    end
  end
  return nil
end

---@class NvimDiff.GitHub.Review
---@field id integer REST id.
---@field node_id? string
---@field state string `APPROVED`, `CHANGES_REQUESTED` or `COMMENTED`.
---@field url? string `html_url`.

--- A 422's `errors` array holds plain strings ("Can not approve your own pull request") or
--- objects with a `message`; the top-level `message` is only "Unprocessable Entity".
---@param body any
---@return string?
local function unprocessable(body)
  if type(body) ~= "table" or type(body.errors) ~= "table" then
    return nil
  end
  local parts = {}
  for _, one in ipairs(body.errors) do
    if type(one) == "string" then
      parts[#parts + 1] = one
    elseif type(one) == "table" and type(one.message) == "string" then
      parts[#parts + 1] = one.message
    end
  end
  return #parts > 0 and table.concat(parts, "; ") or nil
end

--- Submit a verdict on `pr`.
---@param pr NvimDiff.GitHub.PR
---@param event NvimDiff.GitHub.ReviewEvent
---@param body? string Summary; sent only when it has more than whitespace.
---@return NvimDiff.GitHub.Review? review
---@return NvimDiff.GitHub.Error? err `invalid` for an unknown event or a missing required
---body (nothing is sent); otherwise whatever GitHub answered.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.submit(pr, event, body)
  local info = M.info(event)
  if not info then
    return nil, errors.new("invalid", ("not a review verdict: %s"):format(vim.inspect(event)))
  end
  local has_body = type(body) == "string" and body:find("%S") ~= nil
  if info.needs_body and not has_body then
    return nil, errors.new("invalid", ("%s needs a summary"):format(info.label))
  end

  local target = pr.target
  local vars = {
    { flag = "-f", name = "event", value = event },
    { flag = "-f", name = "commit_id", value = pr.head.oid },
  }
  if has_body then
    vars[#vars + 1] = { flag = "-f", name = "body", value = body }
  end
  local response, err = cmd.request(
    target.host,
    ("repos/%s/%s/pulls/%d/reviews"):format(target.owner, target.repo, pr.number),
    { vars = vars }
  )
  if not response then
    return nil, err
  end
  local data
  data, err = cmd.classify(response)
  if not data then
    ---@cast err NvimDiff.GitHub.Error
    local detail = response.status == 422 and unprocessable(response.body)
    if detail then
      err.message = detail
    end
    return nil, err
  end
  if type(data.id) ~= "number" then
    return nil, errors.new("api_error", "GitHub's reply to the review has no id", { status = response.status })
  end
  return {
    id = data.id,
    node_id = type(data.node_id) == "string" and data.node_id or nil,
    state = type(data.state) == "string" and data.state or "",
    url = type(data.html_url) == "string" and data.html_url or nil,
  }
end

return M
