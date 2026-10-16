-- The rule engine against recorded CSV logs, the way playtest logs are used.

local engine = require('src/core/engine')
local fx = require('helpers/fixtures')

local rules = fx.rules()

local function run(name, feedback)
  local runs = engine.runsFromCsv(rules, fx.read(fx.ROOT .. 'logs/' .. name .. '.csv'))
  assert.equals(1, #runs, name .. ' should hold one run')
  local _, levers = fx.car('test_drift')
  return engine.pipeline(rules, runs[1], fx.CTX, levers, { feedback = feedback })
end

describe('CSV logs through the full pipeline', function()
  it('clean run: no recommendation', function()
    assert.equals('none', run('good').recommendation.kind)
    assert.equals('done', run('good', { 'felt_good' }).recommendation.kind)
  end)

  local expected = {
    spin = { 'spin', 'arb_rear' },
    straighten = { 'straighten', 'arb_rear' },
    cant_start = { 'cant_start', 'diff_power' },
    wheelspin = { 'wheelspin', 'pressure_rear' },
    hot_pressure = { 'pressure_rear', 'pressure_rear' },
  }
  for name, e in pairs(expected) do
    it(name .. ' -> ' .. e[2], function()
      local r = run(name).recommendation
      assert.equals('changes', r.kind)
      local main = require('src/core/recommend').checked(r)[1]
      assert.equals(e[1], main.symptom.id)
      assert.equals(e[2], main.plan.lever)
    end)
  end

  it('bogging on a car with ratio-file gearing gives advice', function()
    local r = run('bogging').recommendation
    assert.equals('advice', r.kind)
    assert.matches('gear lower', r.limited[1].advice)
  end)
end)
