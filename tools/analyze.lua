-- Runs the rule engine on a recorded CSV log, outside the game. Use it to tune
-- rules.json thresholds against real runs from playtests.
--
--   luajit tools/analyze.lua <run.csv> [options]
--     --car <dir>        folder with the car's setup.ini (+ optional current_setup.ini)
--     --setup <file>     setup file with the values the car was running
--     --feedback <id>    driver feedback, e.g. spins_out (repeatable)
--     --profile k=v,...  e.g. style=chase,goal=angle
--     --rules <file>     rules file (default: the app's rules.json)
--     --limiter <rpm>    rev limiter, enables the "bogs down" metric
--     --ideal <f>,<r>    ideal hot pressures, enables the pressure metric

package.path = 'apps/lua/drift-setup-assistant/?.lua;' .. package.path

local engine = require('src/core/engine')
local ini = require('src/core/ini')
local items = require('src/core/setup_items')
local util = require('src/core/util')

local function read(path)
  local f = io.open(path, 'rb')
  if not f then io.stderr:write('cannot read ' .. path .. '\n'); os.exit(1) end
  local t = f:read('*a'); f:close(); return t
end

local args = { feedback = {}, profile = {} }
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == '--car' then args.car = arg[i + 1]; i = i + 1
  elseif a == '--setup' then args.setup = arg[i + 1]; i = i + 1
  elseif a == '--feedback' then args.feedback[#args.feedback + 1] = arg[i + 1]; i = i + 1
  elseif a == '--rules' then args.rules = arg[i + 1]; i = i + 1
  elseif a == '--limiter' then args.limiter = tonumber(arg[i + 1]); i = i + 1
  elseif a == '--ideal' then
    local f, r = arg[i + 1]:match('([%d%.]+),([%d%.]+)')
    args.ideal = { front = tonumber(f), rear = tonumber(r) }; i = i + 1
  elseif a == '--profile' then
    for k, v in arg[i + 1]:gmatch('(%w+)=(%w+)') do args.profile[k] = v end
    i = i + 1
  else args.csv = a end
  i = i + 1
end

if not args.csv then
  print('usage: luajit tools/analyze.lua <run.csv> [--car dir] [--feedback id] [--profile k=v,...]')
  os.exit(1)
end

local rules, errs = engine.loadRules(read(args.rules or 'apps/lua/drift-setup-assistant/rules.json'))
if not rules then print('rules.json problems:\n  ' .. table.concat(errs, '\n  ')); os.exit(1) end

local levers = {}
if args.car then
  local setupIni = ini.parse(read(args.car .. '/setup.ini'))
  local values = {}
  local setupPath = args.setup or (args.car .. '/current_setup.ini')
  local f = io.open(setupPath, 'rb')
  if f then values = items.valuesFromSetup(ini.parse(f:read('*a'))); f:close() end
  levers = items.levers(items.build(setupIni, values))
end

local ctx = { rpmLimiter = args.limiter, idealPressure = args.ideal, steerNormalized = true }
local runs = engine.runsFromCsv(rules, read(args.csv))
print(string.format('%s: %d run(s)', args.csv, #runs))

local SHOW = { 'totalTime', 'driftTime', 'segments', 'avgAngle', 'maxAngle', 'angleStd', 'spinScore', 'straightenRatio',
  'failedEntryRatio', 'wheelspinRatio', 'lowRpmRatio', 'frontWashRatio', 'lockLimitRatio', 'transitionYawAccel',
  'bottomingRatio', 'pressureWorstDelta', 'brakeAngleLossRatio' }

for _, run in ipairs(runs) do
  local res = engine.pipeline(rules, run, ctx, levers, { feedback = args.feedback, profile = args.profile })
  print(string.format('\n== Run %d (ended: %s)', run.id, run.endReason))
  for _, k in ipairs(SHOW) do
    local v = res.metrics[k]
    print(string.format('  %-22s %s', k, v == nil and '-' or util.fmt(v, 3)))
  end
  print('  symptoms:')
  for _, s in ipairs(res.diagnosis) do
    if s.confidence > 0 then
      print(string.format('    %s %-22s conf %3d%%  telemetry %3d%%%s', s.fired and '*' or ' ', s.id,
        math.floor(s.confidence * 100 + 0.5), math.floor(s.telemetry * 100 + 0.5), s.confirmed and '  (confirmed)' or ''))
    end
  end
  local r = res.recommendation
  if r.kind == 'change' then
    print('  recommend: ' .. r.summary)
    print('    why:  ' .. r.why)
    for _, b in ipairs(r.blocked) do print('    skipped: ' .. b.text) end
  elseif r.kind == 'advice' then
    for _, l in ipairs(r.limited) do print('  advice (' .. l.symptom.id .. '): ' .. tostring(l.advice)) end
  else
    print('  result: ' .. r.kind)
  end
end
