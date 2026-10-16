-- Persistence: ac.storage for small preferences, JSON files in the app folder
-- for history, CSV files for session logs. No cloud, no accounts.

local compat = require('src/game/compat')
local json = require('src/core/json')
local csv = require('src/core/csv')
local util = require('src/core/util')

local M = {}

local memory = {}
local storage

local function kv()
  if storage then return storage end
  if ac.storage then
    local ok, s = pcall(ac.storage, { profile = '', prefs = '', overrides = '' })
    if ok and s then storage = s; return storage end
  end
  storage = memory
  return storage
end

local function getJson(key, default)
  local raw = kv()[key]
  if type(raw) ~= 'string' or raw == '' then return util.deepcopy(default) end
  local ok, v = pcall(json.decode, raw)
  if ok and type(v) == 'table' then return v end
  return util.deepcopy(default)
end

local function setJson(key, value)
  kv()[key] = json.encode(value)
end

M.DEFAULT_PREFS = { logging = true, hud = true, autoLoadDetect = true }

function M.loadProfile() return getJson('profile', nil) end
function M.saveProfile(p) setJson('profile', p) end

function M.loadPrefs()
  local p = getJson('prefs', {})
  for k, v in pairs(M.DEFAULT_PREFS) do if p[k] == nil then p[k] = v end end
  return p
end
function M.savePrefs(p) setJson('prefs', p) end

-- Manual "what is this item" mappings, per car.
function M.loadOverrides(carId)
  local all = getJson('overrides', {})
  return all[carId] or {}
end
function M.saveOverrides(carId, overrides)
  local all = getJson('overrides', {})
  all[carId] = overrides
  setJson('overrides', all)
end

-- History files --------------------------------------------------------------

local function safe(s) return (s:gsub('[^%w%-_%.]', '_')) end

function M.historyPath(carId, trackId)
  return compat.appDir() .. '/data/history/' .. safe(carId) .. '__' .. safe(trackId) .. '.json'
end

function M.loadHistory(carId, trackId)
  local text = compat.load(M.historyPath(carId, trackId))
  if not text then return nil end
  local ok, h = pcall(json.decode, text)
  if ok and type(h) == 'table' and h.versions then
    h.runs, h.blocked = h.runs or {}, h.blocked or {}
    return h
  end
  compat.log('history file unreadable, starting fresh:', M.historyPath(carId, trackId))
  return nil
end

function M.saveHistory(h)
  compat.mkdir(compat.appDir() .. '/data')
  compat.mkdir(compat.appDir() .. '/data/history')
  return compat.save(M.historyPath(h.car, h.track), json.encode(h, true))
end

-- Session logs ---------------------------------------------------------------

function M.newSessionLog(carId, trackId)
  local dir = compat.appDir() .. '/logs/' .. compat.dateStamp() .. '_' .. safe(carId) .. '_' .. safe(trackId)
  return { dir = dir, created = false, summary = {} }
end

local function ensure(log)
  if log.created then return true end
  compat.mkdir(compat.appDir() .. '/logs')
  log.created = compat.mkdir(log.dir)
  return log.created
end

function M.logRun(log, runId, samples)
  if not ensure(log) then return false end
  return compat.save(log.dir .. '/run_' .. runId .. '.csv', csv.encode(samples))
end

function M.logSummary(log, row)
  if not ensure(log) then return false end
  log.summary[#log.summary + 1] = row
  return compat.save(log.dir .. '/summary.csv', csv.encode(log.summary, csv.SUMMARY_COLUMNS))
end

return M
