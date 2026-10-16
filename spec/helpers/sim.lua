-- Synthetic telemetry for tests and fixtures. Each scenario is a scripted
-- sequence of target states; the builder interpolates between them at 25 Hz.

local M = {}

local RATE = 25
local WHEELS = { 'FL', 'FR', 'RL', 'RR' }

local Builder = {}
Builder.__index = Builder

function M.builder(initial)
  local self = setmetatable({}, Builder)
  self.t = 0
  self.samples = {}
  self.state = {
    speed = 0, slip = 0, steer = 0, throttle = 0, brake = 0, handbrake = 0, clutch = 0,
    gear = 3, rpm = 5500, rearSR = 0.05, frontSlip = 2, frontNd = 0.5,
    pressureF = 26, pressureR = 28, susp = 0.05,
  }
  for k, v in pairs(initial or {}) do self.state[k] = v end
  return self
end

function Builder:emit()
  local st = self.state
  local prev = self.samples[#self.samples]
  local s = {
    t = self.t, speed = st.speed, slip = st.slip, steer = st.steer, steerDeg = st.steer * 450,
    throttle = st.throttle, brake = st.brake, handbrake = st.handbrake, clutch = st.clutch,
    gear = st.gear, rpm = st.rpm,
  }
  -- Yaw rate roughly follows the change in body slip.
  s.yawRate = prev and (st.slip - prev.slip) * RATE or 0
  for _, w in ipairs(WHEELS) do
    local front = w == 'FL' or w == 'FR'
    s['slipAngle' .. w] = front and st.frontSlip or st.slip * 0.8
    s['slipRatio' .. w] = front and 0.01 or st.rearSR
    s['ndSlip' .. w] = front and st.frontNd or 1.5
    s['load' .. w] = 3500
    s['temp' .. w] = 80
    s['pressure' .. w] = front and st.pressureF or st.pressureR
    s['susp' .. w] = st.susp
  end
  self.samples[#self.samples + 1] = s
end

-- Moves linearly from the current state to `target` over `duration` seconds.
function Builder:go(duration, target)
  local from = {}
  for k, v in pairs(self.state) do from[k] = v end
  local steps = math.max(1, math.floor(duration * RATE + 0.5))
  for i = 1, steps do
    local f = i / steps
    for k, v in pairs(target or {}) do
      if type(v) == 'number' and type(from[k]) == 'number' then
        self.state[k] = from[k] + (v - from[k]) * f
      else
        self.state[k] = v
      end
    end
    self.t = self.t + 1 / RATE
    self:emit()
  end
  return self
end

function Builder:hold(duration) return self:go(duration, {}) end

function Builder:launch()
  return self:go(3, { speed = 60, throttle = 0.8, rpm = 6500 })
end

function Builder:drift(duration, angle, extra)
  local t = { slip = angle, steer = angle > 0 and -0.55 or 0.55, throttle = 1, speed = 60 }
  for k, v in pairs(extra or {}) do t[k] = v end
  self:go(0.5, t)
  return self:hold(duration)
end

function Builder:exit(duration)
  return self:go(duration or 1, { slip = 0, steer = 0, throttle = 0.3 })
end

function Builder:stop()
  self:go(3, { speed = 0, throttle = 0, brake = 0.6, slip = 0, steer = 0 })
  return self:hold(3)
end

M.scenarios = {}

function M.scenarios.good()
  local b = M.builder():launch()
  b:drift(6, 35):exit(1.2):hold(2)
  b:drift(5, -32):exit(1.2):hold(1)
  return b:stop().samples
end

function M.scenarios.spin()
  local b = M.builder():launch()
  b:drift(3, 35)
  b:go(1.0, { slip = 110, steer = -0.9 })
  return b:hold(1).samples
end

function M.scenarios.straighten()
  local b = M.builder():launch()
  for i = 1, 4 do
    b:drift(2, 30)
    b:go(0.8, { slip = 0, throttle = 1, steer = 0 })
    b:hold(1.5)
  end
  return b:stop().samples
end

function M.scenarios.cant_start()
  local b = M.builder():launch()
  b:go(1, { speed = 55 })
  for i = 1, 5 do
    b:go(0.2, { steer = 0.6, throttle = 1, slip = 6 })
    b:hold(1.0)
    b:go(0.3, { steer = 0, throttle = 0.5, slip = 0 })
    b:hold(2.5)
  end
  return b:stop().samples
end

function M.scenarios.bogging()
  local b = M.builder():launch()
  b:drift(8, 35, { rpm = 3200 })
  b:exit(1):hold(1)
  b:drift(6, -35, { rpm = 3000 })
  b:exit(1)
  return b:stop().samples
end

function M.scenarios.twitchy()
  local b = M.builder():launch()
  b:drift(2, 30)
  for i = 1, 4 do
    b:go(0.25, { slip = (i % 2 == 1) and -30 or 30, steer = (i % 2 == 1) and 0.55 or -0.55 })
    b:hold(1.5)
  end
  b:exit(1)
  return b:stop().samples
end

function M.scenarios.wheelspin()
  local b = M.builder():launch()
  b:go(1, { speed = 75 })
  b:drift(0.1, 35, { speed = 75 })
  b:go(6, { speed = 35, rearSR = 0.9, throttle = 1 })
  b:exit(1)
  return b:stop().samples
end

function M.scenarios.out_of_lock()
  local b = M.builder():launch()
  b:drift(1, 35)
  b:go(0.4, { steer = -0.98 })
  b:go(2.5, { slip = 60 })
  b:go(0.6, { slip = 100, steer = -1 })
  return b:hold(0.5).samples
end

function M.scenarios.hot_pressure()
  local b = M.builder({ pressureR = 28 }):launch()
  for i = 1, 4 do
    b:drift(6, i % 2 == 1 and 35 or -35, { pressureR = 28 + i * 2.2 })
    b:exit(1)
    b:hold(1)
  end
  return b:stop().samples
end

return M
