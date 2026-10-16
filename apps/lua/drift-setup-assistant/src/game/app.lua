-- The app controller: owns session state and runs the loop from the brief:
-- drive -> feedback -> diagnose -> recommend one change -> save -> load -> compare.
-- UI modules read this state and call its actions; they hold no logic.

local compat = require('src/game/compat')
local telemetry = require('src/game/telemetry')
local cardata = require('src/game/cardata')
local store = require('src/game/store')
local engine = require('src/core/engine')
local items = require('src/core/setup_items')
local history = require('src/core/history')
local setupfile = require('src/core/setupfile')
local compare = require('src/core/compare')
local baseline = require('src/core/baseline')
local catalog = require('src/core/catalog')
local mistakes = require('src/core/mistakes')
local metricsCore = require('src/core/metrics')
local recommend = require('src/core/recommend')
local util = require('src/core/util')

local App = {}
App.__index = App

App.VERSION = '0.1.0'

-- Metrics kept in history per run: every number and label, rounded, so the
-- calibration runs can be evaluated together later.
local function summarize(m)
  local out = {}
  for k, v in pairs(m) do
    if type(v) == 'number' then out[k] = util.round(v, 4)
    elseif type(v) == 'string' then out[k] = v end
  end
  return out
end

-- Feedback over several runs: every complaint counts; "felt good" only if
-- there were no complaints.
local function combineFeedback(lists)
  local seen, out, good = {}, {}, false
  for _, list in ipairs(lists) do
    for _, f in ipairs(list) do
      if f == 'felt_good' then good = true
      elseif not seen[f] then seen[f] = true; out[#out + 1] = f end
    end
  end
  if #out == 0 and good then out[1] = 'felt_good' end
  return out
end

local function sameValues(a, b)
  if not a or not b then return false end
  local compared = 0
  for k, v in pairs(a) do
    if b[k] ~= nil then
      compared = compared + 1
      if math.abs(b[k] - v) > 1e-6 then return false end
    end
  end
  return compared > 0
end

local function basename(path)
  return (tostring(path):match('([^/\\]+)$')) or tostring(path)
end

function App.new()
  local self = setmetatable({}, App)
  self.versionCode = compat.versionCode()
  self.versionOk = compat.versionOk()
  self.clock = 0
  self.sampleAcc = 0
  self.toasts = {}
  self.phase = 'idle'          -- 'idle' | 'feedback' | 'result'
  self.tab = nil               -- UI asks to switch tab, e.g. after a run
  self.prefs = store.loadPrefs()
  self.profile = store.loadProfile()
  -- Input device comes from the game's own controls settings, not a question.
  self.detectedDevice, self.detectedDeviceRaw = cardata.inputDevice()
  if self.profile and self.detectedDevice then self.profile.device = self.detectedDevice end
  self.readOnly = compat.isOnline()

  local rulesText = compat.load(compat.appDir() .. '/rules.json')
  if rulesText then
    self.rules, self.rulesErrors = engine.loadRules(rulesText)
  else
    self.rulesErrors = { 'rules.json not found in ' .. compat.appDir() }
  end
  if not self.rules then
    compat.log('rules.json problems:', table.concat(self.rulesErrors or {}, '; '))
    return self
  end

  self.recorder = engine.newRecorder(self.rules)
  self.sampleRate = (self.rules.detection and self.rules.detection.sampleRate) or 25
  self:scan()
  self.sessionLog = store.newSessionLog(self.car.id, self.track)
  self.setupHook = compat.onSetupFile(function(...) self:onSetupFileEvent(...) end)
  compat.onSessionStart(function() self:abortRun('session_restart') end)
  return self
end

function App:toast(text, kind)
  self.toasts[#self.toasts + 1] = { text = text, kind = kind or 'info', until_ = self.clock + 6 }
  compat.log(text)
end

-- F1: scan the car's setup items and the setup currently loaded --------------

function App:scan()
  self.car = { id = compat.carId(), name = compat.carName() }
  self.track = compat.trackId()
  self.overrides = store.loadOverrides(self.car.id)
  self.setupIni = cardata.setupIni()
  self.history = history.migrate(store.loadHistory(self.car.id, self.track) or history.new(self.car.id, self.track))

  local current, via = cardata.currentSetup()
  self.currentVia = via
  if current then
    self.baseIni = current
    self.values = items.valuesFromSetup(current)
    self:adoptValues(self.values, nil)
  else
    -- No API for the current setup: use the active version from history if any.
    local active = history.active(self.history)
    self.values = active and util.deepcopy(active.values) or {}
    if active and active.path then self.baseIni = cardata.readSetupFile(active.path) end
  end
  self:rebuildItems()
  self:buildContext()
end

-- Matches loaded values to a known version, or records them as the new base.
function App:adoptValues(values, fileName)
  local h = self.history
  if fileName then
    local v = history.findByFile(h, fileName)
    if v then history.setActive(h, v.n); return v end
  end
  local active = history.active(h)
  if active and sameValues(active.values, values) then return active end
  for i = #h.versions, 1, -1 do
    local v = h.versions[i]
    if sameValues(v.values, values) then history.setActive(h, v.n); return v end
  end
  local base = history.addBase(h, fileName or 'Current setup', values, compat.now())
  history.setActive(h, 0)
  store.saveHistory(h)
  return base
end

function App:activeValues()
  local active = history.active(self.history)
  return (active and active.values) or self.values or {}
end

function App:rebuildItems()
  if not self.setupIni then
    self.items, self.levers, self.itemsByName = {}, {}, {}
    return
  end
  self.items = items.build(self.setupIni, self:activeValues(), self.overrides)
  self.levers = items.levers(self.items)
  self.itemsByName = items.byName(self.items)
end

function App:buildContext()
  local car = ac.getCar and ac.getCar(0)
  local compound = self:activeValues().TYRES
  self.ctx = {
    rpmLimiter = car and cardata.rpmLimiter(car) or nil,
    idealPressure = cardata.idealPressure(compound),
    suspMaxTravel = cardata.suspMaxTravel(),
    steerNormalized = true,
  }
end

-- Live loop ------------------------------------------------------------------

function App:update(dt)
  if not self.rules or not self.versionOk then return end
  local now = self.clock
  for i = #self.toasts, 1, -1 do
    if self.toasts[i].until_ < now then table.remove(self.toasts, i) end
  end
  if dt <= 0 or compat.isPaused() then return end
  self.clock = self.clock + dt

  local car = ac.getCar(0)
  if not car then return end
  if not self.tele then self.tele = telemetry.newState(car) end
  self.ctx.steerNormalized = telemetry.steerNormalized(self.tele)

  -- Teleports (back to pits, session restart) end the current run.
  local pos = telemetry.position(car)
  if pos and self.lastPos then
    local dx, dy, dz = pos.x - self.lastPos.x, pos.y - self.lastPos.y, pos.z - self.lastPos.z
    if dx * dx + dy * dy + dz * dz > 40 * 40 then self:abortRun('reset') end
  end
  self.lastPos = pos and { x = pos.x, y = pos.y, z = pos.z } or nil

  if telemetry.inPits(car) then
    if self.recorder.state == 'running' then self:abortRun('pits') end
    self:checkLoadedSetup()
    return
  end

  self.sampleAcc = self.sampleAcc + dt
  local interval = 1 / self.sampleRate
  if self.sampleAcc >= interval then
    self.sampleAcc = math.min(self.sampleAcc - interval, interval)
    local s = telemetry.sample(car, self.clock, self.tele)
    self.lastSample = s
    local run = self.recorder:push(s)
    if run then self:onRunFinished(run) end
  end
end

function App:abortRun(reason)
  if not self.recorder then return end
  local run = self.recorder:abort(self.clock, reason)
  if run then self:onRunFinished(run) end
end

function App:status()
  if not self.recorder then return { recording = false } end
  return self.recorder:status(self.clock)
end

-- While stopped in the pits, notice when the driver loads a different setup.
function App:checkLoadedSetup()
  if not self.prefs.autoLoadDetect then return end
  if self.clock - (self.lastLoadCheck or -10) < 1.5 then return end
  self.lastLoadCheck = self.clock
  local current = cardata.currentSetup()
  if not current then return end
  local values = items.valuesFromSetup(current)
  local pending = self.saved and not self.saved.loaded and self.saved.version
  if pending and sameValues(values, pending.values) then
    self.baseIni = current
    history.setActive(self.history, pending.n)
    self:afterLoad(pending)
    return
  end
  if sameValues(values, self:activeValues()) then return end
  self.baseIni = current
  local v = self:adoptValues(values, nil)
  self:afterLoad(v)
end

function App:onSetupFileEvent(arg)
  local name = type(arg) == 'string' and basename(arg) or nil
  local current = cardata.currentSetup()
  local values = current and items.valuesFromSetup(current)
  if current then self.baseIni = current end
  local v
  if name then v = history.findByFile(self.history, name) end
  if v then
    history.setActive(self.history, v.n)
  elseif values then
    v = self:adoptValues(values, name)
  end
  if v then self:afterLoad(v) end
end

function App:afterLoad(v)
  self:rebuildItems()
  self:buildContext()
  store.saveHistory(self.history)
  if v.kind == 'base' then
    self:toast('Now driving your own setup (' .. (v.file or 'current') .. ').')
  else
    self:toast(string.format('Now driving v%d (%s). Your next run is compared with the previous version.', v.n, v.file))
  end
  if self.saved and self.saved.version.n == v.n then self.saved.loaded = true end
end

-- After a run: feedback, diagnosis, recommendation -----------------------------

function App:onRunFinished(run)
  -- An unanswered feedback prompt from the previous run is skipped.
  if self.phase == 'feedback' then self:finishRun(nil) end
  local m = engine.analyzeRun(self.rules, run, self.ctx)
  local found = mistakes.detect(run, self.rules.mistakes)
  self.lastRun = { run = run, metrics = m, id = run.id, version = self.history.activeN,
    mistakes = found, excluded = #found > 0 }
  self.phase = 'feedback'
  self.tab = 'coach'
  if self.prefs.logging then store.logRun(self.sessionLog, run.id, run.samples) end
end

function App:feedbackOptions()
  return engine.feedbackOptions(self.rules, self.profile)
end

-- "My mistake" / "Count it anyway" on the run waiting for feedback.
function App:setRunExcluded(excluded)
  if self.lastRun then self.lastRun.excluded = excluded end
end

function App:submitFeedback(ids) self:finishRun(ids or {}) end
function App:skipFeedback() self:finishRun({}) end

function App:finishRun(feedback)
  local lr = self.lastRun
  if not lr then return end
  feedback = feedback or {}
  local m = lr.metrics
  local h = self.history
  local kinds = {}
  for _, x in ipairs(lr.mistakes or {}) do kinds[#kinds + 1] = x.kind end
  if h.activeN ~= nil then
    history.addRun(h, h.activeN, summarize(m), feedback, compat.now(), { excluded = lr.excluded, mistakes = lr.mistakes })
  end
  self.phase = 'result'
  local function finish(result)
    result.runId, result.feedback, result.metrics, result.mistakes = lr.id, feedback, m, lr.mistakes
    self.result = result
    store.saveHistory(h)
    if self.prefs.logging then
      local row = summarize(m)
      row.run, row.version, row.endReason = lr.id, h.activeN, lr.run.endReason
      row.feedback = table.concat(feedback, '|')
      row.mistakes = (lr.excluded and 'excluded:' or '') .. table.concat(kinds, '|')
      local rec = result.recommendation
      local top = rec and rec.options and rec.options[1]
      row.topSymptom = top and top.symptom.id or (rec and rec.kind) or result.kind
      store.logSummary(self.sessionLog, row)
    end
  end

  -- Driver mistakes: logged, but not used for tuning.
  if lr.excluded then
    finish({ kind = 'excluded' })
    return
  end

  -- First evaluation waits for enough runs on the starting setup, then looks at them together.
  local evaluated = 1
  if not h.calibrated then
    local count, needed, n = history.calibration(h)
    if count < needed or h.start == nil then
      finish({ kind = 'calibrating', count = count, needed = needed, startVersion = n })
      return
    end
    local list, fbs = {}, {}
    for _, r in ipairs(history.runsFor(h, n)) do
      list[#list + 1] = r.metrics
      fbs[#fbs + 1] = r.feedback or {}
    end
    m = metricsCore.aggregate(list)
    feedback = combineFeedback(fbs)
    evaluated = #list
    h.calibrated = true
  end

  local d = engine.diagnose(self.rules, m, feedback, self.profile)

  -- F9: compare the active version with its parent once both have runs.
  local cmp
  local active = history.active(h)
  if active and active.parent ~= nil then
    local targets = {}
    for _, c in ipairs(history.changesOf(active)) do
      for _, rule in ipairs(self.rules.symptoms) do
        if rule.id == c.symptomId then targets[#targets + 1] = rule end
      end
    end
    cmp = compare.compare(self.rules, history.metricsFor(h, active.parent), history.metricsFor(h, active.n),
      targets, history.feedbackFor(h, active.n))
    cmp.version = active
    if cmp.verdict ~= 'not_enough' and active.verdict ~= 'reverted' then
      history.setVerdict(h, active.n, cmp.verdict)
    end
  end

  local rec = engine.recommend(self.rules, d, self.levers, {
    history = { lastChanges = history.lastChanges(h), isBlocked = history.isBlockedFn(h) },
    metrics = m, profile = self.profile, feedback = feedback,
  })
  finish({ kind = 'evaluated', diagnosis = d, recommendation = rec, compare = cmp, evaluatedRuns = evaluated })
end

-- How to begin on a new car/track: 'baseline' writes the starter drift
-- baseline to load first; 'own' starts from the setup that's loaded now.
function App:chooseStart(mode)
  local h = self.history
  if mode == 'baseline' then
    local v = self:saveBaseline()
    if not v then return end
    history.setStart(h, 'baseline', v.n, 3)
  else
    history.setStart(h, 'own', h.activeN or 0, 3)
  end
  store.saveHistory(h)
end

function App:needsStartChoice()
  return self.history.start == nil
end

-- F8: save the recommendation as a new versioned setup file --------------------

function App:canWrite()
  if self.readOnly then return false, 'Online server: read-only mode, the app explains but doesn\'t write setups.' end
  if not compat.setupsDir() then return false, 'Couldn\'t find your Documents/Assetto Corsa/setups folder.' end
  if not self.setupIni then return false, 'This car exposes no setup items.' end
  return true
end

function App:writeVersion(meta, newValues, headerLines)
  local ok, why = self:canWrite()
  if not ok then self:toast(why, 'error'); return nil end
  local h = self.history
  local root = compat.setupsDir()
  compat.mkdir(root .. '/' .. self.car.id)
  local folder = cardata.trackFolder(self.car.id, self.track)
  compat.mkdir(folder)
  local existing = compat.scan(folder, '*.ini')
  local name, n = setupfile.nextFileName(self.car.id, existing, history.maxN(h) + 1)
  local path = folder .. '/' .. name
  if compat.fileExists(path) then
    self:toast('Refusing to overwrite ' .. name, 'error')
    return nil
  end
  local text = setupfile.build(self.baseIni, newValues, self.car.id, headerLines)
  local saved, err = compat.save(path, text)
  if not saved then
    self:toast('Couldn\'t write ' .. path .. ': ' .. tostring(err), 'error')
    return nil
  end

  -- Load-and-read check: the file on disk must parse back to the same values.
  local back = cardata.readSetupFile(path)
  local verified = back and sameValues(items.valuesFromSetup(back), newValues) or false

  local parentN = h.activeN
  local parentValues = self:activeValues()
  meta.n, meta.file, meta.path, meta.parent, meta.values = n, name, path, parentN, newValues
  local v = history.addVersion(h, meta, compat.now())
  store.saveHistory(h)
  self.saved = {
    version = v,
    diff = setupfile.diff(parentValues, newValues, self.itemsByName),
    path = path,
    verified = verified,
    loaded = false,
  }
  return v
end

function App:toggleOption(id)
  local rec = self.result and self.result.recommendation
  if rec then recommend.toggle(rec, id) end
end

-- F8: writes every ticked change into one new version.
function App:applyChanges()
  local rec = self.result and self.result.recommendation
  if not rec or rec.kind ~= 'changes' then return end
  local picked = recommend.checked(rec)
  if #picked == 0 then return end
  local newValues = util.deepcopy(self:activeValues())
  local changes = {}
  local active = history.active(self.history)
  local header = {
    string.format('Drift Setup Assistant %s - %s', App.VERSION, self.car.id),
    'Based on: ' .. (active and (active.file or 'current setup') or 'current setup'),
  }
  for _, o in ipairs(picked) do
    for _, row in ipairs(o.plan.items) do
      if row.moved then newValues[row.name] = row.to end
    end
    changes[#changes + 1] = { lever = o.plan.lever, direction = o.plan.direction, label = o.plan.label,
      directionLabel = o.plan.directionLabel, summary = o.summary, symptomId = o.symptom.id, symptomName = o.symptom.name }
    header[#header + 1] = 'Change: ' .. o.summary .. ' (for: ' .. o.symptom.name .. ')'
  end
  local v = self:writeVersion({ kind = 'change', changes = changes }, newValues, header)
  if v then self.result.applied = v end
  return v
end

-- The driver confirms they loaded a version in the pit setup screen.
function App:markLoaded(n)
  local v = history.get(self.history, n)
  if not v then return end
  history.setActive(self.history, n)
  if v.path then self.baseIni = cardata.readSetupFile(v.path) or self.baseIni end
  self:afterLoad(v)
end

-- F12: revert to an earlier version. Blocks the changes in between.
function App:revertTo(n)
  local h = self.history
  local target = history.get(h, n)
  if not target then return end
  history.revert(h, n)
  -- The driver's own file might be unknown ("Current setup"); write a copy then.
  if target.kind == 'base' and not (target.path or self:findOwnFile(target.file)) then
    local v = self:writeVersion({ kind = 'revert', revertOf = n }, util.deepcopy(target.values), {
      'Drift Setup Assistant - revert to your original setup' })
    if v then
      self:toast(string.format('Reverted. Load %s in the pit setup screen.', v.file))
      return
    end
  end
  self:rebuildItems()
  store.saveHistory(h)
  self.saved = nil
  self:toast(string.format('Reverted. Load %s in the pit setup screen.', target.file or 'your original setup'))
end

function App:findOwnFile(name)
  if not name then return nil end
  for _, f in ipairs(cardata.listSetupFiles(self.car.id, self.track)) do
    if f.name == name then return f.path end
  end
  return nil
end

-- F10: starter baseline ---------------------------------------------------------

function App:previewBaseline()
  self.baselinePreview = baseline.generate(self.rules, self.levers)
  return self.baselinePreview
end

function App:saveBaseline()
  local b = self.baselinePreview or self:previewBaseline()
  local newValues = util.deepcopy(self:activeValues())
  for k, v in pairs(baseline.values(b)) do newValues[k] = v end
  return self:writeVersion({ kind = 'baseline' }, newValues, {
    'Drift Setup Assistant - starter drift baseline for ' .. self.car.id })
end

-- Loop end: keep the final setup under its own name.
function App:saveFinalCopy()
  local ok, why = self:canWrite()
  if not ok then self:toast(why, 'error'); return end
  local folder = cardata.trackFolder(self.car.id, self.track)
  local existing = {}
  for _, f in ipairs(compat.scan(folder, '*.ini')) do existing[f:lower()] = true end
  local name, i = setupfile.PREFIX .. self.car.id .. '_final.ini', 1
  while existing[name:lower()] do
    i = i + 1
    name = setupfile.PREFIX .. self.car.id .. '_final_' .. i .. '.ini'
  end
  local text = setupfile.build(self.baseIni, self:activeValues(), self.car.id, { 'Drift Setup Assistant - final setup' })
  if compat.save(folder .. '/' .. name, text) then self:toast('Saved your final setup as ' .. name) end
end

-- Base setup selection when CSP can't report the current setup --------------------

function App:setupFiles()
  return cardata.listSetupFiles(self.car.id, self.track)
end

function App:chooseBaseFile(file)
  local parsed = cardata.readSetupFile(file.path)
  if not parsed then self:toast('Couldn\'t read ' .. file.name, 'error'); return end
  self.baseIni = parsed
  self.values = items.valuesFromSetup(parsed)
  local v = self:adoptValues(self.values, file.name)
  if v and not v.path then v.path = file.path end
  self:afterLoad(v)
end

-- Profile, overrides, prefs ----------------------------------------------------

function App:saveProfile(p)
  if self.detectedDevice then p.device = self.detectedDevice end
  self.profile = p
  store.saveProfile(p)
end

function App:setOverride(itemName, lever)
  self.overrides[itemName] = lever and { lever = lever } or nil
  store.saveOverrides(self.car.id, self.overrides)
  self:rebuildItems()
end

function App:savePrefs()
  store.savePrefs(self.prefs)
end

-- Spike tools (milestone 0) ---------------------------------------------------------

function App:diagnostics()
  local car = ac.getCar and ac.getCar(0)
  return {
    versionCode = self.versionCode,
    minVersion = compat.MIN_VERSION_CODE,
    appDir = compat.appDir(),
    setupsDir = compat.setupsDir(),
    currentSetupVia = self.currentVia,
    setupHook = self.setupHook,
    probe = car and telemetry.probe(car) or nil,
    steerLock = self.tele and self.tele.steerLock,
    ctx = self.ctx,
    itemCount = #(self.items or {}),
    readOnly = self.readOnly,
    inputDevice = self.detectedDevice,
    inputDeviceRaw = self.detectedDeviceRaw,
  }
end

-- Writes a copy of the active values with no changes, to confirm the game loads it.
function App:writeSpikeFile()
  local ok, why = self:canWrite()
  if not ok then self:toast(why, 'error'); return end
  local folder = cardata.trackFolder(self.car.id, self.track)
  compat.mkdir(compat.setupsDir() .. '/' .. self.car.id)
  compat.mkdir(folder)
  local name = setupfile.PREFIX .. self.car.id .. '_spiketest.ini'
  local text = setupfile.build(self.baseIni, self:activeValues(), self.car.id, { 'Drift Setup Assistant spike test file' })
  if compat.save(folder .. '/' .. name, text) then
    self.spike = { file = name, values = util.deepcopy(self:activeValues()) }
    self:toast('Wrote ' .. name .. '. Load it in the pits, then press "Verify loaded values".')
  end
end

-- Compares what the game reports as loaded with what we wrote, item by item.
function App:verifySpikeFile()
  if not self.spike then return end
  local current = cardata.currentSetup()
  if not current then
    self.spike.result = { error = 'This CSP build can\'t report the current setup, so check the values by eye in the setup screen.' }
    return
  end
  local loaded = items.valuesFromSetup(current)
  self.spike.result = { rows = setupfile.diff(self.spike.values, loaded, self.itemsByName) }
end

return App
