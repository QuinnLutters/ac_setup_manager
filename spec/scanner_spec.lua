local catalog = require('src/core/catalog')
local items = require('src/core/setup_items')
local fx = require('helpers/fixtures')

describe('F1 catalog', function()
  local cases = {
    PRESSURE_LF = 'pressure_front', PRESSURE_RR = 'pressure_rear', CAMBER_RF = 'camber_front',
    TOE_OUT_LR = 'toe_rear', ARB_FRONT = 'arb_front', ARB_REAR = 'arb_rear',
    SPRING_RATE_LR = 'spring_rear', ROD_LENGTH_RF = 'ride_height_front', DAMP_REBOUND_RR = 'rebound_rear',
    DAMP_FAST_BUMP_LF = 'fast_bump_front', DIFF_POWER = 'diff_power', DIFF_COAST = 'diff_coast',
    FRONT_BIAS = 'brake_bias', FINAL_GEAR_RATIO = 'final_drive', STEER_LOCK = 'steer_lock',
    PRESSURE_FL = 'pressure_front', CAMBER_RL = 'camber_rear',
  }
  for name, lever in pairs(cases) do
    it('maps ' .. name .. ' to ' .. lever, function()
      assert.equals(lever, catalog.classify(name).lever)
    end)
  end

  it('marks unknown items', function()
    assert.equals('unknown', catalog.classify('XX_MAGIC_LEVER').category)
  end)

  it('inverts TOE_IN items', function()
    local c = catalog.classify('TOE_IN_LF')
    assert.equals('toe_front', c.lever)
    assert.is_true(c.invert)
  end)

  it('applies manual overrides', function()
    local c = catalog.classify('XX_MAGIC_LEVER', { XX_MAGIC_LEVER = { lever = 'steer_lock' } })
    assert.equals('steer_lock', c.lever)
    assert.equals('alignment', c.category)
    assert.is_true(c.manual)
  end)
end)

describe('F1 setup items', function()
  local list, levers = fx.car('test_drift')

  it('lists every item with value, MIN, MAX and STEP', function()
    local byName = items.byName(list)
    assert.equals(20, #list)
    local arb = byName.ARB_REAR
    assert.equals(4, arb.value)
    assert.equals(0, arb.min)
    assert.equals(10, arb.max)
    assert.equals(1, arb.step)
    assert.equals('arb', arb.category)
    assert.is_nil(byName.DISPLAY_METHOD)
  end)

  it('maps every item to a category or unknown', function()
    local counts = items.countByCategory(list)
    assert.equals(4, counts.tyres)
    assert.equals(1, counts.unknown)
    assert.equals(1, counts.gearing)
    for _, item in ipairs(list) do
      assert.truthy(catalog.CATEGORY_LABELS[item.category], item.name)
    end
  end)

  it('treats RATIOS items as lists', function()
    assert.equals('list', items.byName(list).FINAL_GEAR_RATIO.kind)
  end)

  it('groups left and right into one lever', function()
    assert.equals(2, #levers.pressure_rear.items)
    assert.is_true(levers.pressure_rear.paired)
    assert.is_false(levers.arb_rear.paired)
  end)

  it('snaps to the step and clamps to the range', function()
    local spring = items.byName(list).SPRING_RATE_LR
    assert.equals(85000, items.snap(spring, 83000))
    assert.equals(120000, items.snap(spring, 999999))
    assert.equals(60000, items.snap(spring, 0))
  end)

  it('shows clicks when the car asks for it', function()
    assert.equals('4 clicks', items.display(items.byName(list).ARB_REAR))
    assert.equals('30', items.display(items.byName(list).PRESSURE_LR))
  end)
end)
