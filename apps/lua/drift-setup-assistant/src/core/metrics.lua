-- F4 (part 1): per-run metrics computed from a recorded run.
--
-- Every symptom metric is a "badness" number where higher means the symptom is
-- stronger. A metric is nil when the data to compute it is missing (for example
-- no suspension travel limit known), and the rule engine then skips it.

local util = require('src/core/util')

local M = {}

M.DEFAULTS = {
  enterAngle = 15,
  countersteer = 0.5,        -- |steer| fraction of lock that counts as opposite lock
  snapRate = 80,             -- deg/s of body slip growth that counts as a snap
  straightenThrottle = 0.7,
  straightenRate = -10,      -- deg/s, slip falling at the end of a segment
  attemptWindow = 1.5,       -- s after an entry attempt for the drift to start
  wheelspinThrottle = 0.8,
  wheelspinSlipRatio = 0.4,  -- rear slip ratio (AC units, verify in spike)
  wheelspinDecel = -1.5,     -- km/h per s
  powerBandLow = 0.55,       -- fraction of rev limiter below which the engine is "bogged"
  frontPeakSlipDeg = 9,      -- used when ndSlip is not available
  washSteer = 0.25,
  lockFraction = 0.95,
  transitionGap = 1.5,       -- s between segments of opposite direction
  bottomingFraction = 0.97,
  pressureMinRunTime = 30,   -- s, tyres need time to reach hot pressure
  brakeAngleLossRate = -10,  -- deg/s
}

local function cfgWith(cfg)
  local c = {}
  for k, v in pairs(M.DEFAULTS) do c[k] = v end
  for k, v in pairs(cfg or {}) do c[k] = v end
  return c
end

local function avg2(s, prefix, a, b)
  local x, y = s[prefix .. a], s[prefix .. b]
  if x == nil or y == nil then return nil end
  return (x + y) / 2
end

-- Rate of change of field `key` at index i, centred over a small window.
local function rate(samples, i, key, abs)
  local a, b = samples[math.max(1, i - 2)], samples[math.min(#samples, i + 2)]
  local dt = b.t - a.t
  if dt <= 0 then return 0 end
  local va, vb = a[key], b[key]
  if va == nil or vb == nil then return 0 end
  if abs then va, vb = math.abs(va), math.abs(vb) end
  return (vb - va) / dt
end

local function sampleDt(samples, i)
  if i < #samples then return math.max(0, samples[i + 1].t - samples[i].t) end
  if i > 1 then return math.max(0, samples[i].t - samples[i - 1].t) end
  return 0
end

-- run: { samples, segments, endReason, attempts }
-- ctx: { rpmLimiter, idealPressure = { front, rear }, suspMaxTravel = { FL, FR, RL, RR }, steerNormalized }
function M.compute(run, ctx, cfg)
  local c = cfgWith(cfg)
  ctx = ctx or {}
  local S = run.samples
  local m = {}
  local n = #S
  if n < 2 then return { totalTime = 0, driftTime = 0, segments = 0 } end

  -- Mark which samples are inside a drift segment.
  local inDrift = {}
  for _, seg in ipairs(run.segments) do
    for i = seg.startIdx, math.min(seg.endIdx or n, n) do inDrift[i] = seg end
  end

  m.totalTime = S[n].t - S[1].t
  m.segments = #run.segments
  m.endReason = run.endReason

  local driftTime, angles, speeds, activeTime = 0, {}, {}, 0
  local snapTime, snaps, inSnap = 0, 0, false
  local wheelspinTime, lowRpmTime, washTime, lockTime, brakeLossTime = 0, 0, 0, 0, 0
  local bottomFront, bottomRear, bottomKnown = 0, 0, false
  local maxAngle, maxSteer = 0, 0
  local counterBeforeEnd = false
  local frontP, rearP, pressureTime = 0, 0, 0
  local pressureFrom = S[1].t + m.totalTime * 0.5
  local susp = ctx.suspMaxTravel

  for i = 1, n do
    local s = S[i]
    local dt = sampleDt(S, i)
    local absSlip = math.abs(s.slip or 0)
    local absSteer = math.abs(s.steer or 0)
    local throttle = s.throttle or 0
    if absSteer > maxSteer then maxSteer = absSteer end
    if (s.speed or 0) > 20 then activeTime = activeTime + dt end

    if inDrift[i] then
      driftTime = driftTime + dt
      angles[#angles + 1] = absSlip
      speeds[#speeds + 1] = s.speed
      if absSlip > maxAngle then maxAngle = absSlip end
      local slipRate = rate(S, i, 'slip', true)

      -- Snap: slip growing fast while the driver is already at opposite lock.
      if slipRate >= c.snapRate and absSteer >= c.countersteer then
        snapTime = snapTime + dt
        if not inSnap and snapTime >= 0.15 then snaps = snaps + 1; inSnap = true end
      else
        snapTime, inSnap = 0, false
      end

      if ctx.rpmLimiter and s.rpm and throttle >= 0.5 and s.rpm < c.powerBandLow * ctx.rpmLimiter then
        lowRpmTime = lowRpmTime + dt
      end
      if absSteer >= c.lockFraction and slipRate > 0 then lockTime = lockTime + dt end

      -- Wheelspin without drive: rears spinning, throttle pinned, speed falling.
      local rearSR = avg2(s, 'slipRatio', 'RL', 'RR')
      if rearSR and throttle >= c.wheelspinThrottle and math.abs(rearSR) >= c.wheelspinSlipRatio
        and rate(S, i, 'speed') <= c.wheelspinDecel then
        wheelspinTime = wheelspinTime + dt
      end
      if (s.brake or 0) >= 0.2 and slipRate <= c.brakeAngleLossRate then brakeLossTime = brakeLossTime + dt end
    end


    -- Front washing out: fronts past peak slip while the car isn't rotating.
    if (s.speed or 0) > 30 and absSteer >= c.washSteer and absSlip < c.enterAngle then
      local nd = avg2(s, 'ndSlip', 'FL', 'FR')
      local sa = avg2(s, 'slipAngle', 'FL', 'FR')
      local pastPeak = (nd and nd > 1.0) or (not nd and sa and math.abs(sa) > c.frontPeakSlipDeg)
      if pastPeak then washTime = washTime + dt end
    end

    if susp then
      bottomKnown = true
      for _, w in ipairs({ 'FL', 'FR', 'RL', 'RR' }) do
        local travel, maxT = s['susp' .. w], susp[w]
        if travel and maxT and maxT > 0 and travel >= c.bottomingFraction * maxT then
          if w == 'FL' or w == 'FR' then bottomFront = bottomFront + dt / 2 else bottomRear = bottomRear + dt / 2 end
        end
      end
    end

    if s.t >= pressureFrom and (s.speed or 0) > 20 then
      local pf, pr = avg2(s, 'pressure', 'FL', 'FR'), avg2(s, 'pressure', 'RL', 'RR')
      if pf and pr then
        frontP, rearP, pressureTime = frontP + pf * dt, rearP + pr * dt, pressureTime + dt
      end
    end
  end

  -- Was the driver at opposite lock in the half second before a spin?
  if run.endReason == 'spin' then
    local tEnd = S[n].t
    for i = n, 1, -1 do
      if tEnd - S[i].t > 0.5 then break end
      if math.abs(S[i].steer or 0) >= c.countersteer then counterBeforeEnd = true end
    end
  end

  m.driftTime = driftTime
  m.driftShare = m.totalTime > 0 and driftTime / m.totalTime or 0
  m.avgAngle = util.mean(angles)
  m.maxAngle = maxAngle
  m.angleStd = util.stddev(angles)
  m.avgDriftSpeed = util.mean(speeds)
  m.maxSteer = maxSteer
  m.snapEvents = snaps
  m.spinOut = run.endReason == 'spin' and 1 or 0

  -- Spin score: 1 for a spin at opposite lock, 0.7 for any other spin, else snaps per segment.
  local spinPart = run.endReason == 'spin' and (counterBeforeEnd and 1 or 0.7) or 0
  m.spinScore = math.max(spinPart, math.min(1, snaps / math.max(1, #run.segments)))

  -- Straightening up: segments that end with throttle still high and slip falling.
  local straight, judged = 0, 0
  for _, seg in ipairs(run.segments) do
    if seg.endReason == 'exit' then
      judged = judged + 1
      local thr, cnt, endIdx = 0, 0, seg.endIdx
      local endT = S[endIdx].t
      for i = endIdx, seg.startIdx, -1 do
        if endT - S[i].t > 0.5 then break end
        thr, cnt = thr + (S[i].throttle or 0), cnt + 1
      end
      local mid = math.max(seg.startIdx, endIdx - 3)
      local slipRate = rate(S, mid, 'slip', true)
      if cnt > 0 and thr / cnt >= c.straightenThrottle and slipRate <= c.straightenRate then
        straight = straight + 1
      end
    end
  end
  m.straightenRatio = judged > 0 and straight / judged or 0

  -- Failed entries: attempts that never turned into a drift.
  local failed = M.failedEntries(run, c)
  m.failedEntries = failed
  m.failedEntryRatio = (failed + #run.segments) > 0 and failed / (failed + #run.segments) or 0

  local base = math.max(driftTime, 0.001)
  m.wheelspinRatio = wheelspinTime / base
  m.lowRpmRatio = ctx.rpmLimiter and (lowRpmTime / base) or nil
  m.frontWashRatio = activeTime > 0 and washTime / activeTime or 0
  m.lockLimitRatio = ctx.steerNormalized ~= false and (lockTime / base) or nil
  m.brakeAngleLossRatio = brakeLossTime / base

  -- Transitions: body slip flips from one side to the other within a short gap.
  -- Scanned per sample because a quick switch never drops out of the drift segment.
  local peaks = {}
  local lastSide, lastSideT, lastSideIdx = 0, nil, nil
  for i = 1, n do
    local s = S[i]
    local slip = s.slip or 0
    if math.abs(slip) >= c.enterAngle then
      local side = slip > 0 and 1 or -1
      if lastSide ~= 0 and side ~= lastSide and s.t - lastSideT <= c.transitionGap then
        local peak = 0
        local tFrom, tTo = lastSideT - 0.3, s.t + 0.5
        for j = math.max(1, lastSideIdx - 15), n do
          if S[j].t > tTo then break end
          if S[j].t >= tFrom then
            local ya = math.abs(rate(S, j, 'yawRate'))
            if ya > peak then peak = ya end
          end
        end
        peaks[#peaks + 1] = peak
      end
      lastSide, lastSideT, lastSideIdx = side, s.t, i
    end
  end
  m.transitions = #peaks
  m.transitionYawAccel = #peaks > 0 and util.mean(peaks) or nil

  if bottomKnown then
    m.bottomingRatio = m.totalTime > 0 and (bottomFront + bottomRear) / m.totalTime or 0
    m.bottomingAxle = bottomRear >= bottomFront and 'rear' or 'front'
  end

  local ideal = ctx.idealPressure
  if ideal and ideal.front and ideal.rear and pressureTime > 1 and m.totalTime >= c.pressureMinRunTime then
    m.frontPressureDelta = frontP / pressureTime - ideal.front
    m.rearPressureDelta = rearP / pressureTime - ideal.rear
    if math.abs(m.frontPressureDelta) >= math.abs(m.rearPressureDelta) then
      m.pressureWorstAxle, m.pressureWorstDelta = 'front', m.frontPressureDelta
    else
      m.pressureWorstAxle, m.pressureWorstDelta = 'rear', m.rearPressureDelta
    end
    m.pressureWorstAbs = math.abs(m.pressureWorstDelta)
  end

  return m
end

function M.failedEntries(run, c)
  c = cfgWith(c)
  local S, failed, i = run.samples, 0, 1
  local segStarts = {}
  for _, seg in ipairs(run.segments) do segStarts[#segStarts + 1] = seg.startT end
  while i <= #S do
    local s = S[i]
    local attempt = (s.speed or 0) >= 25 and math.abs(s.slip or 0) < c.enterAngle
      and ((s.handbrake or 0) >= 0.5 or (math.abs(s.steer or 0) >= 0.3 and (s.throttle or 0) >= 0.8))
    if attempt then
      local t0 = s.t
      local succeeded = false
      for _, st in ipairs(segStarts) do
        if st >= t0 - 0.3 and st <= t0 + c.attemptWindow then succeeded = true end
      end
      if not succeeded then
        -- Only judge attempts whose whole window was recorded.
        if S[#S].t - t0 >= c.attemptWindow then failed = failed + 1 end
      end
      -- Skip past this attempt so one long input isn't counted many times.
      while i <= #S and S[i].t - t0 < c.attemptWindow do i = i + 1 end
    else
      i = i + 1
    end
  end
  return failed
end

return M
