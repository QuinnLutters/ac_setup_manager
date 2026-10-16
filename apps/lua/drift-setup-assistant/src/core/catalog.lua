-- F1: mapping table from setup item names to categories and "levers".
--
-- A lever is what the rules talk about ("arb_rear", "pressure_front"). One lever
-- can be several items (left + right), which the recommender changes as a pair.
-- `invert = true` means a higher raw value moves the lever the other way, so
-- rules can always say "+1 = stiffer / more / higher".

local M = {}

M.CATEGORIES = { 'tyres', 'alignment', 'arb', 'springs', 'dampers', 'diff', 'brakes', 'gearing', 'other', 'unknown' }

M.CATEGORY_LABELS = {
  tyres = 'Tyres', alignment = 'Alignment', arb = 'Anti-roll bars', springs = 'Springs & ride height',
  dampers = 'Dampers', diff = 'Differential', brakes = 'Brakes', gearing = 'Gearing',
  other = 'Other (not used for drift)', unknown = 'Unknown',
}

-- What "+1" means for each lever, shown in the UI and explanations.
M.LEVERS = {
  pressure_front    = { category = 'tyres',     label = 'Front tyre pressure',  plus = 'higher',     minus = 'lower' },
  pressure_rear     = { category = 'tyres',     label = 'Rear tyre pressure',   plus = 'higher',     minus = 'lower' },
  compound          = { category = 'tyres',     label = 'Tyre compound',        plus = 'next',       minus = 'previous' },
  camber_front      = { category = 'alignment', label = 'Front camber',         plus = 'less negative', minus = 'more negative' },
  camber_rear       = { category = 'alignment', label = 'Rear camber',          plus = 'less negative', minus = 'more negative' },
  toe_front         = { category = 'alignment', label = 'Front toe',            plus = 'more toe-out', minus = 'more toe-in' },
  toe_rear          = { category = 'alignment', label = 'Rear toe',             plus = 'more toe-out', minus = 'more toe-in' },
  caster            = { category = 'alignment', label = 'Caster',               plus = 'more',       minus = 'less' },
  steer_lock        = { category = 'alignment', label = 'Steering lock',        plus = 'more lock',  minus = 'less lock' },
  arb_front         = { category = 'arb',       label = 'Front anti-roll bar',  plus = 'stiffer',    minus = 'softer' },
  arb_rear          = { category = 'arb',       label = 'Rear anti-roll bar',   plus = 'stiffer',    minus = 'softer' },
  spring_front      = { category = 'springs',   label = 'Front springs',        plus = 'stiffer',    minus = 'softer' },
  spring_rear       = { category = 'springs',   label = 'Rear springs',         plus = 'stiffer',    minus = 'softer' },
  ride_height_front = { category = 'springs',   label = 'Front ride height',    plus = 'higher',     minus = 'lower' },
  ride_height_rear  = { category = 'springs',   label = 'Rear ride height',     plus = 'higher',     minus = 'lower' },
  packer_front      = { category = 'springs',   label = 'Front bump packers',   plus = 'more travel', minus = 'less travel' },
  packer_rear       = { category = 'springs',   label = 'Rear bump packers',    plus = 'more travel', minus = 'less travel' },
  bump_front        = { category = 'dampers',   label = 'Front bump damping',   plus = 'stiffer',    minus = 'softer' },
  bump_rear         = { category = 'dampers',   label = 'Rear bump damping',    plus = 'stiffer',    minus = 'softer' },
  fast_bump_front   = { category = 'dampers',   label = 'Front fast bump',      plus = 'stiffer',    minus = 'softer' },
  fast_bump_rear    = { category = 'dampers',   label = 'Rear fast bump',       plus = 'stiffer',    minus = 'softer' },
  rebound_front     = { category = 'dampers',   label = 'Front rebound',        plus = 'stiffer',    minus = 'softer' },
  rebound_rear      = { category = 'dampers',   label = 'Rear rebound',         plus = 'stiffer',    minus = 'softer' },
  fast_rebound_front = { category = 'dampers',  label = 'Front fast rebound',   plus = 'stiffer',    minus = 'softer' },
  fast_rebound_rear = { category = 'dampers',   label = 'Rear fast rebound',    plus = 'stiffer',    minus = 'softer' },
  diff_power        = { category = 'diff',      label = 'Diff power (on throttle)', plus = 'more lock', minus = 'less lock' },
  diff_coast        = { category = 'diff',      label = 'Diff coast (off throttle)', plus = 'more lock', minus = 'less lock' },
  diff_preload      = { category = 'diff',      label = 'Diff preload',         plus = 'more',       minus = 'less' },
  brake_bias        = { category = 'brakes',    label = 'Brake bias',           plus = 'more front', minus = 'more rear' },
  brake_power       = { category = 'brakes',    label = 'Brake power',          plus = 'more',       minus = 'less' },
  final_drive       = { category = 'gearing',   label = 'Final drive',          plus = 'shorter',    minus = 'longer' },
  gear              = { category = 'gearing',   label = 'Gear ratio',           plus = 'next',       minus = 'previous' },
  other             = { category = 'other',     label = 'Other' },
}

-- Side suffixes, normalised to AC's LF/RF/LR/RR. Some mods use FL/FR/RL/RR.
local SIDES = {
  LF = { side = 'LF', axle = 'front' }, RF = { side = 'RF', axle = 'front' },
  LR = { side = 'LR', axle = 'rear' },  RR = { side = 'RR', axle = 'rear' },
  FL = { side = 'LF', axle = 'front' }, FR = { side = 'RF', axle = 'front' },
  RL = { side = 'LR', axle = 'rear' },
  FRONT = { axle = 'front' }, REAR = { axle = 'rear' }, F = { axle = 'front' }, R = { axle = 'rear' },
}

-- Ordered: first match wins. `base` is the lever without the axle, appended as _front/_rear.
local PATTERNS = {
  { prefix = 'PRESSURE',          base = 'pressure' },
  { prefix = 'CAMBER',            base = 'camber' },
  { prefix = 'TOE_OUT',           base = 'toe' },
  { prefix = 'TOE_IN',            base = 'toe', invert = true },
  { prefix = 'TOE',               base = 'toe' },
  { prefix = 'ARB',               base = 'arb' },
  { prefix = 'SPRING_RATE',       base = 'spring' },
  { prefix = 'ROD_LENGTH',        base = 'ride_height' },
  { prefix = 'RIDE_HEIGHT',       base = 'ride_height' },
  { prefix = 'PACKER_RANGE',      base = 'packer' },
  { prefix = 'DAMP_FAST_BUMP',    base = 'fast_bump' },
  { prefix = 'DAMP_FAST_REBOUND', base = 'fast_rebound' },
  { prefix = 'DAMP_BUMP',         base = 'bump' },
  { prefix = 'DAMP_REBOUND',      base = 'rebound' },
  { prefix = 'CASTER',            lever = 'caster' },
}

local EXACT = {
  TYRES = 'compound', COMPOUND = 'compound',
  DIFF_POWER = 'diff_power', DIFF_COAST = 'diff_coast', DIFF_PRELOAD = 'diff_preload',
  FRONT_BIAS = 'brake_bias', BRAKE_BIAS = 'brake_bias', BRAKE_POWER_MULT = 'brake_power',
  FINAL_RATIO = 'final_drive', FINAL_GEAR_RATIO = 'final_drive', FINAL_DRIVE = 'final_drive',
  STEER_LOCK = 'steer_lock', STEERING_LOCK = 'steer_lock', STEER_ANGLE = 'steer_lock', MAX_STEER = 'steer_lock',
  FUEL = 'other', ABS = 'other', TRACTION_CONTROL = 'other', TURBO_0 = 'other', TURBO_1 = 'other',
  ENGINE_LIMITER = 'other', BRAKE_DUCT = 'other',
}

-- Sections in setup.ini that are not adjustable items.
M.NON_ITEMS = { DISPLAY_METHOD = true, HEADER = true, CAR = true, ['__EXT_PATCH'] = true, VERSION = true }

local function splitSide(name)
  for suffix, info in pairs(SIDES) do
    local stem = name:match('^(.-)_' .. suffix .. '$')
    if stem and stem ~= '' then return stem, info end
  end
  return name, nil
end

-- Returns { category, lever, side, axle, invert } or a result with category 'unknown'.
-- `overrides` maps item name -> { lever = '...', invert = bool } from the manual mapper.
function M.classify(name, overrides)
  local upper = name:upper()
  local o = overrides and overrides[name]
  if o and o.lever and M.LEVERS[o.lever] then
    local _, sideInfo = splitSide(upper)
    return { category = M.LEVERS[o.lever].category, lever = o.lever, side = sideInfo and sideInfo.side,
             axle = sideInfo and sideInfo.axle, invert = o.invert or false, manual = true }
  end

  if EXACT[upper] then
    local lever = EXACT[upper]
    return { category = M.LEVERS[lever].category, lever = lever, invert = false }
  end
  if upper:match('^INTERNAL_GEAR_%d+$') or upper:match('^GEAR_%d+$') then
    return { category = 'gearing', lever = 'gear', invert = false }
  end
  if upper:match('^WING_') then
    return { category = 'other', lever = 'other', invert = false }
  end

  local stem, sideInfo = splitSide(upper)
  for _, p in ipairs(PATTERNS) do
    if stem == p.prefix or stem:sub(1, #p.prefix + 1) == p.prefix .. '_' then
      if p.lever then
        return { category = M.LEVERS[p.lever].category, lever = p.lever, side = sideInfo and sideInfo.side,
                 axle = sideInfo and sideInfo.axle, invert = p.invert or false }
      end
      if sideInfo and sideInfo.axle then
        local lever = p.base .. '_' .. sideInfo.axle
        if M.LEVERS[lever] then
          return { category = M.LEVERS[lever].category, lever = lever, side = sideInfo.side,
                   axle = sideInfo.axle, invert = p.invert or false }
        end
      end
    end
  end
  return { category = 'unknown', invert = false }
end

-- Levers the manual "what is this item" mapper offers, in a sensible order.
function M.leverChoices()
  local out = {}
  for lever, info in pairs(M.LEVERS) do
    if lever ~= 'other' then out[#out + 1] = { lever = lever, label = info.label, category = info.category } end
  end
  table.sort(out, function(a, b)
    if a.category ~= b.category then return a.category < b.category end
    return a.label < b.label
  end)
  return out
end

return M
