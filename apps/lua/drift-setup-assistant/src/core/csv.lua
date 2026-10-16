-- CSV run logs. One row per telemetry sample, so a recorded run can be fed
-- back through the recorder and rule engine outside the game.

local util = require('src/core/util')

local M = {}

local WHEELS = { 'FL', 'FR', 'RL', 'RR' }
M.WHEELS = WHEELS

M.COLUMNS = { 't', 'speed', 'slip', 'yawRate', 'steer', 'steerDeg', 'throttle', 'brake', 'handbrake', 'clutch', 'gear', 'rpm',
  'collided', 'offTrack' }
for _, prefix in ipairs({ 'slipAngle', 'slipRatio', 'ndSlip', 'load', 'temp', 'pressure', 'susp' }) do
  for _, w in ipairs(WHEELS) do M.COLUMNS[#M.COLUMNS + 1] = prefix .. w end
end

function M.encode(samples, columns)
  columns = columns or M.COLUMNS
  local out = { table.concat(columns, ',') }
  for _, s in ipairs(samples) do
    local row = {}
    for i, c in ipairs(columns) do
      local v = s[c]
      row[i] = v == nil and '' or (type(v) == 'number' and util.fmt(v, 4) or tostring(v))
    end
    out[#out + 1] = table.concat(row, ',')
  end
  return table.concat(out, '\n') .. '\n'
end

function M.decode(text)
  local lines = {}
  for line in text:gmatch('[^\r\n]+') do
    if not line:match('^%s*#') then lines[#lines + 1] = line end
  end
  if #lines == 0 then return {} end
  local header = util.split(lines[1], ',')
  local samples = {}
  for i = 2, #lines do
    local cells = util.split(lines[i], ',')
    local s = {}
    for j, name in ipairs(header) do
      local cell = cells[j]
      if cell and cell ~= '' then s[util.trim(name)] = tonumber(cell) or cell end
    end
    samples[#samples + 1] = s
  end
  return samples
end

-- One summary row per run, for the session log.
M.SUMMARY_COLUMNS = { 'run', 'version', 'endReason', 'totalTime', 'driftTime', 'segments', 'avgAngle',
  'maxAngle', 'angleStd', 'avgDriftSpeed', 'spinScore', 'straightenRatio', 'failedEntryRatio', 'wheelspinRatio',
  'lowRpmRatio', 'frontWashRatio', 'lockLimitRatio', 'transitionYawAccel', 'bottomingRatio',
  'pressureWorstDelta', 'feedback', 'mistakes', 'topSymptom' }

return M
