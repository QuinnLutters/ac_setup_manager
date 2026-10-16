-- Read-only access to the car's data files and the driver's setup files.
-- Car data files are never written (editing physics files is out of scope).

local compat = require('src/game/compat')
local ini = require('src/core/ini')

local M = {}

-- Parsed data/setup.ini, or nil if the car exposes none.
function M.setupIni()
  local cfg = compat.carData('setup.ini')
  if not cfg then return nil end
  return ini.fromCspSections(cfg.sections)
end

local function firstNumber(cfg, section, key)
  local sec = cfg and cfg.sections[section]
  local v = sec and sec[key]
  if type(v) == 'table' then v = v[1] end
  return tonumber(v)
end

-- Ideal hot pressures from tyres.ini for the given compound index (0-based).
function M.idealPressure(compoundIndex)
  local cfg = compat.carData('tyres.ini')
  if not cfg then return nil end
  local suffix = (compoundIndex and compoundIndex > 0) and ('_' .. compoundIndex) or ''
  local front = firstNumber(cfg, 'FRONT' .. suffix, 'PRESSURE_IDEAL')
  local rear = firstNumber(cfg, 'REAR' .. suffix, 'PRESSURE_IDEAL')
  if front and rear then return { front = front, rear = rear } end
  return nil
end

-- SPIKE: PACKER_RANGE is the travel before the packers, in metres. Treat it as
-- the bottoming limit when present; 0 means "no packers" and gives no limit.
function M.suspMaxTravel()
  local cfg = compat.carData('suspensions.ini')
  if not cfg then return nil end
  local f, r = firstNumber(cfg, 'FRONT', 'PACKER_RANGE'), firstNumber(cfg, 'REAR', 'PACKER_RANGE')
  if not f or not r or f <= 0 or r <= 0 then return nil end
  return { FL = f, FR = f, RL = r, RR = r }
end

function M.rpmLimiter(car)
  local v = compat.num(car, 'rpmLimiter')
  if v and v > 0 then return v end
  local cfg = compat.carData('engine.ini')
  return firstNumber(cfg, 'ENGINE_DATA', 'LIMITER')
end

-- Setups folders for this car: track-specific first, then generic.
function M.setupFolders(carId, trackId)
  local root = compat.setupsDir()
  if not root then return {} end
  return {
    { label = trackId, path = root .. '/' .. carId .. '/' .. trackId },
    { label = 'generic', path = root .. '/' .. carId .. '/generic' },
  }
end

function M.trackFolder(carId, trackId)
  local root = compat.setupsDir()
  return root and (root .. '/' .. carId .. '/' .. trackId) or nil
end

-- Lists { name, path, folder } for every .ini setup file the driver has for this car.
function M.listSetupFiles(carId, trackId)
  local out = {}
  for _, folder in ipairs(M.setupFolders(carId, trackId)) do
    for _, name in ipairs(compat.scan(folder.path, '*.ini')) do
      out[#out + 1] = { name = name, path = folder.path .. '/' .. name, folder = folder.label }
    end
  end
  return out
end

function M.readSetupFile(path)
  local text = compat.load(path)
  if not text then return nil end
  return ini.parse(text)
end

-- The setup the car is running right now, if the CSP build can tell us.
function M.currentSetup()
  local cfg, via = compat.currentSetup()
  if not cfg then return nil end
  return ini.fromCspSections(cfg.sections), via
end

return M
