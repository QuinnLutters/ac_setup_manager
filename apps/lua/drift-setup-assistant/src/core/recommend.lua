-- F6: turns a diagnosis into exactly one setup change, clamped to the car's
-- MIN/MAX/STEP. Left and right items of a lever move together as a pair.

local util = require('src/core/util')
local catalog = require('src/core/catalog')
local items = require('src/core/setup_items')

local M = {}

local function conditionsHold(conds, metrics, profile)
  for _, c in ipairs(conds or {}) do
    local v
    if c.metric then v = metrics and metrics[c.metric] elseif c.profile then v = profile and profile[c.profile] end
    if v == nil then return false end
    if type(v) ~= type(c.value) then return false end
    if not util.compare(v, c.op, c.value) then return false end
  end
  return true
end

local function leverLabel(lever)
  local info = catalog.LEVERS[lever]
  return info and info.label or lever
end

local function directionLabel(lever, direction)
  local info = catalog.LEVERS[lever]
  if not info then return direction > 0 and 'up' or 'down' end
  return direction > 0 and (info.plus or 'up') or (info.minus or 'down')
end

M.directionLabel = directionLabel
M.leverLabel = leverLabel

local REASONS = {
  not_exposed = '%s isn\'t adjustable on this car.',
  ratio_list = '%s uses gear-ratio files, which the app can\'t adjust safely yet.',
  no_value = 'Couldn\'t read the current value of %s, so it can\'t be changed safely.',
  at_max = '%s is already at its maximum.',
  at_min = '%s is already at its minimum.',
  at_target = '%s is already at or past the target value.',
  reverted_before = 'You reverted this %s change before, so it\'s skipped.',
  would_undo = 'Changing %s now would undo your last change before we know if it helped.',
}

function M.reasonText(reason, lever)
  local fmt = REASONS[reason] or '%s can\'t be changed.'
  return string.format(fmt, leverLabel(lever))
end

-- Works out the new values for one candidate change. Returns plan or nil, reason.
function M.planChange(rules, change, leverGroups, metrics)
  local g = leverGroups[change.lever]
  if not g then return nil, 'not_exposed' end
  local usable, sawList = {}, false
  for _, item in ipairs(g.items) do
    if item.kind == 'list' then sawList = true
    elseif item.value ~= nil then usable[#usable + 1] = item end
  end
  if #usable == 0 then return nil, sawList and 'ratio_list' or 'no_value' end

  local cfg = rules.change or {}
  local rows, moved = {}, false
  for _, item in ipairs(usable) do
    local rawDir = change.direction * (item.invert and -1 or 1)
    local range = item.max - item.min
    local target
    if change.to then
      target = change.to
    elseif change.toFraction then
      target = item.min + change.toFraction * range
      if item.invert then target = item.max - change.toFraction * range end
    else
      local steps = change.steps
      if change.stepsFromMetric and metrics and metrics[change.stepsFromMetric] then
        steps = math.ceil(math.abs(metrics[change.stepsFromMetric]) / item.step - 1e-9)
      end
      local explicit = steps ~= nil
      steps = steps or 1
      local minFrac = change.minFractionOfRange or cfg.minFractionOfRange or 0
      local maxFrac = change.maxFractionOfRange or cfg.maxFractionOfRange or 1
      local minSteps = math.ceil(minFrac * range / item.step - 1e-9)
      local maxSteps = math.max(1, math.floor(maxFrac * range / item.step + 1e-9))
      if not explicit or change.stepsFromMetric then steps = math.max(steps, minSteps) end
      steps = util.clamp(steps, 1, maxSteps)
      target = item.value + rawDir * steps * item.step
    end
    local newValue = items.snap(item, target)
    local delta = newValue - item.value
    local movesRightWay = delta * rawDir > 1e-9
    if not movesRightWay then newValue = item.value end
    if movesRightWay then moved = true end
    rows[#rows + 1] = {
      name = item.name, label = item.label, side = item.side,
      from = item.value, to = newValue, moved = movesRightWay,
      fromDisplay = items.display(item, item.value), toDisplay = items.display(item, newValue),
    }
  end
  if not moved then
    if change.to or change.toFraction then return nil, 'at_target' end
    local rawDir = change.direction * (usable[1].invert and -1 or 1)
    return nil, rawDir > 0 and 'at_max' or 'at_min'
  end
  return {
    lever = change.lever,
    label = leverLabel(change.lever),
    direction = change.direction,
    directionLabel = directionLabel(change.lever, change.direction),
    items = rows,
    paired = #rows > 1,
  }
end

function M.describe(plan)
  local first = plan.items[1]
  local parts = {}
  for _, r in ipairs(plan.items) do
    if r.moved then parts[#parts + 1] = r.fromDisplay .. ' → ' .. r.toDisplay end
  end
  local valueText = parts[1] or ''
  if plan.paired and #parts > 1 and parts[1] ~= parts[2] then valueText = table.concat(parts, ', ') end
  return string.format('%s: %s (%s%s)', plan.label, plan.directionLabel, valueText,
    plan.paired and ', left and right' or ''), first
end

-- history: optional { lastChange = { lever, direction, verdict }, isBlocked = function(lever, direction) }
-- Returns one of:
--   { kind = 'change', symptom, plan, why, feel, glossary, blocked = {...}, limited = {...} }
--   { kind = 'advice', limited = {...} }   every fired symptom is out of levers on this car
--   { kind = 'done' }                       driver said "felt good" and nothing fired
--   { kind = 'none' }                       nothing fired, no feedback
function M.recommend(rules, diagnosisList, leverGroups, opts)
  opts = opts or {}
  local history, metrics, profile = opts.history, opts.metrics or {}, opts.profile
  local limited = {}
  local anyFired = false

  for _, s in ipairs(diagnosisList) do
    if s.fired then
      anyFired = true
      local blocked = {}
      for _, change in ipairs(s.rule.changes or {}) do
        if conditionsHold(change.when, metrics, profile) then
          local skip
          if history and history.isBlocked and history.isBlocked(change.lever, change.direction) then
            skip = 'reverted_before'
          end
          local last = history and history.lastChange
          if not skip and last and last.lever == change.lever and last.direction == -change.direction
            and last.verdict ~= 'worse' then
            skip = 'would_undo'
          end
          local plan, reason
          if not skip then plan, reason = M.planChange(rules, change, leverGroups, metrics) end
          reason = skip or reason
          if plan then
            return {
              kind = 'change',
              symptom = s,
              plan = plan,
              summary = M.describe(plan),
              why = s.rule.why,
              feel = s.rule.feel,
              glossary = s.rule.glossary,
              blocked = blocked,
              limited = limited,
            }
          end
          blocked[#blocked + 1] = { lever = change.lever, reason = reason, text = M.reasonText(reason, change.lever) }
        end
      end
      limited[#limited + 1] = { symptom = s, blocked = blocked, advice = s.rule.limitAdvice }
    end
  end

  if anyFired then return { kind = 'advice', limited = limited } end
  if opts.feedback and util.contains(opts.feedback, 'felt_good') then return { kind = 'done' } end
  return { kind = 'none' }
end

return M
