-- Reads ac.getCar(0) into the flat sample the core expects (see src/core/csv.lua).
--
-- SPIKE: per-wheel field names are not in the public SDK repo. Every field is
-- read through compat.field, and `probe` reports which ones exist so the spike
-- can confirm them from the Diagnostics tab.

local compat = require('src/game/compat')

local M = {}

local WHEELS = { 'FL', 'FR', 'RL', 'RR' }

M.CAR_FIELDS = { 'speedKmh', 'velocity', 'localVelocity', 'look', 'side', 'up', 'localAngularVelocity',
  'angularVelocity', 'steer', 'steerLock', 'gas', 'brake', 'handbrake', 'clutch', 'gear', 'rpm', 'rpmLimiter',
  'position', 'isInPitlane', 'isInPit', 'wheels', 'collidedWith', 'collisionDepth', 'wheelsOutside' }

-- Per-wheel: our column prefix -> candidate CSP field names, first match wins.
M.WHEEL_FIELDS = {
  slipAngle = { 'slipAngle' },
  slipRatio = { 'slipRatio' },
  ndSlip = { 'ndSlip' },
  load = { 'load' },
  temp = { 'tyreCoreTemperature', 'tyreMiddleTemperature' },
  pressure = { 'tyrePressure' },
  susp = { 'suspensionTravel' },
}

local function wheel(car, i)
  local wheels = compat.field(car, 'wheels')
  if not wheels then return nil end
  local ok, w = pcall(function() return wheels[i] end)
  return ok and w or nil
end

-- Returns { car = { field = true/false }, wheel = { prefix = 'csp field' or false } }.
function M.probe(car)
  local res = { car = {}, wheel = {} }
  for _, f in ipairs(M.CAR_FIELDS) do res.car[f] = compat.field(car, f) ~= nil end
  local w = wheel(car, 0)
  for prefix, names in pairs(M.WHEEL_FIELDS) do
    res.wheel[prefix] = false
    for _, name in ipairs(names) do
      if w and compat.field(w, name) ~= nil then res.wheel[prefix] = name; break end
    end
  end
  return res
end

local function vecDot(a, b)
  return a.x * b.x + a.y * b.y + a.z * b.z
end

-- Body slip in degrees, signed. Uses world velocity against the car's look and
-- side vectors, which avoids guessing the local axis convention.
function M.bodySlip(car)
  local v, look, side = compat.field(car, 'velocity'), compat.field(car, 'look'), compat.field(car, 'side')
  local fwd, lat
  if v and look and side then
    fwd, lat = vecDot(v, look), vecDot(v, side)
  else
    local lv = compat.field(car, 'localVelocity')
    if not lv then return 0 end
    fwd, lat = lv.z, lv.x
  end
  if math.sqrt(fwd * fwd + lat * lat) < 1.5 then return 0 end
  return math.deg((math.atan2 or math.atan)(lat, fwd))
end

function M.yawRate(car)
  local lav = compat.field(car, 'localAngularVelocity')
  if lav then return math.deg(lav.y) end
  local av, up = compat.field(car, 'angularVelocity'), compat.field(car, 'up')
  if av and up then return math.deg(vecDot(av, up)) end
  return 0
end

-- state: per-session table this module keeps (max steer seen, probe result).
function M.newState(car)
  local probe = M.probe(car)
  local lock = compat.num(car, 'steerLock')
  return {
    probe = probe,
    steerLock = (lock and lock > 0) and lock or nil,
    maxSteerSeen = 0,
  }
end

function M.steerNormalized(state)
  return state.steerLock ~= nil
end

function M.sample(car, t, state)
  local steerDeg = compat.num(car, 'steer') or 0
  local absSteer = math.abs(steerDeg)
  if absSteer > state.maxSteerSeen then state.maxSteerSeen = absSteer end
  -- Without a known lock, normalise against the most lock seen this session.
  local lock = state.steerLock or math.max(state.maxSteerSeen, 90)

  local s = {
    t = t,
    speed = compat.num(car, 'speedKmh') or 0,
    slip = M.bodySlip(car),
    yawRate = M.yawRate(car),
    steer = steerDeg / lock,
    steerDeg = steerDeg,
    throttle = compat.num(car, 'gas') or 0,
    brake = compat.num(car, 'brake') or 0,
    handbrake = compat.num(car, 'handbrake') or 0,
    clutch = compat.num(car, 'clutch') or 0,
    gear = compat.num(car, 'gear') or 0,
    rpm = compat.num(car, 'rpm') or 0,
  }
  -- SPIKE: collision and track-limit fields. The mistake detector only trusts
  -- them alongside real speed loss, and ignores a field that's always on.
  local with, depth = compat.num(car, 'collidedWith'), compat.num(car, 'collisionDepth')
  s.collided = ((with and with >= 0) or (depth and depth > 0)) and 1 or 0
  s.offTrack = compat.num(car, 'wheelsOutside')
  for i = 0, 3 do
    local w = wheel(car, i)
    if w then
      local suffix = WHEELS[i + 1]
      for prefix, field in pairs(state.probe.wheel) do
        if field then
          local v = compat.num(w, field)
          if v then s[prefix .. suffix] = v end
        end
      end
    end
  end
  return s
end

function M.position(car)
  return compat.field(car, 'position')
end

function M.inPits(car)
  return compat.field(car, 'isInPitlane') == true or compat.field(car, 'isInPit') == true
end

return M
