--- A second Neovim, driven over RPC, for tests that need the real input loop.
---
--- Scrolling behaviour cannot be tested from inside the test process: `nvim -l` never
--- reaches the main loop, so `WinScrolled` and `CursorMoved` never fire there, and
--- `:normal!` scrolls differently from typed keys. The child is `nvim --embed --headless`:
--- keys go in through `nvim_input`, which runs the real input loop and its autocommands,
--- and the screen comes back through `screenstring()`.
---
--- This is the harness's screen capture. It returns text, not colour — colour is checked
--- through extmarks in the test process instead.
---
--- Two limits of a headless Neovim with no UI attached, both measured on 0.12.4 and the
--- 0.13 nightly: the screen is 80x24, and **raising `lines` or `columns` above that
--- corrupts the grid** (a later redraw segfaults in `grid_clear_line`). Lowering them is
--- safe.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.normalize(vim.fn.fnamemodify(script, ":p:h:h"))

local M = {}

---@class NvimDiff.TestChild
---@field chan integer
---@field seq? integer Last input sentinel typed.
local Child = {}
Child.__index = Child

--- Start a child with this repository on its runtimepath and `tests.*` requirable.
---@return NvimDiff.TestChild
function M.spawn()
  local chan = vim.fn.jobstart({ vim.v.progpath, "--clean", "--embed", "--headless", "-n" }, { rpc = true })
  assert(chan > 0, "could not start a child nvim")
  local self = setmetatable({ chan = chan }, Child)
  self:lua(
    [[
    local root = ...
    vim.opt.runtimepath:prepend(root)
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
    vim.g.nvim_diff_test_seq = 0
  ]],
    root
  )
  return self
end

--- Run Lua in the child and return its result. Arguments arrive as `...`.
---@param code string
---@param ... any
---@return any
function Child:lua(code, ...)
  return vim.rpcrequest(self.chan, "nvim_exec_lua", code, { ... })
end

--- Wait until the child has consumed everything typed so far.
---
--- `nvim_input` only queues keys, and a request can be answered before they have run —
--- measured: 1 in 900 checks read the screen between a `<C-d>` and the `WinScrolled` it
--- caused. So a `<Cmd>` sentinel is typed after the keys and waited for; it runs only once
--- every key before it has, and the idle round-trip after it lets the autocommands of the
--- last key fire.
function Child:settle()
  self.seq = (self.seq or 0) + 1
  local seq = self.seq
  vim.rpcrequest(self.chan, "nvim_input", ("<Cmd>let g:nvim_diff_test_seq = %d<CR>"):format(seq))
  local ok = vim.wait(5000, function()
    return vim.rpcrequest(self.chan, "nvim_get_var", "nvim_diff_test_seq") == seq
  end, 1)
  assert(ok, "child did not consume its input")
  vim.rpcrequest(self.chan, "nvim_exec_lua", "return true", {})
end

--- Type keys (`<C-e>` notation) and wait until they, and their autocommands, have run.
---@param keys string
function Child:input(keys)
  vim.rpcrequest(self.chan, "nvim_input", keys)
  self:settle()
end

--- A mouse event, as `nvim_input_mouse` takes it: e.g. `("wheel", "down", "", 0, row, col)`.
---@param ... any
function Child:mouse(...)
  vim.rpcrequest(self.chan, "nvim_input_mouse", ...)
  self:settle()
end

--- Screen text, one string per row, `row1..row2` and `col1..col2` inclusive (1-based).
---@param row1 integer
---@param row2 integer
---@param col1 integer
---@param col2 integer
---@return string[]
function Child:screen(row1, row2, col1, col2)
  return self:lua(
    [[
    local r1, r2, c1, c2 = ...
    vim.cmd("redraw")
    local rows = {}
    for r = r1, r2 do
      local cells = {}
      for c = c1, c2 do
        cells[#cells + 1] = vim.fn.screenstring(r, c)
      end
      rows[#rows + 1] = table.concat(cells)
    end
    return rows
  ]],
    row1,
    row2,
    col1,
    col2
  )
end

function Child:stop()
  pcall(vim.fn.jobstop, self.chan)
end

return M
