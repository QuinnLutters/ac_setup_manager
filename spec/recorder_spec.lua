local recorder = require('src/core/recorder')
local sim = require('helpers/sim')

local function record(samples, cfg)
  local rec = recorder.new(cfg)
  local runs = {}
  for _, s in ipairs(samples) do
    local run = rec:push(s)
    if run then runs[#runs + 1] = run end
  end
  return runs, rec
end

describe('F3 run recorder', function()
  it('records at 20 Hz or more', function()
    local samples = sim.scenarios.good()
    local dt = samples[2].t - samples[1].t
    assert.is_true(1 / dt >= 20)
  end)

  it('detects drift segments from body slip and speed, and ends on stop', function()
    local runs = record(sim.scenarios.good())
    assert.equals(1, #runs)
    assert.equals('stop', runs[1].endReason)
    assert.equals(2, #runs[1].segments)
    assert.equals(1, runs[1].segments[1].direction)
    assert.equals(-1, runs[1].segments[2].direction)
    assert.is_true(runs[1].driftTime > 10)
  end)

  it('ends the run on a spin', function()
    local runs = record(sim.scenarios.spin())
    assert.equals(1, #runs)
    assert.equals('spin', runs[1].endReason)
    assert.equals('spin', runs[1].segments[1].endReason)
  end)

  it('ends the run after 60 s without drifting', function()
    local b = sim.builder():launch()
    b:drift(3, 30):exit(1)
    b:hold(61)
    local runs = record(b.samples)
    assert.equals(1, #runs)
    assert.equals('timeout', runs[1].endReason)
  end)

  it('keeps the timeout configurable', function()
    local b = sim.builder():launch()
    b:drift(3, 30):exit(1):hold(12)
    local runs = record(b.samples, { noDriftTimeout = 10 })
    assert.equals('timeout', runs[1].endReason)
  end)

  it('keeps failed entry attempts as a run so "can\'t start" can be diagnosed', function()
    local runs = record(sim.scenarios.cant_start())
    assert.equals(1, #runs)
    assert.equals(0, #runs[1].segments)
    assert.is_true(runs[1].attempts >= 2)
  end)

  it('ignores normal driving without drifts or attempts', function()
    local b = sim.builder():launch()
    b:hold(10)
    b:stop()
    local runs = record(b.samples)
    assert.equals(0, #runs)
  end)

  it('includes pre-roll samples before the drift', function()
    local runs = record(sim.scenarios.good())
    local run = runs[1]
    assert.is_true(run.samples[1].t < run.segments[1].startT - 1.5)
  end)

  it('reports live status for the HUD', function()
    local rec = recorder.new()
    local samples = sim.scenarios.good()
    for i = 1, 150 do rec:push(samples[i]) end
    local st = rec:status(samples[150].t)
    assert.is_true(st.recording)
    assert.is_true(st.inDrift)
  end)

  it('can abort a run on reset', function()
    local rec = recorder.new()
    local samples = sim.scenarios.good()
    for i = 1, 200 do rec:push(samples[i]) end
    local run = rec:abort(samples[200].t, 'reset')
    assert.equals('reset', run.endReason)
    assert.equals('idle', rec.state)
  end)
end)
