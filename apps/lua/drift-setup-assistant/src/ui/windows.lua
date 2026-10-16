-- The three app windows from manifest.ini: main, settings and the on-track HUD.

local K = require('src/ui/kit')
local coach = require('src/ui/coach')
local tabs = require('src/ui/tabs')
local profile = require('src/ui/profile')
local history = require('src/core/history')
local compat = require('src/game/compat')
local telemetry = require('src/game/telemetry')

local M = {}

local function blockers(app)
  if not app.versionOk then
    K.title('Custom Shaders Patch update needed')
    K.wrap(string.format('Drift Setup Assistant needs CSP %s or newer (build %d). You have build %d. Update CSP in Content Manager → Settings → Custom Shaders Patch.',
      compat.MIN_VERSION_LABEL, compat.MIN_VERSION_CODE, app.versionCode), K.C.warn)
    return true
  end
  if not app.rules then
    K.title('rules.json has problems')
    for _, e in ipairs(app.rulesErrors or {}) do K.bullet(e, K.C.bad) end
    K.muted('Fix the file in the app folder and restart the session.')
    return true
  end
  return false
end

function M.main(app, dt)
  if blockers(app) then return end
  if not profile.complete(app.profile) then
    profile.draw(app, true)
    return
  end

  local active = history.active(app.history)
  K.colored(app.car.name, K.C.text)
  ui.sameLine(0, 8)
  K.colored(app.track, K.C.muted)
  ui.sameLine(0, 8)
  K.colored(active and (active.n == 0 and 'your setup' or ('v' .. active.n)) or 'no setup yet', K.C.accent)

  local selected = app.tab
  app.tab = nil
  K.tabs('dsa_tabs', {
    { id = 'coach', label = 'Coach', fn = function() coach.draw(app) end },
    { id = 'setup', label = 'Setup', fn = function() tabs.setup(app) end },
    { id = 'history', label = 'History', fn = function() tabs.history(app) end },
    { id = 'learn', label = 'Learn', fn = function() tabs.learn(app) end },
  }, selected)
end

function M.settings(app, dt)
  if blockers(app) then return end
  K.heading('Driver profile')
  profile.draw(app, false)
  K.sep()

  K.heading('Preferences')
  local p = app.prefs
  local before = tostring(p.logging) .. tostring(p.hud) .. tostring(p.autoLoadDetect)
  p.logging = K.checkbox('Save CSV logs of each run in the app folder', p.logging)
  p.hud = K.checkbox('Show the on-track HUD', p.hud)
  p.autoLoadDetect = K.checkbox('Detect when I load a setup in the pits', p.autoLoadDetect)
  if before ~= tostring(p.logging) .. tostring(p.hud) .. tostring(p.autoLoadDetect) then app:savePrefs() end
  K.sep()

  K.heading('Diagnostics')
  K.muted('For the milestone 0 spike and bug reports.')
  local d = app:diagnostics()
  K.table({
    { 'CSP build', string.format('%d (minimum %d)', d.versionCode, d.minVersion) },
    { 'App folder', tostring(d.appDir) },
    { 'Setups folder', tostring(d.setupsDir) },
    { 'Current setup API', d.currentSetupVia and ('ac.INIConfig.' .. d.currentSetupVia) or 'not available', d.currentSetupVia and K.C.good or K.C.warn },
    { 'Setup load hook', d.setupHook and 'ac.onSetupFile' or 'not available', d.setupHook and K.C.good or K.C.warn },
    { 'Steering lock', d.steerLock and (d.steerLock .. '°') or 'unknown (learned while driving)' },
    { 'Rev limiter', d.ctx and d.ctx.rpmLimiter and tostring(d.ctx.rpmLimiter) or 'unknown' },
    { 'Ideal pressures', d.ctx and d.ctx.idealPressure and string.format('%s / %s', d.ctx.idealPressure.front, d.ctx.idealPressure.rear) or 'unknown' },
    { 'Bottoming limit', d.ctx and d.ctx.suspMaxTravel and 'from suspensions.ini' or 'unknown' },
    { 'Online (read-only)', tostring(d.readOnly) },
  }, 170)
  if d.probe then
    K.gap(4)
    K.colored('Car fields', K.C.text)
    local missing = {}
    for _, f in ipairs(telemetry.CAR_FIELDS) do if not d.probe.car[f] then missing[#missing + 1] = f end end
    K.small(#missing == 0 and 'All expected fields present.' or ('Missing: ' .. table.concat(missing, ', ')))
    K.colored('Wheel fields', K.C.text)
    for prefix, field in pairs(d.probe.wheel) do
      K.table({ { prefix, field or 'missing', field and K.C.good or K.C.bad } }, 120)
    end
  end
  K.gap(4)
  if K.button('Rescan car and setup', 180) then app:scan() end
  ui.sameLine(0, 6)
  if K.button('Write spike test file', 180) then app:writeSpikeFile() end
  if app.spike then
    if K.button('Verify loaded values', 180) then app:verifySpikeFile() end
    local r = app.spike.result
    if r and r.error then K.wrap(r.error, K.C.warn) end
    if r and r.rows then
      if #r.rows == 0 then
        K.colored('Every value loaded exactly as written.', K.C.good)
      else
        K.colored('Values that differ after loading (written → loaded):', K.C.bad)
        for _, row in ipairs(r.rows) do K.bullet(string.format('%s: %s → %s', row.label, row.fromDisplay, row.toDisplay)) end
      end
    end
  end
end

function M.hud(app, dt)
  if not app.rules or not app.versionOk or not app.prefs.hud then return end
  local st = app:status()
  if st.recording then
    K.colored(st.inDrift and '● REC  drifting' or '● REC', K.C.rec)
    local s = app.lastSample
    if s then K.text(string.format('%3.0f°   %3.0f km/h', math.abs(s.slip), s.speed)) end
    K.small(string.format('%.1fs drift · %d', st.driftTime, st.segments))
  elseif app.phase == 'feedback' then
    K.colored('Run done: open Drift Setup Assistant to rate it', K.C.accent)
  elseif app.saved and not app.saved.loaded then
    K.colored('Load ' .. app.saved.version.file .. ' in the pits', K.C.info)
  else
    K.colored('○ DSA ready', K.C.muted)
  end
end

return M
