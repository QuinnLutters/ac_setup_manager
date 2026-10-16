-- F8: building versioned setup files and diffs. Pure string work; the game
-- layer does the actual file IO.

local ini = require('src/core/ini')
local util = require('src/core/util')

local M = {}

M.PREFIX = 'DSA_'

local function safeId(id)
  return (id:gsub('[^%w%-_%.]', '_'))
end

function M.fileName(carId, n)
  return string.format('%s%s_v%d.ini', M.PREFIX, safeId(carId), n)
end

-- Highest DSA version number already present for this car among `existing` file names.
function M.maxVersion(carId, existing)
  local pattern = '^' .. M.PREFIX:gsub('%p', '%%%0') .. safeId(carId):gsub('%p', '%%%0') .. '_v(%d+)%.ini$'
  local max = 0
  for _, name in ipairs(existing or {}) do
    local n = tonumber(name:match(pattern))
    if n and n > max then max = n end
  end
  return max
end

-- Next free file name. Never returns a name that's in `existing`, so the
-- driver's own files (and our older versions) are never overwritten.
function M.nextFileName(carId, existing, atLeast)
  local n = math.max(M.maxVersion(carId, existing) + 1, atLeast or 1)
  local taken = {}
  for _, name in ipairs(existing or {}) do taken[name:lower()] = true end
  while taken[M.fileName(carId, n):lower()] do n = n + 1 end
  return M.fileName(carId, n), n
end

function M.isOwnFile(name)
  return name:sub(1, #M.PREFIX) == M.PREFIX
end

-- baseIni: parsed setup file the change starts from (may be nil).
-- values: { ITEM = value } to set. carId goes into [CAR] MODEL.
function M.build(baseIni, values, carId, headerLines)
  local out = baseIni and util.deepcopy(baseIni) or ini.new()
  for _, name in ipairs(util.keys(values)) do
    ini.set(out, name, 'VALUE', util.fmt(values[name], 6))
  end
  if carId and not (out.sections.CAR and out.sections.CAR.values.MODEL) then
    ini.set(out, 'CAR', 'MODEL', carId)
  end
  return ini.serialize(out, headerLines and table.concat(headerLines, '\n') or nil)
end

-- Diff between two { ITEM = value } maps. itemsByName gives labels/display.
function M.diff(oldValues, newValues, itemsByName)
  local rows, seen = {}, {}
  local names = {}
  for k in pairs(oldValues or {}) do if not seen[k] then seen[k] = true; names[#names + 1] = k end end
  for k in pairs(newValues or {}) do if not seen[k] then seen[k] = true; names[#names + 1] = k end end
  table.sort(names)
  for _, name in ipairs(names) do
    local a, b = oldValues and oldValues[name], newValues and newValues[name]
    if a ~= b and not (a and b and math.abs(a - b) < 1e-9) then
      local item = itemsByName and itemsByName[name]
      local display = function(v)
        if v == nil then return '—' end
        if item then return require('src/core/setup_items').display(item, v) end
        return util.fmt(v, 3)
      end
      rows[#rows + 1] = { name = name, label = item and item.label or name, from = a, to = b,
        fromDisplay = display(a), toDisplay = display(b) }
    end
  end
  return rows
end

return M
