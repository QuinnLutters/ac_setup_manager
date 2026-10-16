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

-- The main (first ticked) fix in a recommendation.
local function main(r)
  assert.equals('changes', r.kind)
  return recommend.checked(r)[1]
end

local function find(r, lever)
  for _, o in ipairs(r.options) do if o.plan.lever == lever then return o end end
end

describe('F6 recommendation engine', function()
  local _, levers = fx.car('test_drift')

  it('ticks the main fix for a spin and lists the alternative unticked', function()
    local r = rec('spin', levers)
    local o = main(r)
    assert.equals('arb_rear', o.plan.lever)
    assert.equals(1, #o.plan.items)
    assert.equals(4, o.plan.items[1].from)
    assert.equals(3, o.plan.items[1].to)
    assert.equals('softer', o.plan.directionLabel)
    assert.is_true(o.primary)
    local alt = find(r, 'pressure_rear')
    assert.is_false(alt.checked)
    assert.is_false(alt.primary)
    assert.equals(1, #recommend.checked(r))
  end)

  it('suggests one main fix per problem, so a version can hold several changes', function()
    local d = engine.diagnose(rules, {}, { 'spins_out', 'cant_start', 'twitchy' }, {})
    local r = recommend.recommend(rules, d, levers, { metrics = {} })
    local picked = {}
    for _, o in ipairs(recommend.checked(r)) do picked[o.plan.lever] = o.symptom.id end
    assert.equals('spin', picked.arb_rear)
    assert.equals('cant_start', picked.diff_power)
    assert.equals('twitchy', picked.rebound_rear)
  end)

  it('fixes front and rear pressure in the same go', function()
    local m = { frontPressureAbs = 4.5, frontPressureDelta = 4.5, rearPressureAbs = 4.2, rearPressureDelta = -4.2 }
    local r = recommend.recommend(rules, engine.diagnose(rules, m, {}, {}), levers, { metrics = m })
    local front, rear = find(r, 'pressure_front'), find(r, 'pressure_rear')
    assert.is_true(front.checked and rear.checked)
    assert.equals(21, front.plan.items[1].to) -- 26 - ceil(4.5)
    assert.equals(35, rear.plan.items[1].to)  -- 30 + ceil(4.2)
  end)

  it('never ticks two changes that move the same setting', function()
    -- Spin wants a softer rear bar, straightening wants a stiffer one.
    local d = engine.diagnose(rules, {}, { 'spins_out', 'straightens_up' }, {})
    local r = recommend.recommend(rules, d, levers, { metrics = {} })
    local seen = {}
    for _, o in ipairs(recommend.checked(r)) do
      assert.is_nil(seen[o.plan.lever], 'two ticked changes on ' .. o.plan.lever)
      seen[o.plan.lever] = true
    end
    local conflicting
    for _, o in ipairs(r.options) do if o.conflict then conflicting = o end end
    assert.is_table(conflicting)
    assert.is_false(conflicting.checked)
  end)

  it('ticking an option unticks the other option on that setting', function()
    local d = engine.diagnose(rules, {}, { 'spins_out', 'straightens_up' }, {})
    local r = recommend.recommend(rules, d, levers, { metrics = {} })
    local soft, stiff
    for _, o in ipairs(r.options) do
      if o.plan.lever == 'arb_rear' and o.plan.direction == -1 then soft = o end
      if o.plan.lever == 'arb_rear' and o.plan.direction == 1 then stiff = o end
    end
    assert.is_true(soft.checked)
    recommend.toggle(r, stiff.id)
    assert.is_true(stiff.checked)
    assert.is_false(soft.checked)
    recommend.toggle(r, stiff.id)
    assert.is_false(stiff.checked)
  end)

  it('merges the same fix asked for by two problems', function()
    -- Spin's alternative and wheelspin's main fix are both "lower rear pressure".
    local _, l = fx.car('test_drift')
    for _, item in ipairs(l.arb_rear.items) do item.value = item.min end
    local d = engine.diagnose(rules, { wheelspinRatio = 1 }, { 'spins_out' }, {})
    local r = recommend.recommend(rules, d, l, { metrics = { wheelspinRatio = 1 } })
    local count = 0
    for _, o in ipairs(r.options) do if o.plan.lever == 'pressure_rear' then count = count + 1 end end
    assert.equals(1, count)
    local o = find(r, 'pressure_rear')
    assert.is_true(o.checked)
    assert.equals(1, #o.alsoFor)
  end)

  it('changes left and right as a pair', function()
    local _, l = fx.car('test_drift')
    -- Max out the rear bar so the next candidate (rear pressure) is used.
    for _, item in ipairs(l.arb_rear.items) do item.value = item.max end
    local o = main(rec('straighten', l))
    assert.equals('pressure_rear', o.plan.lever)
    assert.equals(2, #o.plan.items)
    assert.equals(o.plan.items[1].to, o.plan.items[2].to)
    assert.is_true(o.plan.items[1].to > 30)
  end)

  it('explains the limit and offers the next-best item', function()
    local _, l = fx.car('test_drift')
    for _, item in ipairs(l.arb_rear.items) do item.value = item.max end
    local o = main(rec('straighten', l))
    assert.equals(1, #o.blocked)
    assert.equals('at_max', o.blocked[1].reason)
    assert.matches('maximum', o.blocked[1].text)
  end)

  it('makes changes big enough to feel (min fraction of range)', function()
    local o = main(rec('cant_start', levers))
    assert.equals('diff_power', o.plan.lever)
    -- range 10..100 step 10: 5% of range rounds up to one 10% step
    assert.equals(70, o.plan.items[1].to)
  end)

  it('clamps every change to the car range', function()
    local _, l = fx.car('test_drift')
    l.diff_power.items[1].value = 100
    local o = main(rec('cant_start', l))
    assert.equals('diff_coast', o.plan.lever)
    for _, row in ipairs(o.plan.items) do assert.is_true(row.to <= 100) end
  end)

  it('moves brake bias toward 66 for chase drivers', function()
    local o = main(rec('chase_brake', levers, nil, nil, { 'lost_angle_braking' }))
    assert.equals('brake_bias', o.plan.lever)
    assert.equals(66, o.plan.items[1].to)
  end)

  it('picks the axle that bottoms out', function()
    local o = main(rec('bottoming', levers, nil, { bottomingRatio = 0.2, bottomingAxle = 'rear' }, {}))
    assert.equals('spring_rear', o.plan.lever)
    assert.equals(85000, o.plan.items[1].to)
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

  it('carries the limit explanation along with the fixes it can make', function()
    local _, l = fx.car('test_drift')
    for _, item in ipairs(l.toe_front.items) do item.value = item.max end
    -- Out of lock outranks the spin it caused, but has no levers; the spin fix is still offered.
    local r = rec('out_of_lock', l, nil, { lockLimitRatio = 0.5, spinScore = 1 }, { 'spins_out' })
    assert.equals('spin', main(r).symptom.id)
    assert.equals('out_of_lock', r.limited[1].symptom.id)
  end)

  it('treats gear-ratio files as not adjustable', function()
    local r = rec('bogs_down', levers, nil, { lowRpmRatio = 0.9 }, {})
    assert.equals('advice', r.kind)
    assert.equals('ratio_list', r.limited[1].blocked[1].reason)
  end)

  it('still fixes the problems it can when another is stuck', function()
    local _, locked = fx.lockedPack()
    local d = engine.diagnose(rules, {}, { 'cant_start', 'spins_out' }, {})
    local r = recommend.recommend(rules, d, locked, { metrics = {} })
    local o = main(r)
    assert.equals('spin', o.symptom.id)
    assert.equals('pressure_rear', o.plan.lever)
    assert.equals('cant_start', r.limited[1].symptom.id)
  end)

  it('says done when the driver felt good and nothing fired', function()
    local d = engine.diagnose(rules, {}, { 'felt_good' }, {})
    assert.equals('done', recommend.recommend(rules, d, levers, { feedback = { 'felt_good' } }).kind)
    assert.equals('none', recommend.recommend(rules, engine.diagnose(rules, {}, {}, {}), levers, {}).kind)
  end)

  it('skips changes the driver reverted before', function()
    local h = history.new('test_drift', 'track')
    history.block(h, 'arb_rear', -1, 'spin')
    local o = main(rec('spin', levers, { history = { isBlocked = history.isBlockedFn(h) } }))
    assert.equals('pressure_rear', o.plan.lever)
    assert.equals('reverted_before', o.blocked[1].reason)
  end)

  it('does not undo the last changes before their verdict is in', function()
    local o = main(rec('straighten', levers, { history = { lastChanges = { { lever = 'arb_rear', direction = -1 } } } }))
    assert.equals('pressure_rear', o.plan.lever)
    assert.equals('would_undo', o.blocked[1].reason)
    local o2 = main(rec('straighten', levers,
      { history = { lastChanges = { { lever = 'arb_rear', direction = -1, verdict = 'worse' } } } }))
    assert.equals('arb_rear', o2.plan.lever)
  end)

  it('respects inverted items', function()
    local items = require('src/core/setup_items')
    local ini = require('src/core/ini')
    local p = ini.parse('[TOE_IN_LF]\nMIN=-10\nMAX=10\nSTEP=1\n[TOE_IN_RF]\nMIN=-10\nMAX=10\nSTEP=1\n')
    local l = items.levers(items.build(p, { TOE_IN_LF = 0, TOE_IN_RF = 0 }))
    local plan = recommend.planChange(rules, { lever = 'toe_front', direction = 1, steps = 1 }, l, {})
    assert.equals(-1, plan.items[1].to) -- more toe-out = less toe-in
  end)

  it('every suggestion carries what, why, feel and a glossary term', function()
    for _, s in ipairs(rules.symptoms) do
      assert.is_string(s.why, s.id)
      assert.is_string(s.feel, s.id)
      assert.truthy(require('src/core/glossary').get(s.glossary), s.id)
    end
    local o = main(rec('spin', levers))
    assert.matches('Rear anti%-roll bar: softer', o.summary)
    assert.is_string(o.why)
    assert.is_string(o.feel)
  end)
end)
