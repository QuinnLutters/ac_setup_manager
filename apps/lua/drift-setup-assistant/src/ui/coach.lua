-- The Coach tab: the main loop. Live status, post-run feedback (F5), the
-- explain panel (F7), save (F8) and before/after (F9).

local K = require('src/ui/kit')
local glossary = require('src/core/glossary')
local history = require('src/core/history')
local util = require('src/core/util')

local M = {}

local END_REASONS = {
  spin = 'ended in a spin', stop = 'you stopped', timeout = '60 s without drifting',
  reset = 'car was reset', pits = 'you went to the pits', session_restart = 'session restarted', log_end = 'log ended',
}

local VERDICT_COLORS = { helped = 'good', worse = 'bad', unclear = 'warn', not_enough = 'muted' }

local function fmtMetric(v, unit, scale)
  if type(v) ~= 'number' then return '—' end
  return util.fmt(v * (scale or 1), 1) .. (unit or '')
end

local function liveStatus(app)
  local st = app:status()
  if st.recording then
    K.colored(st.inDrift and '● Recording: drifting' or '● Recording: waiting for the next drift', K.C.rec)
    K.small(string.format('Run time %ds · drifting %.1fs · %d drift%s', math.floor(st.runTime), st.driftTime,
      st.segments, st.segments == 1 and '' or 's'))
  else
    K.colored('○ Ready. Recording starts when you start drifting.', K.C.muted)
  end
end

local function savedPanel(app)
  local s = app.saved
  if not s or s.loaded then return end
  K.sep()
  K.heading('Saved as ' .. s.version.file)
  if s.verified then
    K.small('Checked: the file reads back with the values we wrote.')
  else
    K.colored('Warning: the file did not read back cleanly. Check it in the setup screen.', K.C.warn)
  end
  for _, r in ipairs(s.diff) do
    K.bullet(string.format('%s: %s → %s', r.label, r.fromDisplay, r.toDisplay))
  end
  K.gap(4)
  K.wrap('Load it now: go to the pits, open Setup, press Load and pick ' .. s.version.file .. '. Then drive another run.', K.C.info)
  if not app.setupHook then
    if K.primary("I've loaded it", 160, 26) then app:markLoaded(s.version.n) end
    K.small('This CSP build can\'t tell when you load a setup, so confirm it here.')
  else
    K.small('The app will notice when you load it.')
    if K.button("I've loaded it", 160) then app:markLoaded(s.version.n) end
  end
end

local function feedbackPrompt(app)
  local lr = app.lastRun
  local m = lr.metrics
  K.heading(string.format('Run %d finished (%s)', lr.id, END_REASONS[lr.run.endReason] or lr.run.endReason))
  K.table({
    { 'Drifting', string.format('%.1f s of %.0f s', m.driftTime or 0, m.totalTime or 0) },
    { 'Drifts', tostring(m.segments or 0) },
    { 'Average angle', fmtMetric(m.avgAngle, '°') },
    { 'Max angle', fmtMetric(m.maxAngle, '°') },
  }, 130)
  K.gap(6)
  -- Driver mistakes: say what was seen and let the driver overrule it.
  if lr.excluded then
    for _, x in ipairs(lr.mistakes or {}) do K.bullet(x.text, K.C.warn) end
    if #(lr.mistakes or {}) == 0 then K.bullet('You marked this run as your mistake.', K.C.warn) end
    K.wrap('This run won\'t count toward setup changes, because the problem was the driving, not the car.', K.C.warn)
    if K.button('Count it anyway', 150) then app:setRunExcluded(false) end
  else
    if K.button('My mistake, don\'t count this run', 260) then app:setRunExcluded(true) end
  end
  K.gap(8)
  K.colored('How did the car feel?', K.C.text)
  local opts = app:feedbackOptions()
  local w = math.max(110, (K.width() - 12) / 3)
  for i, o in ipairs(opts) do
    if (i - 1) % 3 ~= 0 then ui.sameLine(0, 4) end
    local clicked
    if o.id == 'felt_good' then clicked = K.primary(o.label, w, 30) else clicked = K.button(o.label, w, 30) end
    if clicked then app:submitFeedback({ o.id }) end
  end
  K.gap(4)
  if K.button('Skip', 80) then app:skipFeedback() end
  K.small('Optional. Your answer confirms what the telemetry saw.')
end

local function compareBlock(app, cmp)
  if not cmp or cmp.verdict == 'not_enough' then return end
  local v = cmp.version
  K.heading(string.format('Did v%d help?', v.n))
  for _, c in ipairs(history.changesOf(v)) do K.small('Change: ' .. (c.summary or c.label)) end
  K.wrap(cmp.text, K.C[VERDICT_COLORS[cmp.verdict]])
  for _, p in ipairs(cmp.primaries or {}) do
    if p.before then
      K.table({ { p.label, string.format('%s → %s', fmtMetric(p.before, nil), fmtMetric(p.after, nil)) } }, 200)
    end
  end
  for _, r in ipairs(cmp.rows) do
    local col = r.same and K.C.muted or (r.better and K.C.good or K.C.bad)
    K.table({ { r.label, string.format('%s → %s', fmtMetric(r.before, r.unit, r.scale), fmtMetric(r.after, r.unit, r.scale)), col } }, 200)
  end
  K.small(string.format('Based on %d run(s) before and %d after.', cmp.runsBefore, cmp.runsAfter))
  if cmp.verdict == 'worse' and v.parent ~= nil then
    local parent = history.get(app.history, v.parent)
    if K.primary('Revert to ' .. (parent and parent.n > 0 and ('v' .. parent.n) or 'previous setup'), 220, 26) then
      app:revertTo(v.parent)
    end
  end
  K.sep()
end

local function glossaryLink(app, id, key)
  local term = glossary.get(id)
  if not term then return end
  K.colored('Term: ' .. term.term, K.C.info)
  K.muted(term.short)
  if K.button('Learn more about ' .. term.term:lower() .. '##' .. (key or id), 0) then
    app.learnTerm = id
    app.tab = 'learn'
  end
end

-- One suggested fix: checkbox, what changes, why, what to feel (F7).
local function optionPanel(app, o)
  local label = o.summary .. '##' .. o.id
  if ui.checkbox(label, o.checked) then app:toggleOption(o.id) end
  local s = o.symptom
  local tag = o.primary and '' or 'Alternative · '
  K.small(string.format('%sFor: %s · confidence %s%s', tag, s.name, K.pct(s.confidence),
    s.confirmed and ', confirmed by you' or ''))
  if #o.alsoFor > 0 then K.small('Also helps: ' .. table.concat(o.alsoFor, ', ')) end
  if o.conflict then K.small('Moves the same setting the other way to the fix for ' .. o.conflict .. '. Pick one.') end
  if o.primary then
    for _, b in ipairs(o.blocked or {}) do K.small(b.text .. ' So this is the next-best fix.') end
  end
  for _, r in ipairs(o.plan.items) do
    if r.moved then K.bullet(string.format('%s: %s → %s', r.label, r.fromDisplay, r.toDisplay)) end
  end
  K.colored('Why it helps', K.C.text)
  K.wrap(o.why)
  K.colored('What to feel on the next run', K.C.text)
  K.wrap(o.feel)
  glossaryLink(app, o.glossary, o.id)
  K.gap(8)
end

local function changesPanel(app, rec)
  for _, l in ipairs(rec.limited or {}) do
    K.colored('Can\'t fix "' .. l.symptom.name .. '" with this car\'s setup', K.C.warn)
    for _, b in ipairs(l.blocked) do K.bullet(b.text, K.C.muted) end
    if l.advice then K.muted(l.advice) end
    K.gap(4)
  end

  K.heading('Suggested changes')
  K.muted('Tick the changes you want in the next version. Main fixes are ticked for you; alternatives are optional.')
  K.gap(4)
  local count = 0
  for _, o in ipairs(rec.options) do
    optionPanel(app, o)
    if o.checked then count = count + 1 end
  end

  local label = count == 1 and 'Save 1 change as new setup' or string.format('Save %d changes as new setup', count)
  if app.result.applied then
    K.colored('Saved as ' .. app.result.applied.file, K.C.good)
  else
    local ok, why = app:canWrite()
    if count == 0 then
      K.disabledButton(label, 240, 30, 'Tick at least one change.')
    elseif ok then
      if K.primary(label, 240, 30) then app:applyChanges() end
    else
      K.disabledButton(label, 240, 30, why)
      K.small(why)
    end
  end
end

local function otherSymptoms(result, shown)
  local others = {}
  for _, s in ipairs(result.diagnosis) do
    if not shown[s.id] and not s.fired and s.confidence >= 0.25 then others[#others + 1] = s end
  end
  if #others == 0 then return end
  K.sep()
  K.colored('Watching, but below threshold', K.C.muted)
  for _, s in ipairs(others) do
    K.text(s.name)
    K.bar(s.confidence, 220, 4, nil, K.C.muted)
  end
end

local function calibratingView(app, r)
  local h = app.history
  if h.start and h.start.version ~= h.activeN then
    local v = history.get(h, h.start.version)
    K.heading('Load your starting setup first')
    K.wrap(string.format('Runs only count once %s is loaded. Pits → Setup → Load.', v and v.file or 'the starting setup'), K.C.info)
    return
  end
  K.heading(string.format('Starting runs: %d of %d', r.count, r.needed))
  K.bar(r.count / r.needed, nil, 6, nil, K.C.accent)
  K.wrap(string.format('Drive %d more run%s on this setup. After %d runs the app looks at all of them together and suggests the first changes.',
    r.needed - r.count, r.needed - r.count == 1 and '' or 's', r.needed))
end

local function resultView(app)
  local r = app.result
  if r.kind == 'excluded' then
    K.heading('This run doesn\'t count')
    for _, x in ipairs(r.mistakes or {}) do K.bullet(x.text, K.C.warn) end
    K.muted('It\'s saved in the log, but not used for setup changes or comparisons. Drive another run.')
  elseif r.kind == 'calibrating' then
    calibratingView(app, r)
  else
    if r.evaluatedRuns and r.evaluatedRuns > 1 then
      K.colored(string.format('First evaluation, based on your %d starting runs together.', r.evaluatedRuns), K.C.info)
      K.gap(4)
    end
    compareBlock(app, r.compare)
    local rec = r.recommendation
    local shown = {}
    if rec.kind == 'changes' then
      for _, o in ipairs(rec.options) do shown[o.symptom.id] = true end
      changesPanel(app, rec)
      otherSymptoms(r, shown)
    elseif rec.kind == 'advice' then
      for _, l in ipairs(rec.limited) do
        K.heading(l.symptom.name)
        K.small('Confidence ' .. K.pct(l.symptom.confidence))
        for _, b in ipairs(l.blocked) do K.bullet(b.text, K.C.muted) end
        K.wrap(l.advice or 'This car can\'t make the usual changes for this.')
        glossaryLink(app, l.symptom.rule.glossary)
        K.gap(6)
      end
    elseif rec.kind == 'done' then
      K.heading('Your setup is dialled in')
      local active = history.active(app.history)
      K.wrap(string.format('You said the car felt good and no symptom is above its threshold. Your setup stays saved as %s.',
        active and (active.file or 'your current setup') or 'your current setup'), K.C.good)
      if active and active.n > 0 then
        local ok = app:canWrite()
        if ok and K.button('Also save a copy named "final"', 240) then app:saveFinalCopy() end
      end
    else
      K.heading('No clear problem on this run')
      K.muted('Keep driving. If something feels off, say so after the next run and the app will look at it.')
      otherSymptoms(r, shown)
    end
  end
  K.gap(6)
  if K.button('Dismiss', 90) then app.phase = 'idle' end
end

-- New car/track: start from the drift baseline or from the driver's own setup.
local function startChooser(app)
  K.heading('How do you want to start?')
  K.muted('Pick a starting point for this car and track. You\'ll drive 3 runs on it, then the app suggests the first changes.')
  K.gap(4)
  local ok, why = app:canWrite()
  if ok then
    if K.primary('Start from a drift baseline', 240, 28) then app:chooseStart('baseline') end
    K.small('The app builds a drift-ready setup from this car\'s ranges. Load it in the pits first.')
  else
    K.disabledButton('Start from a drift baseline', 240, 28, why)
  end
  K.gap(4)
  if K.button('Start from my current setup', 240, 28) then app:chooseStart('own') end
  K.small('Keep the setup you have loaded now.')
  K.sep()
end

local function baseChooser(app)
  local files = app:setupFiles()
  K.heading('Which setup are you running?')
  K.muted('This CSP build can\'t read the loaded setup directly. Pick the file you loaded in the pits, so the app knows your starting values.')
  if #files == 0 then
    K.muted('No saved setups found for this car. Save your setup in the pit setup screen first, then come back.')
  end
  for _, f in ipairs(files) do
    if K.button(f.name .. '  (' .. f.folder .. ')##' .. f.path, K.width()) then app:chooseBaseFile(f) end
  end
  K.sep()
end

function M.draw(app)
  for _, t in ipairs(app.toasts) do
    K.wrap(t.text, t.kind == 'error' and K.C.bad or K.C.info)
  end
  if app.readOnly then
    K.wrap('Online server: read-only mode. The app diagnoses and explains, but doesn\'t write setups.', K.C.warn)
  end
  if #(app.items or {}) == 0 then
    K.wrap('This car exposes no setup items, so the app can only diagnose and explain.', K.C.warn)
  elseif not next(app:activeValues()) then
    baseChooser(app)
  end

  if app:needsStartChoice() and #(app.items or {}) > 0 and next(app:activeValues()) then startChooser(app) end

  liveStatus(app)
  savedPanel(app)
  K.sep()

  if app.phase == 'feedback' and app.lastRun then
    feedbackPrompt(app)
  elseif app.phase == 'result' and app.result then
    resultView(app)
  else
    K.heading('How it works')
    K.bullet('Drive a run as normal. The app spots your drifts and records them.')
    K.bullet('Tell it how the car felt (one tap, or skip).')
    K.bullet('It recommends one setup change and explains why.')
    K.bullet('Save it, load it in the pits, and drive again to see if it helped.')
  end
end

return M
