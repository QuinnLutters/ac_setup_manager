local mistakes = require('src/core/mistakes')
local recorder = require('src/core/recorder')
local sim = require('helpers/sim')

local function runOf(samples)
  local rec = recorder.new()
  local run
  for _, s in ipairs(samples) do run = rec:push(s) or run end
  return run or rec:abort(samples[#samples].t, 'log_end')
end

local function kinds(list)
  local out = {}
  for _, m in ipairs(list) do out[#out + 1] = m.kind end
  return table.concat(out, ',')
end

describe('driver mistake detection', function()
  it('finds nothing on clean runs, including a spin the driver tried to catch', function()
    assert.equals('', kinds(mistakes.detect(runOf(sim.scenarios.good()))))
    assert.equals('', kinds(mistakes.detect(runOf(sim.scenarios.spin()))))
    assert.equals('', kinds(mistakes.detect(runOf(sim.scenarios.straighten()))))
  end)

  it('detects a wall hit from a sudden stop the brake does not explain', function()
    local b = sim.builder():launch()
    b:drift(3, 35)
    b:go(0.25, { speed = 5, slip = 10, throttle = 0 })
    local found = mistakes.detect(runOf(b:stop().samples))
    assert.equals('impact', kinds(found))
    assert.matches('You hit something', found[1].text)
  end)

  it('does not mistake hard braking for a crash', function()
    local b = sim.builder():launch()
    b:drift(3, 35):exit(1)
    b:go(1.2, { speed = 0, brake = 1, slip = 0, throttle = 0 })
    assert.equals('', kinds(mistakes.detect(runOf(b:hold(3).samples))))
  end)

  it('uses a reported collision only when speed is really lost', function()
    -- A light touch mid-drift: the game reports contact but the car keeps its speed.
    local run = runOf(sim.scenarios.good())
    for _, s in ipairs(run.samples) do s.collided = (s.t > 5 and s.t < 5.2) and 1 or 0 end
    assert.equals('', kinds(mistakes.detect(run)))
    -- Contact followed by real speed loss does count.
    local b = sim.builder():launch()
    b:drift(3, 35)
    b:go(0.5, { speed = 40 })
    local hit = runOf(b:stop().samples)
    for _, s in ipairs(hit.samples) do s.collided = (s.t > 6.5 and s.t < 6.6) and 1 or 0 end
    assert.equals('impact', kinds(mistakes.detect(hit)))
  end)

  it('detects all four wheels off track', function()
    local run = runOf(sim.scenarios.good())
    for _, s in ipairs(run.samples) do s.offTrack = (s.t > 6 and s.t < 7.5) and 4 or 0 end
    assert.equals('off_track', kinds(mistakes.detect(run)))
  end)

  it('ignores a track-limit field that is on for the whole run', function()
    local run = runOf(sim.scenarios.good())
    for _, s in ipairs(run.samples) do s.offTrack = 4 end
    assert.equals('', kinds(mistakes.detect(run)))
  end)

  it('flags a spin the driver never tried to catch', function()
    local b = sim.builder():launch()
    b:drift(1, 35, { steer = 0.1 })
    b:go(0.8, { slip = 110, steer = 0.1 })
    assert.equals('uncaught_spin', kinds(mistakes.detect(runOf(b:hold(0.5).samples))))
  end)
end)
