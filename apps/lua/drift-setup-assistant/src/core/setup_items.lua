-- F1: builds the list of setup items a car exposes, from its data/setup.ini
-- (MIN/MAX/STEP per item) and the values of the setup currently loaded.

local util = require('src/core/util')
local ini = require('src/core/ini')
local catalog = require('src/core/catalog')

local M = {}

-- setupIni: parsed car data/setup.ini (src/core/ini shape)
-- currentValues: { ITEM_NAME = number } from the loaded setup file, may be partial
-- overrides: manual item -> lever mappings
function M.build(setupIni, currentValues, overrides)
  local items = {}
  for _, name in ipairs(setupIni.order) do
    if not catalog.NON_ITEMS[name] then
      local s = setupIni.sections[name]
      local min, max, step = tonumber(s.values.MIN), tonumber(s.values.MAX), tonumber(s.values.STEP)
      local ratios = s.values.RATIOS
      local kind
      if ratios then kind = 'list'
      elseif min and max then kind = 'range'
      end
      if kind then
        local c = catalog.classify(name, overrides)
        local item = {
          name = name,
          label = s.values.NAME or name,
          tab = s.values.TAB,
          kind = kind,
          min = kind == 'range' and math.min(min, max) or 0,
          max = kind == 'range' and math.max(min, max) or nil,
          step = (step and step > 0) and step or 1,
          showClicks = s.values.SHOW_CLICKS == '1',
          ratiosFile = ratios,
          category = c.category,
          lever = c.lever,
          side = c.side,
          axle = c.axle,
          invert = c.invert,
          manual = c.manual,
        }
        local v = currentValues and currentValues[name]
        item.value = v and tonumber(v) or nil
        items[#items + 1] = item
      end
    end
  end
  return items
end

-- Reads { ITEM = value } out of a parsed setup file ([ITEM] VALUE=...).
function M.valuesFromSetup(setupFileIni)
  local out = {}
  for _, name in ipairs(setupFileIni.order) do
    local v = tonumber(ini.get(setupFileIni, name, 'VALUE'))
    if v then out[name] = v end
  end
  return out
end

function M.snap(item, value)
  if item.kind ~= 'range' then return util.round(value) end
  local steps = util.round((value - item.min) / item.step)
  local v = item.min + steps * item.step
  v = util.clamp(v, item.min, item.max)
  -- Kill float noise like 25.000000001 so the written file is clean.
  return util.round(v, 6)
end

function M.clicks(item, value)
  return util.round(((value or item.value or 0) - item.min) / item.step)
end

function M.display(item, value)
  value = value or item.value
  if value == nil then return '?' end
  if item.showClicks then return util.fmt(M.clicks(item, value), 0) .. ' clicks' end
  return util.fmt(value, 3)
end

-- Fraction of the range, 0 at MIN and 1 at MAX.
function M.fraction(item, value)
  value = value or item.value
  if item.kind ~= 'range' or value == nil or item.max == item.min then return nil end
  return (value - item.min) / (item.max - item.min)
end

-- Groups items by lever: { lever = { items = {...}, paired = bool } }.
function M.levers(items)
  local out = {}
  for _, item in ipairs(items) do
    if item.lever then
      local g = out[item.lever]
      if not g then g = { lever = item.lever, items = {} }; out[item.lever] = g end
      g.items[#g.items + 1] = item
    end
  end
  for _, g in pairs(out) do
    g.paired = #g.items > 1
    table.sort(g.items, function(a, b) return (a.side or a.name) < (b.side or b.name) end)
  end
  return out
end

function M.byName(items)
  local out = {}
  for _, item in ipairs(items) do out[item.name] = item end
  return out
end

function M.countByCategory(items)
  local out = {}
  for _, item in ipairs(items) do out[item.category] = (out[item.category] or 0) + 1 end
  return out
end

return M
