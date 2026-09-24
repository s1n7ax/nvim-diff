--- Random file pairs for alignment tests: a base file and a mutation of it with deleted,
--- inserted and edited runs, including at the very top and the very bottom. Lines come from
--- a small vocabulary so that repeated lines (the hard case for a line differ) are common.

local M = {}

---@param rand fun(m: integer, n: integer): integer
---@return string
local function word_line(rand)
  local words = {}
  for i = 1, rand(1, 4) do
    words[i] = "w" .. rand(1, 12)
  end
  return table.concat(words, " ")
end

--- A deterministic pair of files.
---@param seed integer
---@param size? integer Lines in the base file. Default: 20..80, from the seed.
---@return string[] old
---@return string[] new
function M.files(seed, size)
  math.randomseed(seed)
  local rand = math.random
  size = size or rand(20, 80)
  local old, new = {}, {}
  for i = 1, size do
    old[i] = word_line(rand)
  end
  local i = 1
  -- Sometimes start with an insertion, so filler sits under the header.
  if rand() < 0.3 then
    for _ = 1, rand(1, 4) do
      new[#new + 1] = "top " .. word_line(rand)
    end
  end
  while i <= size do
    local r = rand()
    if r < 0.08 then
      i = i + rand(1, 5) -- delete a run
    elseif r < 0.16 then
      for _ = 1, rand(1, 6) do
        new[#new + 1] = "ins " .. word_line(rand)
      end
    elseif r < 0.26 then
      new[#new + 1] = old[i] .. " x" .. rand(1, 9)
      i = i + 1
    else
      new[#new + 1] = old[i]
      i = i + 1
    end
  end
  -- Sometimes end with a deletion or insertion, which needs the trailer line.
  local tail = rand()
  if tail < 0.25 then
    for _ = 1, rand(1, 4) do
      new[#new + 1] = "end " .. word_line(rand)
    end
  elseif tail < 0.5 then
    for _ = 1, rand(1, 4) do
      old[#old + 1] = "gone " .. word_line(rand)
    end
  end
  return old, new
end

return M
