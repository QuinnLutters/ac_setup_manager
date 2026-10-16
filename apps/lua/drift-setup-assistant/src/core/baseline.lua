-- F10: a starter drift baseline generated from the car's own setup ranges.

local items = require('src/core/setup_items')
local catalog = require('src/core/catalog')

local M = {}

-- Returns { changes = { { lever, label, why, items = { {name, from, to, ...} } } }, skipped = { {lever, label} } }
function M.generate(rules, leverGroups)
  local out = { changes = {}, skipped = {} }
  for _, entry in ipairs(rules.baseline or {}) do
    local g = leverGroups[entry.lever]
    local label = catalog.LEVERS[entry.lever] and catalog.LEVERS[entry.lever].label or entry.lever
    local rows = {}
    if g then
      for _, item in ipairs(g.items) do
        if item.kind == 'range' then
          local f = entry.fraction
          if item.invert then f = 1 - f end
          local to = items.snap(item, item.min + f * (item.max - item.min))
          rows[#rows + 1] = { name = item.name, label = item.label, from = item.value, to = to,
            fromDisplay = items.display(item, item.value), toDisplay = items.display(item, to),
            moved = item.value == nil or math.abs(to - item.value) > 1e-9 }
        end
      end
    end
    if #rows > 0 then
      out.changes[#out.changes + 1] = { lever = entry.lever, label = label, why = entry.why, items = rows }
    else
      out.skipped[#out.skipped + 1] = { lever = entry.lever, label = label }
    end
  end

  -- Keep rear pressure above front, as the brief asks, even on odd ranges.
  local front, rear
  for _, c in ipairs(out.changes) do
    if c.lever == 'pressure_front' then front = c end
    if c.lever == 'pressure_rear' then rear = c end
  end
  if front and rear and rear.items[1].to <= front.items[1].to then
    local g = leverGroups.pressure_rear
    for i, row in ipairs(rear.items) do
      local item = g.items[i]
      local to = items.snap(item, front.items[1].to + 2 * item.step)
      row.to, row.toDisplay = to, items.display(item, to)
    end
  end
  return out
end

-- Flattens a baseline into { ITEM = value }.
function M.values(result)
  local out = {}
  for _, c in ipairs(result.changes) do
    for _, r in ipairs(c.items) do out[r.name] = r.to end
  end
  return out
end

return M
