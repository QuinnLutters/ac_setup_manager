-- Spots driver mistakes in a run, so a wall hit or a botched entry doesn't get
-- blamed on the setup. Runs with a mistake are logged but excluded from tuning.

local M = {}

M.DEFAULTS = {
  impactDecel = -80,      -- km/h per s over ~0.2 s, with the brake not explaining it (~2.3 g)
  impactBrake = 0.5,
  collisionDrop = 10,     -- km/h lost within 0.5 s after the game reports a collision
  offTrackWheels = 4,     -- all four wheels outside the track...
  offTrackHold = 0.5,     -- ...for this long
  unreliableShare = 0.8,  -- a field that's "on" for most of the run is ignored as bogus
  countersteer = 0.5,     -- |steer| that counts as trying to catch a slide
  catchWindow = 1.0,      -- s before a spin in which the driver should have countersteered
}

M.TEXT = {
  impact = 'You hit something at %.0f s',
  off_track = 'All four wheels went off track at %.0f s',
  uncaught_spin = 'The car spun at %.0f s without you countersteering to catch it',
}

local function cfgWith(cfg)
  local c = {}
  for k, v in pairs(M.DEFAULTS) do c[k] = v end
  for k, v in pairs(cfg or {}) do c[k] = v end
  return c
end

local function speedDrop(S, i, window)
  local t0, v0, minV = S[i].t, S[i].speed or 0, S[i].speed or 0
  for j = i + 1, #S do
    if S[j].t - t0 > window then break end
    if (S[j].speed or 0) < minV then minV = S[j].speed or 0 end
  end
  return v0 - minV
end

-- Share of samples where `field` is set, to catch a telemetry field that's always on.
local function share(S, test)
  local n = 0
  for i = 1, #S do if test(S[i]) then n = n + 1 end end
  return #S > 0 and n / #S or 0
end

-- Returns a list of { kind, t, text } (t in seconds from the start of the run).
function M.detect(run, cfg)
  local c = cfgWith(cfg)
  local S = run.samples
  local out = {}
  if #S < 3 then return out end
  local t0 = S[1].t
  local function add(kind, t)
    out[#out + 1] = { kind = kind, t = t - t0, text = string.format(M.TEXT[kind], t - t0) }
  end

  -- Impacts: a deceleration spike the brake doesn't explain, or a reported
  -- collision followed by real speed loss.
  local collisionReliable = share(S, function(s) return (s.collided or 0) > 0 end) < c.unreliableShare
  local i = 1
  while i <= #S do
    local s = S[i]
    local j = math.min(#S, i + 5)
    local dt = S[j].t - s.t
    local decel = dt > 0 and ((S[j].speed or 0) - (s.speed or 0)) / dt or 0
    local hardStop = decel <= c.impactDecel and (s.brake or 0) < c.impactBrake and (s.handbrake or 0) < 0.3
    local reported = collisionReliable and (s.collided or 0) > 0 and speedDrop(S, i, 0.5) >= c.collisionDrop
    if hardStop or reported then
      add('impact', s.t)
      -- One impact per two seconds, so a single crash isn't counted many times.
      local tSkip = s.t + 2
      while i <= #S and S[i].t < tSkip do i = i + 1 end
    else
      i = i + 1
    end
  end

  -- Off track: all wheels outside for a while.
  local offReliable = share(S, function(s) return (s.offTrack or 0) >= c.offTrackWheels end) < c.unreliableShare
  if offReliable then
    local since
    for k = 1, #S do
      local s = S[k]
      if (s.offTrack or 0) >= c.offTrackWheels then
        since = since or s.t
        if s.t - since >= c.offTrackHold then
          add('off_track', since)
          since = math.huge -- report once per excursion
        end
      else
        since = nil
      end
    end
  end

  -- Spin with no attempt to catch it.
  if run.endReason == 'spin' then
    local tEnd, tried = S[#S].t, false
    for k = #S, 1, -1 do
      if tEnd - S[k].t > c.catchWindow then break end
      if math.abs(S[k].steer or 0) >= c.countersteer then tried = true end
    end
    if not tried then add('uncaught_spin', tEnd) end
  end

  table.sort(out, function(a, b) return a.t < b.t end)
  return out
end

return M
