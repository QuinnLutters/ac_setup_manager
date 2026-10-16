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
  if v.change then K.small('Change: ' .. (v.change.summary or v.change.label)) end
  K.wrap(cmp.text, K.C[VERDICT_COLORS[cmp.verdict]])
  if cmp.primary and cmp.primary.before then
    K.table({ { cmp.primary.label, string.format('%s → %s', fmtMetric(cmp.primary.before, nil), fmtMetric(cmp.primary.after, nil)) } }, 200)
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

local function glossaryLink(app, id)
  local term = glossary.get(id)
  if not term then return end
  K.colored('Term: ' .. term.term, K.C.info)
  K.muted(term.short)
  if K.button('Learn more about ' .. term.term:lower(), 0) then
    app.learnTerm = id
    app.tab = 'learn'
  end
end

local function explainPanel(app, rec)
  local s = rec.symptom
  for _, l in ipairs(rec.limited or {}) do
    K.colored('Can\'t fix "' .. l.symptom.name .. '" with this car\'s setup', K.C.warn)
    for _, b in ipairs(l.blocked) do K.bullet(b.text, K.C.muted) end
    if l.advice then K.muted(l.advice) end
    K.gap(4)
  end

  K.heading(s.name)
  K.small(string.format('Confidence %s%s', K.pct(s.confidence), s.confirmed and ' · confirmed by you' or ' · from telemetry'))
  K.bar(s.confidence, nil, 4, nil, K.C.accent)
  K.gap(6)

  if #rec.blocked > 0 then
    for _, b in ipairs(rec.blocked) do K.bullet(b.text, K.C.muted) end
    K.muted('So the app picked the next-best change:')
  end

  K.colored('What changes', K.C.text)
  for _, r in ipairs(rec.plan.items) do
    if r.moved then
      K.bullet(string.format('%s: %s → %s', r.label, r.fromDisplay, r.toDisplay))
    end
  end
  K.small(rec.plan.label .. ' ' .. rec.plan.directionLabel .. (rec.plan.paired and ', left and right together' or ''))
  K.gap(4)
  K.colored('Why it helps', K.C.text)
  K.wrap(rec.why)
  K.gap(4)
  K.colored('What to feel on the next run', K.C.text)
  K.wrap(rec.feel)
  K.gap(4)
  glossaryLink(app, rec.glossary)
  K.gap(8)

  if app.result.applied then
    K.colored('Saved as ' .. app.result.applied.file, K.C.good)
  else
    local ok, why = app:canWrite()
    if ok then
      if K.primary('Save as new setup', 200, 30) then app:applyRecommendation() end
    else
      K.disabledButton('Save as new setup', 200, 30, why)
      K.small(why)
    end
  end
end

local function otherSymptoms(result, shownId)
  local others = {}
  for _, s in ipairs(result.diagnosis) do
    if s.id ~= shownId and (s.fired or s.confidence >= 0.25) then others[#others + 1] = s end
  end
  if #others == 0 then return end
  K.sep()
  K.colored('Also noticed', K.C.muted)
  for _, s in ipairs(others) do
    K.text(s.name .. (s.fired and '' or ' (below threshold)'))
    K.bar(s.confidence, 220, 4, nil, s.fired and K.C.warn or K.C.muted)
  end
  K.small('One change at a time: these are looked at again after your next run.')
end

local function resultView(app)
  local r = app.result
  compareBlock(app, r.compare)
  local rec = r.recommendation
  if rec.kind == 'change' then
    explainPanel(app, rec)
    otherSymptoms(r, rec.symptom.id)
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
    otherSymptoms(r, nil)
  end
  K.gap(6)
  if K.button('Dismiss', 90) then app.phase = 'idle' end
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
