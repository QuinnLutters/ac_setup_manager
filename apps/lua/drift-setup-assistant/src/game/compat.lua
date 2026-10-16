-- Thin layer over CSP APIs that differ between builds. Everything here checks
-- that a function exists before calling it, so an older CSP gets a clear
-- message instead of a Lua error. Items marked SPIKE are confirmed in milestone 0.

local M = {}

-- SPIKE: the minimum supported CSP build is an open question in the brief.
-- Placeholder until the spike confirms which build has every API used here.
M.MIN_VERSION_CODE = 2651
M.MIN_VERSION_LABEL = '0.2.0'

function M.versionCode()
  if ac.getPatchVersionCode then
    local ok, v = pcall(ac.getPatchVersionCode)
    if ok and type(v) == 'number' then return v end
  end
  return 0
end

function M.versionOk()
  return M.versionCode() >= M.MIN_VERSION_CODE
end

-- Reads a field from a CSP struct. Missing fields on cdata throw, so pcall.
function M.field(obj, key)
  if obj == nil then return nil end
  local ok, v = pcall(function() return obj[key] end)
  if ok then return v end
  return nil
end

function M.num(obj, key)
  local v = M.field(obj, key)
  if type(v) == 'number' then return v end
  return nil
end

function M.log(...)
  local parts = {}
  for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
  local msg = '[DSA] ' .. table.concat(parts, ' ')
  if ac.log then ac.log(msg) else print(msg) end
end

function M.debug(key, value)
  if ac.debug then pcall(ac.debug, key, value) end
end

-- File IO --------------------------------------------------------------------

function M.load(path)
  if io.load then
    local ok, text = pcall(io.load, path)
    if ok and text then return text end
  end
  local f = io.open(path, 'rb')
  if not f then return nil end
  local text = f:read('*a')
  f:close()
  return text
end

function M.save(path, text)
  if io.save then
    local ok, res = pcall(io.save, path, text)
    if ok and res ~= false then return true end
  end
  local f, err = io.open(path, 'wb')
  if not f then return false, err end
  f:write(text)
  f:close()
  return true
end

function M.fileExists(path)
  if io.fileExists then return io.fileExists(path) end
  local f = io.open(path, 'rb')
  if f then f:close(); return true end
  return false
end

function M.dirExists(path)
  if io.dirExists then return io.dirExists(path) end
  return M.fileExists(path)
end

function M.mkdir(path)
  if M.dirExists(path) then return true end
  if io.createDir then
    local ok, res = pcall(io.createDir, path)
    return ok and res ~= false
  end
  return false
end

-- Lists file names (not paths) in `dir` matching `mask` (e.g. '*.ini').
function M.scan(dir, mask)
  local out = {}
  if not io.scanDir or not M.dirExists(dir) then return out end
  local ok, res = pcall(io.scanDir, dir, mask or '*', function(name)
    out[#out + 1] = name
  end)
  if ok and type(res) == 'table' and #out == 0 then
    for _, name in ipairs(res) do out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

-- Folders ----------------------------------------------------------------------

function M.appDir()
  if __dirname then return __dirname end
  if ac.getFolder and ac.FolderID and ac.FolderID.ACApps then
    return ac.getFolder(ac.FolderID.ACApps) .. '/lua/drift-setup-assistant'
  end
  return '.'
end

-- SPIKE: confirm which FolderID points at Documents/Assetto Corsa/setups.
function M.setupsDir()
  if not ac.getFolder or not ac.FolderID then return nil end
  local candidates = {}
  if ac.FolderID.UserSetups then candidates[#candidates + 1] = ac.getFolder(ac.FolderID.UserSetups) end
  if ac.FolderID.Documents then
    local docs = ac.getFolder(ac.FolderID.Documents)
    candidates[#candidates + 1] = docs .. '/setups'
    candidates[#candidates + 1] = docs .. '/Assetto Corsa/setups'
  end
  for _, dir in ipairs(candidates) do
    if dir and M.dirExists(dir) then return dir end
  end
  return candidates[1]
end

function M.now()
  local ok, t = pcall(os.time)
  return ok and t or 0
end

function M.dateStamp()
  local ok, s = pcall(os.date, '%Y-%m-%d_%H-%M-%S')
  return ok and s or tostring(M.now())
end

-- Session info -------------------------------------------------------------------

function M.sim()
  return ac.getSim and ac.getSim() or nil
end

function M.isOnline()
  local sim = M.sim()
  return M.field(sim, 'isOnlineRace') == true
end

function M.isPaused()
  local sim = M.sim()
  return M.field(sim, 'isPaused') == true
end

function M.carId()
  if ac.getCarID then
    local ok, id = pcall(ac.getCarID, 0)
    if ok and id then return id end
  end
  return 'unknown_car'
end

function M.carName()
  if ac.getCarName then
    local ok, name = pcall(ac.getCarName, 0)
    if ok and name and name ~= '' then return name end
  end
  return M.carId()
end

function M.trackId()
  if ac.getTrackID then
    local ok, id = pcall(ac.getTrackID)
    if ok and id then return id end
  end
  return 'unknown_track'
end

-- Reads a car data file (works on packed data.acd). Returns CSP INIConfig or nil.
function M.carData(fileName)
  if not (ac.INIConfig and ac.INIConfig.carData) then return nil end
  local ok, cfg = pcall(ac.INIConfig.carData, 0, fileName)
  if ok and cfg and cfg.sections then return cfg end
  return nil
end

-- SPIKE: the brief names ac.INIConfig.currentSetup(); try it and a couple of
-- likely alternatives. Returns CSP INIConfig or nil.
function M.currentSetup()
  if not ac.INIConfig then return nil end
  for _, fnName in ipairs({ 'currentSetup', 'carSetup' }) do
    local fn = ac.INIConfig[fnName]
    if fn then
      local ok, cfg = pcall(fn, 0)
      if not ok then ok, cfg = pcall(fn) end
      if ok and cfg and cfg.sections and next(cfg.sections) then return cfg, fnName end
    end
  end
  return nil
end

function M.onSetupFile(callback)
  if ac.onSetupFile then
    local ok = pcall(ac.onSetupFile, callback)
    return ok
  end
  return false
end

function M.onSessionStart(callback)
  if ac.onSessionStart then pcall(ac.onSessionStart, callback) end
end

return M
