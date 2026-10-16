local setupfile = require('src/core/setupfile')
local history = require('src/core/history')
local compare = require('src/core/compare')
local baseline = require('src/core/baseline')
local items = require('src/core/setup_items')
local ini = require('src/core/ini')
local fx = require('helpers/fixtures')

local rules = fx.rules()

describe('F8 save as new setup', function()
  it('names files DSA_<car>_v<n>.ini', function()
    assert.equals('DSA_ks_bmw_m3_v1.ini', (setupfile.nextFileName('ks_bmw_m3', {})))
    local name, n = setupfile.nextFileName('ks_bmw_m3', { 'DSA_ks_bmw_m3_v1.ini', 'DSA_ks_bmw_m3_v3.ini', 'mine.ini' })
    assert.equals('DSA_ks_bmw_m3_v4.ini', name)
    assert.equals(4, n)
  end)

  it('never returns a name that already exists', function()
    local existing = { 'DSA_car_v1.ini', 'dsa_car_v2.ini' }
    local name = setupfile.nextFileName('car', existing, 2)
    assert.equals('DSA_car_v3.ini', name)
  end)

  it('keeps every other value from the base setup and changes only the target', function()
    local base = ini.parse(fx.read(fx.ROOT .. 'cars/test_drift/current_setup.ini'))
    local text = setupfile.build(base, { ARB_REAR = 3 }, 'test_drift', { 'Drift Setup Assistant v2' })
    local out = ini.parse(text)
    assert.equals('3', out.sections.ARB_REAR.values.VALUE)
    assert.equals('30', out.sections.PRESSURE_LR.values.VALUE)
    assert.equals('test_drift', out.sections.CAR.values.MODEL)
    assert.matches('^; Drift Setup Assistant v2', text)
    -- Base is untouched.
    assert.equals('4', base.sections.ARB_REAR.values.VALUE)
  end)

  it('diffs two versions', function()
    local list = fx.car('test_drift')
    local rows = setupfile.diff({ ARB_REAR = 4, FUEL = 30 }, { ARB_REAR = 3, FUEL = 30 }, items.byName(list))
    assert.equals(1, #rows)
    assert.equals('Rear ARB', rows[1].label)
    assert.equals('4 clicks', rows[1].fromDisplay)
    assert.equals('3 clicks', rows[1].toDisplay)
  end)
end)

describe('F9 before and after', function()
  local spinRule
  for _, s in ipairs(rules.symptoms) do if s.id == 'spin' then spinRule = s end end
  local straightenRule
  for _, s in ipairs(rules.symptoms) do if s.id == 'straighten' then straightenRule = s end end

  it('says the change helped when the symptom went down', function()
    local r = compare.compare(rules, { { spinScore = 1, avgAngle = 30, spinOut = 1 }, { spinScore = 0.8, spinOut = 1 } },
      { { spinScore = 0.1, avgAngle = 33, spinOut = 0 }, { spinScore = 0, spinOut = 0 } }, spinRule)
    assert.equals('helped', r.verdict)
    assert.is_true(#r.rows > 0)
  end)

  it('says worse when the symptom went up', function()
    local r = compare.compare(rules, { { straightenRatio = 0.4 } }, { { straightenRatio = 0.9 } }, straightenRule)
    assert.equals('worse', r.verdict)
    assert.matches('revert', r.text)
  end)

  it('flags new spins as worse whatever the target was', function()
    local r = compare.compare(rules, { { straightenRatio = 0.6, spinOut = 0 } },
      { { straightenRatio = 0.3, spinOut = 1 } }, straightenRule)
    assert.equals('worse', r.verdict)
  end)

  it('needs runs on both setups', function()
    assert.equals('not_enough', compare.compare(rules, {}, { { spinScore = 0 } }, spinRule).verdict)
  end)

  it('uses driver feedback as a tie-breaker', function()
    local r = compare.compare(rules, { { straightenRatio = 0.5 } }, { { straightenRatio = 0.45 } }, straightenRule, { 'felt_good' })
    assert.equals('helped', r.verdict)
  end)
end)

describe('F12 history and revert', function()
  it('tracks versions, runs and reverts', function()
    local h = history.new('car', 'track')
    history.addBase(h, 'mine.ini', { ARB_REAR = 4 }, 1)
    history.setActive(h, 0)
    history.addVersion(h, { n = 1, file = 'DSA_car_v1.ini', parent = 0, kind = 'change',
      change = { lever = 'arb_rear', direction = -1 }, symptomId = 'spin', values = { ARB_REAR = 3 } }, 2)
    history.addVersion(h, { n = 2, file = 'DSA_car_v2.ini', parent = 1, kind = 'change',
      change = { lever = 'pressure_rear', direction = -1 }, symptomId = 'spin', values = { ARB_REAR = 3 } }, 3)
    history.setActive(h, 2)
    history.addRun(h, 2, { spinScore = 1 }, { 'spins_out' }, 4)
    assert.equals(1, #history.metricsFor(h, 2))
    assert.same({ { lever = 'pressure_rear', direction = -1 } }, history.lastChanges(h))

    history.revert(h, 0)
    assert.equals(0, h.activeN)
    local blocked = history.isBlockedFn(h)
    assert.is_true(blocked('arb_rear', -1))
    assert.is_true(blocked('pressure_rear', -1))
    assert.is_false(blocked('arb_rear', 1))
    assert.equals('reverted', history.get(h, 2).verdict)
    assert.equals('DSA_car_v1.ini', history.findByFile(h, 'dsa_car_v1.ini').file)
  end)

  it('reuses the base when the same setup is seen again', function()
    local h = history.new('car', 'track')
    local a = history.addBase(h, 'mine.ini', { X = 1 }, 1)
    local b = history.addBase(h, 'mine.ini', { X = 1 }, 2)
    assert.equals(a, b)
    history.addBase(h, 'other.ini', { X = 2 }, 3)
    assert.equals(1, #h.versions)
    assert.equals('other.ini', h.versions[1].file)
  end)
end)

describe('F10 starter baseline', function()
  it('builds a drift baseline from the car ranges', function()
    local _, levers = fx.car('test_drift')
    local b = baseline.generate(rules, levers)
    local v = baseline.values(b)
    assert.equals(100, v.DIFF_POWER)
    assert.equals(90, v.DIFF_COAST)
    assert.is_true(v.PRESSURE_LR > v.PRESSURE_LF)
    assert.equals(-40, v.CAMBER_LF)
    local skipped = {}
    for _, s in ipairs(b.skipped) do skipped[s.lever] = true end
    assert.is_true(skipped.steer_lock)
    assert.is_true(skipped.camber_rear)
  end)

  it('keeps rear pressure above front on odd ranges', function()
    local p = ini.parse('[PRESSURE_LF]\nMIN=10\nMAX=40\nSTEP=1\n[PRESSURE_LR]\nMIN=10\nMAX=20\nSTEP=1\n')
    local l = items.levers(items.build(p, {}))
    local v = baseline.values(baseline.generate(rules, l))
    assert.is_true(v.PRESSURE_LR > v.PRESSURE_LF or v.PRESSURE_LR == 20)
  end)
end)

describe('multi-change versions and the start of a session', function()
  local rules = fx.rules()
  local function rule(id) for _, s in ipairs(rules.symptoms) do if s.id == id then return s end end end

  it('compares a version that fixed several problems', function()
    local before = { { spinScore = 1, rearPressureAbs = 4 }, { spinScore = 0.8, rearPressureAbs = 4.4 } }
    local after = { { spinScore = 0.1, rearPressureAbs = 1 }, { spinScore = 0, rearPressureAbs = 0.6 } }
    local r = compare.compare(rules, before, after, { rule('spin'), rule('pressure_rear') })
    assert.equals('helped', r.verdict)
    assert.equals(2, #r.primaries)
    assert.matches('The changes helped', r.text)
  end)

  it('averages several runs, numbers by mean and labels by majority', function()
    local m = require('src/core/metrics').aggregate({
      { spinScore = 1, bottomingAxle = 'rear' }, { spinScore = 0.5, bottomingAxle = 'rear' },
      { spinScore = 0, bottomingAxle = 'front' } })
    assert.equals(0.5, m.spinScore)
    assert.equals('rear', m.bottomingAxle)
  end)

  it('reads versions saved before multi-change support', function()
    local v = { n = 1, change = { lever = 'arb_rear', direction = -1 }, symptomId = 'spin' }
    local list = history.changesOf(v)
    assert.equals(1, #list)
    assert.equals('spin', list[1].symptomId)
  end)

  it('counts starting runs, leaving out mistakes', function()
    local h = history.new('car', 'track')
    history.addBase(h, 'mine.ini', { X = 1 }, 1)
    history.setActive(h, 0)
    history.setStart(h, 'own', 0, 3)
    history.addRun(h, 0, {}, {}, 1)
    history.addRun(h, 0, {}, {}, 2, { excluded = true })
    local count, needed = history.calibration(h)
    assert.equals(1, count)
    assert.equals(3, needed)
    assert.equals(2, #history.runsFor(h, 0, true))
  end)

  it('skips the start choice for histories that were already tuning', function()
    local h = history.new('car', 'track')
    history.addBase(h, 'mine.ini', { X = 1 }, 1)
    history.addVersion(h, { n = 1, parent = 0, kind = 'change' }, 2)
    history.migrate(h)
    assert.is_true(h.calibrated)
    local fresh = history.migrate(history.new('car', 'track'))
    assert.is_nil(fresh.start)
  end)
end)
