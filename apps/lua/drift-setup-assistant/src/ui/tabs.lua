-- Setup (F1 + F10), History (F12) and Learn (F11) tabs.

local K = require('src/ui/kit')
local catalog = require('src/core/catalog')
local items = require('src/core/setup_items')
local glossary = require('src/core/glossary')
local history = require('src/core/history')
local diagram = require('src/ui/diagram')
local util = require('src/core/util')

local M = {}

local mapping = nil      -- item name being mapped by the manual mapper
local mappingCategory = nil

local function mapper(app, item)
  K.muted('What is "' .. item.label .. '"? Pick what it adjusts, or leave it unknown.')
  local cats = {}
  for _, c in ipairs(catalog.CATEGORIES) do
    if c ~= 'unknown' and c ~= 'other' then cats[#cats + 1] = { id = c, label = catalog.CATEGORY_LABELS[c] } end
  end
  mappingCategory = K.choice({ cats[1], cats[2], cats[3], cats[4] }, mappingCategory)
  mappingCategory = K.choice({ cats[5], cats[6], cats[7], cats[8] }, mappingCategory)
  if mappingCategory then
    for _, l in ipairs(catalog.leverChoices()) do
      if l.category == mappingCategory and K.button(l.label .. '##map' .. l.lever, 220) then
        app:setOverride(item.name, l.lever)
        mapping, mappingCategory = nil, nil
      end
    end
  end
  if K.button('Cancel##map', 80) then mapping, mappingCategory = nil, nil end
  ui.sameLine(0, 6)
  if item.manual and K.button('Clear mapping', 120) then
    app:setOverride(item.name, nil)
    mapping, mappingCategory = nil, nil
  end
end

function M.setup(app)
  local list = app.items or {}
  K.heading(string.format('%s exposes %d setup item%s', app.car.name, #list, #list == 1 and '' or 's'))
  local counts = items.countByCategory(list)
  if (counts.unknown or 0) > 0 then
    K.muted(counts.unknown .. ' item(s) aren\'t recognised. Map them below if you know what they do.')
  end
  for _, cat in ipairs(catalog.CATEGORIES) do
    local inCat = {}
    for _, item in ipairs(list) do if item.category == cat then inCat[#inCat + 1] = item end end
    if #inCat > 0 then
      K.sep()
      K.colored(catalog.CATEGORY_LABELS[cat], cat == 'unknown' and K.C.warn or K.C.accent)
      for _, item in ipairs(inCat) do
        ui.text(item.label)
        ui.sameLine(200)
        ui.text(items.display(item))
        ui.sameLine(300)
        if item.kind == 'range' then
          K.colored(string.format('%s – %s, step %s', util.fmt(item.min, 3), util.fmt(item.max, 3), util.fmt(item.step, 3)), K.C.muted)
        else
          K.colored('ratio list (' .. tostring(item.ratiosFile) .. ')', K.C.muted)
        end
        if cat == 'unknown' or item.manual then
          ui.sameLine(0, 8)
          if K.button((item.manual and 'Remap' or 'What is this?') .. '##' .. item.name) then mapping = item.name end
        end
        if mapping == item.name then mapper(app, item) end
      end
    end
  end

  -- F10 starter baseline.
  K.sep()
  K.heading('Starter drift baseline')
  K.muted('Not sure where to start? Generate a drift baseline from this car\'s own ranges, then tune from there.')
  if K.button('Generate baseline', 160) then app:previewBaseline() end
  local b = app.baselinePreview
  if b then
    for _, c in ipairs(b.changes) do
      local r = c.items[1]
      K.bullet(string.format('%s: %s → %s', c.label, r.fromDisplay, r.toDisplay))
      K.small(c.why)
    end
    if #b.skipped > 0 then
      local names = {}
      for _, s in ipairs(b.skipped) do names[#names + 1] = s.label end
      K.small('Not adjustable on this car: ' .. table.concat(names, ', '))
    end
    local ok, why = app:canWrite()
    if ok then
      if K.primary('Save baseline as new setup', 220, 28) then app:saveBaseline(); app.tab = 'coach' end
    else
      K.disabledButton('Save baseline as new setup', 220, 28, why)
    end
  end
end

local KIND_LABELS = { base = 'your setup', change = 'change', baseline = 'baseline', revert = 'revert copy' }
local VERDICTS = { helped = { 'helped', 'good' }, worse = { 'made it worse', 'bad' }, unclear = { 'no clear change', 'warn' },
  reverted = { 'reverted', 'muted' } }

function M.history(app)
  local h = app.history
  K.heading(string.format('%s at %s', app.car.name, app.track))
  if #h.versions == 0 then K.muted('No versions yet.') return end
  K.muted('Newest first. Load a version in the pit setup screen to drive it.')
  for i = #h.versions, 1, -1 do
    local v = h.versions[i]
    K.sep()
    local active = h.activeN == v.n
    K.colored(string.format('%s  %s%s', v.n == 0 and 'Base' or ('v' .. v.n), v.file or 'current setup',
      active and '  · driving now' or ''), active and K.C.accent or K.C.text)
    local line = KIND_LABELS[v.kind] or v.kind
    if v.change then line = line .. ': ' .. (v.change.summary or v.change.label) end
    if v.symptomName then line = line .. ' (for: ' .. v.symptomName .. ')' end
    K.small(line)
    local runs = #history.runsFor(h, v.n)
    local verdict = v.verdict and VERDICTS[v.verdict]
    K.small(string.format('%d run%s', runs, runs == 1 and '' or 's'))
    if verdict then ui.sameLine(0, 8); K.colored(verdict[1], K.C[verdict[2]]) end
    if not active then
      if K.button('Revert to this##' .. v.n, 130) then app:revertTo(v.n) end
      ui.sameLine(0, 6)
      if K.button("I've loaded this##" .. v.n, 130) then app:markLoaded(v.n) end
    end
  end
end

function M.learn(app)
  K.heading('Drift and setup glossary')
  K.muted('Plain-language explanations of the terms the app uses.')
  local focus = app.learnTerm
  for _, t in ipairs(glossary.terms) do
    K.sep()
    K.colored(t.term, focus == t.id and K.C.accent or K.C.text)
    K.wrap(t.short)
    if focus == t.id then
      K.muted(t.body)
      if t.diagram then diagram.draw(t.diagram, 140) end
      if K.button('Close##' .. t.id, 70) then app.learnTerm = nil end
    elseif K.button('Explain##' .. t.id, 70) then
      app.learnTerm = t.id
    end
  end
end

return M
