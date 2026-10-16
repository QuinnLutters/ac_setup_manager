local engine = require('src/core/engine')
local recommend = require('src/core/recommend')
local history = require('src/core/history')
local fx = require('helpers/fixtures')

local rules = fx.rules()

-- Builds a diagnosis list where only `id` fired (with optional metrics).
local function diagFor(id, feedback, m)
  m = m or {}
  local fb = feedback
  if not fb then
    for _, s in ipairs(rules.symptoms) do
      if s.id == id then fb = { s.feedback[1] } end
    end
  end
  return engine.diagnose(rules, m, fb, { style = 'chase' }), m
end

local function rec(id, levers, opts, m, feedback)
  local d, metrics = diagFor(id, feedback, m)
  opts = opts or {}
  opts.metrics = metrics
  return recommend.recommend(rules, d, levers, opts)
end

describe('F6 recommendation engine', function()
  local _, levers = fx.car('test_drift')

  it('recommends exactly one lever for a spin: soften the rear bar', function()
    local r = rec('spin', levers)
    assert.equals('change', r.kind)
    assert.equals('arb_rear', r.plan.lever)
    assert.equals(1, #r.plan.items)
    assert.equals(4, r.plan.items[1].from)
    assert.equals(3, r.plan.items[1].to)
    assert.equals('softer', r.plan.directionLabel)
  end)

  it('changes left and right as a pair', function()
    local _, l = fx.car('test_drift')
    -- Max out the rear bar so the next candidate (rear pressure) is used.
    for _, item in ipairs(l.arb_rear.items) do item.value = item.max end
    local r = rec('straighten', l)
    assert.equals('pressure_rear', r.plan.lever)
    assert.equals(2, #r.plan.items)
    assert.equals(r.plan.items[1].to, r.plan.items[2].to)
    assert.is_true(r.plan.items[1].to > 30)
  end)

  it('explains the limit and offers the next-best item', function()
    local _, l = fx.car('test_drift')
    for _, item in ipairs(l.arb_rear.items) do item.value = item.max end
    local r = rec('straighten', l)
    assert.equals(1, #r.blocked)
    assert.equals('at_max', r.blocked[1].reason)
    assert.matches('maximum', r.blocked[1].text)
  end)

  it('makes changes big enough to feel (min fraction of range)', function()
    local r = rec('cant_start', levers)
    assert.equals('diff_power', r.plan.lever)
    -- range 10..100 step 10: 5% of range rounds up to one 10% step
    assert.equals(70, r.plan.items[1].to)
  end)

  it('clamps every change to the car range', function()
    local _, l = fx.car('test_drift')
    l.diff_power.items[1].value = 100
    local r = rec('cant_start', l)
    assert.equals('diff_coast', r.plan.lever)
    for _, row in ipairs(r.plan.items) do assert.is_true(row.to <= 100) end
  end)

  it('moves brake bias toward 66 for chase drivers', function()
    local r = rec('chase_brake', levers, nil, nil, { 'lost_angle_braking' })
    assert.equals('brake_bias', r.plan.lever)
    assert.equals(66, r.plan.items[1].to)
  end)

  it('steers pressure toward the target window', function()
    local r = rec('pressure_window', levers, nil,
      { pressureWorstAbs = 4.2, pressureWorstAxle = 'rear', pressureWorstDelta = 4.2 }, {})
    assert.equals('pressure_rear', r.plan.lever)
    assert.equals(25, r.plan.items[1].to) -- 30 - ceil(4.2)
  end)

  it('picks the axle that bottoms out', function()
    local r = rec('bottoming', levers, nil, { bottomingRatio = 0.2, bottomingAxle = 'rear' }, {})
    assert.equals('spring_rear', r.plan.lever)
    assert.equals(85000, r.plan.items[1].to)
  end)

  it('gives advice when the car has no levers left', function()
    local _, locked = fx.lockedPack()
    local r = rec('cant_start', locked)
    assert.equals('advice', r.kind)
    assert.equals(3, #r.limited[1].blocked)
    assert.equals('not_exposed', r.limited[1].blocked[1].reason)
    assert.is_string(r.limited[1].advice)
  end)

  it('explains when steering lock is a hardware limit', function()
    local _, l = fx.car('test_drift')
    for _, item in ipairs(l.toe_front.items) do item.value = item.max end
    local r = rec('out_of_lock', l, nil, { lockLimitRatio = 0.5 }, {})
    assert.equals('advice', r.kind)
    assert.matches('hardware limit', r.limited[1].advice)
  end)

  it('carries the limit explanation along when it falls back to another symptom', function()
    local _, l = fx.car('test_drift')
    for _, item in ipairs(l.toe_front.items) do item.value = item.max end
    -- Out of lock outranks the spin it caused, but has no levers; the spin fix is used instead.
    local r = rec('out_of_lock', l, nil, { lockLimitRatio = 0.5, spinScore = 1 }, { 'spins_out' })
    assert.equals('change', r.kind)
    assert.equals('spin', r.symptom.id)
    assert.equals('out_of_lock', r.limited[1].symptom.id)
  end)

  it('treats gear-ratio files as not adjustable', function()
    local r = rec('bogs_down', levers, nil, { lowRpmRatio = 0.9 }, {})
    assert.equals('advice', r.kind)
    assert.equals('ratio_list', r.limited[1].blocked[1].reason)
  end)

  it('falls through to the next symptom when the top one is stuck', function()
    local _, locked = fx.lockedPack()
    local d = engine.diagnose(rules, {}, { 'cant_start', 'spins_out' }, {})
    local r = recommend.recommend(rules, d, locked, { metrics = {} })
    assert.equals('change', r.kind)
    assert.equals('spin', r.symptom.id)
    assert.equals('pressure_rear', r.plan.lever)
  end)

  it('says done when the driver felt good and nothing fired', function()
    local d = engine.diagnose(rules, {}, { 'felt_good' }, {})
    assert.equals('done', recommend.recommend(rules, d, levers, { feedback = { 'felt_good' } }).kind)
    assert.equals('none', recommend.recommend(rules, engine.diagnose(rules, {}, {}, {}), levers, {}).kind)
  end)

  it('skips changes the driver reverted before', function()
    local h = history.new('test_drift', 'track')
    history.block(h, 'arb_rear', -1, 'spin')
    local r = rec('spin', levers, { history = { isBlocked = history.isBlockedFn(h) } })
    assert.equals('pressure_rear', r.plan.lever)
    assert.equals('reverted_before', r.blocked[1].reason)
  end)

  it('does not undo the last change before its verdict is in', function()
    local r = rec('straighten', levers, { history = { lastChange = { lever = 'arb_rear', direction = -1 } } })
    assert.equals('pressure_rear', r.plan.lever)
    assert.equals('would_undo', r.blocked[1].reason)
    local r2 = rec('straighten', levers, { history = { lastChange = { lever = 'arb_rear', direction = -1, verdict = 'worse' } } })
    assert.equals('arb_rear', r2.plan.lever)
  end)

  it('respects inverted items', function()
    local items = require('src/core/setup_items')
    local ini = require('src/core/ini')
    local p = ini.parse('[TOE_IN_LF]\nMIN=-10\nMAX=10\nSTEP=1\n[TOE_IN_RF]\nMIN=-10\nMAX=10\nSTEP=1\n')
    local l = items.levers(items.build(p, { TOE_IN_LF = 0, TOE_IN_RF = 0 }))
    local plan = recommend.planChange(rules, { lever = 'toe_front', direction = 1, steps = 1 }, l, {})
    assert.equals(-1, plan.items[1].to) -- more toe-out = less toe-in
  end)

  it('every recommendation carries what, why, feel and a glossary term', function()
    for _, s in ipairs(rules.symptoms) do
      assert.is_string(s.why, s.id)
      assert.is_string(s.feel, s.id)
      assert.truthy(require('src/core/glossary').get(s.glossary), s.id)
    end
    local r = rec('spin', levers)
    assert.matches('Rear anti%-roll bar: softer', r.summary)
  end)
end)
