local engine = require('src/core/engine')
local diagnosis = require('src/core/diagnosis')
local fx = require('helpers/fixtures')
local sim = require('helpers/sim')

local rules = fx.rules()

local function analyze(samples, feedback, profile, ctx)
  local rec = engine.newRecorder(rules)
  local run
  for _, s in ipairs(samples) do run = rec:push(s) or run end
  run = run or rec:abort(samples[#samples].t, 'log_end')
  assert.is_table(run, 'no run recorded')
  local m = engine.analyzeRun(rules, run, ctx or fx.CTX)
  return m, engine.diagnose(rules, m, feedback, profile)
end

local function top(d)
  local fired = diagnosis.fired(d)
  return fired[1] and fired[1].id, fired
end

describe('F4 symptom detection', function()
  it('validates rules.json', function()
    assert.same({}, engine.validate(rules))
  end)

  it('gives every symptom a confidence score', function()
    local _, d = analyze(sim.scenarios.good())
    assert.equals(#rules.symptoms, #d)
    for _, s in ipairs(d) do
      assert.is_number(s.confidence)
      assert.is_true(s.confidence >= 0 and s.confidence <= 1)
    end
  end)

  it('fires nothing on a clean run', function()
    local m, d = analyze(sim.scenarios.good())
    local id, fired = top(d)
    assert.is_nil(id, id and ('unexpected ' .. id .. ' ' .. tostring(fired[1].metricValue)))
    assert.is_true(m.avgAngle > 25)
  end)

  local expectations = {
    { 'spin', 'spin' },
    { 'straighten', 'straighten' },
    { 'cant_start', 'cant_start' },
    { 'bogging', 'bogs_down' },
    { 'wheelspin', 'wheelspin' },
    { 'hot_pressure', 'pressure_window' },
  }
  for _, e in ipairs(expectations) do
    it('detects ' .. e[2] .. ' from telemetry alone', function()
      local _, d = analyze(sim.scenarios[e[1]]())
      local id = top(d)
      assert.equals(e[2], id)
    end)
  end

  it('lets "running out of lock" outrank the spin it caused', function()
    local m, d = analyze(sim.scenarios.out_of_lock())
    assert.equals(1, m.spinOut)
    assert.equals('out_of_lock', top(d))
  end)

  it('needs the driver to say "twitchy" before flagging transitions', function()
    local m, d = analyze(sim.scenarios.twitchy())
    assert.is_true(m.transitions >= 3)
    assert.is_nil(top(d))
    local _, d2 = analyze(sim.scenarios.twitchy(), { 'twitchy' })
    assert.equals('twitchy', top(d2))
  end)

  it('lets feedback confirm a symptom and raise its priority', function()
    local _, plain = analyze(sim.scenarios.good())
    local _, confirmed = analyze(sim.scenarios.good(), { 'straightens_up' })
    local function find(list, id) for _, s in ipairs(list) do if s.id == id then return s end end end
    assert.is_false(find(plain, 'straighten').fired)
    assert.is_true(find(confirmed, 'straighten').fired)
    assert.is_true(find(confirmed, 'straighten').confirmed)
  end)

  it('puts safety before balance', function()
    -- Spin run where the driver also says it straightens up: spin still comes first.
    local _, d = analyze(sim.scenarios.spin(), { 'straightens_up' })
    local id, fired = top(d)
    assert.equals('spin', id)
    assert.equals('straighten', fired[2].id)
  end)

  it('dampens telemetry-only symptoms when the driver says it felt good', function()
    local _, d = analyze(sim.scenarios.hot_pressure(), { 'felt_good' })
    for _, s in ipairs(d) do
      if s.id == 'pressure_window' then assert.is_true(s.confidence < 0.85) end
    end
  end)

  it('only offers the chase option to chase drivers', function()
    local solo = engine.feedbackOptions(rules, { style = 'solo' })
    local chase = engine.feedbackOptions(rules, { style = 'chase' })
    assert.equals(6, #solo)
    assert.equals(7, #chase)
  end)

  it('applies profile modifiers', function()
    local _, base = analyze(sim.scenarios.bogging())
    local _, speed = analyze(sim.scenarios.bogging(), nil, { goal = 'speed' })
    local function conf(list) for _, s in ipairs(list) do if s.id == 'bogs_down' then return s.confidence end end end
    assert.is_true(conf(speed) >= conf(base))
  end)

  it('skips metrics it cannot compute', function()
    local m = analyze(sim.scenarios.good(), nil, nil, {})
    assert.is_nil(m.lowRpmRatio)
    assert.is_nil(m.bottomingRatio)
    assert.is_nil(m.pressureWorstAbs)
  end)
end)
