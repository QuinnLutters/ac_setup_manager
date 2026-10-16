-- F3: run recorder. A pure state machine fed one telemetry sample at a time.
--
-- A sample is a flat table (see src/core/csv.lua for the columns). The fields the
-- recorder needs: t (s), speed (km/h), slip (body slip angle, deg, signed),
-- steer (-1..1 of lock), throttle, handbrake.
--
-- A run starts at the first drift segment or entry attempt, and ends on a spin,
-- a stop, or `noDriftTimeout` seconds (60 by default) without drifting.

local M = {}
M.__index = M

M.DEFAULTS = {
  enterAngle = 15,      -- deg of body slip to count as drifting
  exitAngle = 8,        -- deg below which a drift ends
  minSpeed = 20,        -- km/h
  enterHold = 0.25,     -- s above enterAngle before a segment starts
  exitHold = 0.4,       -- s below exitAngle before a segment ends
  spinAngle = 85,       -- deg of body slip that counts as a spin
  stopSpeed = 5,        -- km/h
  stopHold = 2.0,       -- s below stopSpeed to end the run
  noDriftTimeout = 60,  -- s without drifting to end the run
  preRoll = 2.0,        -- s of samples kept before the run starts
  minDriftTime = 1.5,   -- s of drifting for a run to count (spins and failed starts always count)
  attemptSpeed = 25,    -- km/h, entry attempt detection
  attemptSteer = 0.3,
  attemptThrottle = 0.8,
  attemptHandbrake = 0.5,
}

function M.new(cfg)
  local self = setmetatable({}, M)
  self.cfg = {}
  for k, v in pairs(M.DEFAULTS) do self.cfg[k] = v end
  for k, v in pairs(cfg or {}) do self.cfg[k] = v end
  self:reset()
  return self
end

function M:reset()
  self.state = 'idle'        -- 'idle' | 'running'
  self.preroll = {}
  self.run = nil
  self.inDrift = false
  self.aboveSince = nil
  self.belowSince = nil
  self.stoppedSince = nil
  self.lastDriftT = nil
  self.attemptSince = nil
  self.calmSince = nil
  self.runCount = self.runCount or 0
end

function M:isAttempt(s)
  local c = self.cfg
  if s.speed < c.attemptSpeed or math.abs(s.slip) >= c.enterAngle then return false end
  return (s.handbrake or 0) >= c.attemptHandbrake
    or (math.abs(s.steer or 0) >= c.attemptSteer and (s.throttle or 0) >= c.attemptThrottle)
end

function M:startRun(t)
  self.state = 'running'
  self.run = { samples = {}, segments = {}, startT = t, attempts = 0 }
  for i = 1, #self.preroll do self.run.samples[i] = self.preroll[i] end
  self.preroll = {}
  self.lastDriftT = t
  self.stoppedSince = nil
end

local function findIndexAtOrAfter(samples, t)
  for i = #samples, 1, -1 do
    if samples[i].t < t then return i + 1 end
  end
  return 1
end

function M:openSegment(t)
  local run = self.run
  local idx = findIndexAtOrAfter(run.samples, t)
  run.segments[#run.segments + 1] = { startT = t, startIdx = idx }
  self.inDrift = true
end

function M:closeSegment(t, reason)
  local run = self.run
  local seg = run.segments[#run.segments]
  seg.endT = t
  seg.endIdx = math.max(seg.startIdx, findIndexAtOrAfter(run.samples, t) - 1)
  if reason == 'spin' then seg.endIdx = #run.samples end
  seg.endReason = reason
  local sum = 0
  for i = seg.startIdx, seg.endIdx do sum = sum + run.samples[i].slip end
  seg.direction = sum >= 0 and 1 or -1
  self.inDrift = false
  self.lastDriftT = t
end

function M:finishRun(t, reason)
  local run = self.run
  if self.inDrift then self:closeSegment(t, reason == 'spin' and 'spin' or 'run_end') end
  run.endT = t
  run.endReason = reason
  local driftTime = 0
  for _, seg in ipairs(run.segments) do driftTime = driftTime + (seg.endT - seg.startT) end
  run.driftTime = driftTime
  self.state = 'idle'
  self.run = nil
  self.aboveSince, self.belowSince, self.attemptSince = nil, nil, nil
  -- After a spin the car is still sliding; wait until it settles before arming again.
  self.cooldown = reason == 'spin'
  self.calmSince = nil
  local keep = driftTime >= self.cfg.minDriftTime
    or (reason == 'spin' and #run.segments > 0)
    or (#run.segments == 0 and run.attempts >= 2)
  if not keep then return nil end
  self.runCount = self.runCount + 1
  run.id = self.runCount
  return run
end

-- Feeds one sample. Returns a finished run table when a run ends, else nil.
function M:push(s)
  local c = self.cfg
  local absSlip = math.abs(s.slip)
  local moving = s.speed >= c.minSpeed

  if self.state == 'idle' and self.cooldown then
    if absSlip < c.exitAngle or s.speed < c.stopSpeed then
      self.calmSince = self.calmSince or s.t
      if s.t - self.calmSince >= 1.0 then self.cooldown = false end
    else
      self.calmSince = nil
    end
    return nil
  end

  if self.state == 'idle' then
    local pr = self.preroll
    pr[#pr + 1] = s
    while #pr > 1 and s.t - pr[1].t > c.preRoll do table.remove(pr, 1) end

    if absSlip >= c.enterAngle and moving then
      self.aboveSince = self.aboveSince or s.t
      if s.t - self.aboveSince >= c.enterHold then
        local since = self.aboveSince
        self:startRun(since)
        self:openSegment(since)
      end
    else
      self.aboveSince = nil
    end
    if self.state == 'idle' and self:isAttempt(s) then
      self.attemptSince = self.attemptSince or s.t
      if s.t - self.attemptSince >= 0.3 then
        self:startRun(self.attemptSince)
        self.run.attempts = 1
      end
    elseif self.state == 'idle' then
      self.attemptSince = nil
    end
    return nil
  end

  local run = self.run
  run.samples[#run.samples + 1] = s

  -- Spin ends everything immediately.
  if absSlip >= c.spinAngle and s.speed > 3 then
    return self:finishRun(s.t, 'spin')
  end

  if self.inDrift then
    if absSlip < c.exitAngle or not moving then
      self.belowSince = self.belowSince or s.t
      if s.t - self.belowSince >= c.exitHold then
        self:closeSegment(self.belowSince, 'exit')
        self.belowSince = nil
      end
    else
      self.belowSince = nil
      self.lastDriftT = s.t
    end
  else
    if absSlip >= c.enterAngle and moving then
      self.aboveSince = self.aboveSince or s.t
      if s.t - self.aboveSince >= c.enterHold then
        self:openSegment(self.aboveSince)
        self.aboveSince = nil
      end
    else
      self.aboveSince = nil
    end
    -- Count fresh entry attempts (rising edge) for the "can't start" signal.
    if self:isAttempt(s) then
      if not self.attemptSince then self.attemptSince = s.t; run.attempts = run.attempts + 1 end
    else
      self.attemptSince = nil
    end
  end

  if s.speed < c.stopSpeed then
    self.stoppedSince = self.stoppedSince or s.t
    if s.t - self.stoppedSince >= c.stopHold then return self:finishRun(s.t, 'stop') end
  else
    self.stoppedSince = nil
  end

  if not self.inDrift and s.t - self.lastDriftT >= c.noDriftTimeout then
    return self:finishRun(s.t, 'timeout')
  end
  return nil
end

-- Ends the current run early, e.g. when the car is teleported back to the pits.
function M:abort(t, reason)
  if self.state ~= 'running' then self:reset(); return nil end
  local run = self:finishRun(t, reason or 'reset')
  self.preroll = {}
  return run
end

-- Live numbers for the HUD.
function M:status(t)
  if self.state ~= 'running' then return { recording = false } end
  local run = self.run
  local driftTime = 0
  for _, seg in ipairs(run.segments) do driftTime = driftTime + ((seg.endT or t) - seg.startT) end
  return {
    recording = true,
    inDrift = self.inDrift,
    runTime = t - run.startT,
    driftTime = driftTime,
    segments = #run.segments,
    sinceDrift = self.inDrift and 0 or (t - self.lastDriftT),
  }
end

return M
