local ini = require('src/core/ini')
local items = require('src/core/setup_items')
local engine = require('src/core/engine')

local M = {}

M.ROOT = 'spec/fixtures/'
M.APP = 'apps/lua/drift-setup-assistant/'

function M.read(path)
  local f = assert(io.open(path, 'rb'))
  local text = f:read('*a')
  f:close()
  return text
end

function M.rules()
  local rules, errs = engine.loadRules(M.read(M.APP .. 'rules.json'))
  assert(rules, errs and table.concat(errs, '\n'))
  return rules
end

-- Returns items, leverGroups, values for a fixture car.
function M.car(name, currentFile)
  local setupIni = ini.parse(M.read(M.ROOT .. 'cars/' .. name .. '/setup.ini'))
  local values = {}
  if currentFile ~= false then
    local ok, text = pcall(M.read, M.ROOT .. 'cars/' .. name .. '/' .. (currentFile or 'current_setup.ini'))
    if ok then values = items.valuesFromSetup(ini.parse(text)) end
  end
  local list = items.build(setupIni, values)
  return list, items.levers(list), values
end

-- Locked pack has no current file; give it mid-range values.
function M.lockedPack()
  local setupIni = ini.parse(M.read(M.ROOT .. 'cars/locked_pack/setup.ini'))
  local values = { PRESSURE_LF = 28, PRESSURE_RF = 28, PRESSURE_LR = 40, PRESSURE_RR = 40, FUEL = 20 }
  local list = items.build(setupIni, values)
  return list, items.levers(list), values
end

M.CTX = {
  rpmLimiter = 8000,
  idealPressure = { front = 26, rear = 28 },
  suspMaxTravel = { FL = 0.1, FR = 0.1, RL = 0.1, RR = 0.1 },
  steerNormalized = true,
}

return M
