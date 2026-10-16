-- F9: before/after comparison of runs on the old and new setup.

local util = require('src/core/util')

local M = {}

-- Metrics shown in the comparison table. `better` is the direction that's good.
M.KEY_METRICS = {
  { key = 'avgAngle',    label = 'Average angle',     unit = '°',  better = 'higher' },
  { key = 'angleStd',    label = 'Angle consistency (spread)', unit = '°', better = 'lower' },
  { key = 'driftShare',  label = 'Time spent drifting', unit = '%', better = 'higher', scale = 100 },
  { key = 'spinOut',     label = 'Spin rate',         unit = '%',  better = 'lower', scale = 100 },
  { key = 'avgDriftSpeed', label = 'Drift speed',     unit = ' km/h', better = 'higher' },
}

local function avgOf(list, key)
  local vals = {}
  for _, m in ipairs(list) do
    if type(m[key]) == 'number' then vals[#vals + 1] = m[key] end
  end
  if #vals == 0 then return nil end
  return util.mean(vals)
end

local function lastN(list, n)
  local out = {}
  for i = math.max(1, #list - n + 1), #list do out[#out + 1] = list[i] end
  return out
end

-- before/after: lists of per-run metrics tables (oldest first).
-- targets: the symptom rule the change targeted, or a list of them when one
-- version fixed several problems (nil or empty for a baseline).
-- feedbackAfter: list of feedback ids given on the new setup.
function M.compare(rules, before, after, targets, feedbackAfter)
  if targets and targets.id then targets = { targets } end
  targets = targets or {}
  local cfg = rules.compare or {}
  local n = cfg.runs or 3
  before, after = lastN(before, n), lastN(after, n)
  local result = { rows = {}, runsBefore = #before, runsAfter = #after }
  if #before == 0 or #after == 0 then
    result.verdict = 'not_enough'
    result.text = 'Drive at least one run on each setup to compare them.'
    return result
  end

  -- One row per targeted problem; the overall improvement is their average.
  result.primaries = {}
  local improvements = {}
  for _, rule in ipairs(targets) do
    local b, a = avgOf(before, rule.metric), avgOf(after, rule.metric)
    local row = { key = rule.metric, label = rule.name, before = b, after = a, better = 'lower' }
    if b ~= nil and a ~= nil then
      local floor = math.max(math.abs(rule.warn or 0), 1e-6)
      row.improvement = (b - a) / math.max(math.abs(b), floor)
      improvements[#improvements + 1] = row.improvement
    end
    result.primaries[#result.primaries + 1] = row
  end
  result.primary = result.primaries[1]
  if #improvements > 0 then result.improvement = util.mean(improvements) end

  for _, km in ipairs(M.KEY_METRICS) do
    local b, a = avgOf(before, km.key), avgOf(after, km.key)
    if b ~= nil and a ~= nil then
      local better = km.better == 'higher' and a > b or km.better == 'lower' and a < b
      result.rows[#result.rows + 1] = { key = km.key, label = km.label, unit = km.unit, scale = km.scale or 1,
        before = b, after = a, better = better, same = math.abs(a - b) < 1e-6 }
    end
  end

  local score = result.improvement or 0
  for _, rule in ipairs(targets) do
    for _, f in ipairs(feedbackAfter or {}) do
      if rule.feedback and util.contains(rule.feedback, f) then score = score - 0.1 end
    end
  end
  if feedbackAfter and util.contains(feedbackAfter, 'felt_good') then score = score + 0.1 end

  -- Safety: more spins than before is always a bad sign, whatever the target was.
  local spinsB, spinsA = avgOf(before, 'spinOut') or 0, avgOf(after, 'spinOut') or 0
  local targetedSpin = false
  for _, rule in ipairs(targets) do if rule.id == 'spin' then targetedSpin = true end end
  local newSpins = not targetedSpin and spinsA - spinsB >= 0.34

  if newSpins or score <= (cfg.worseImprovement or -0.15) then
    result.verdict = 'worse'
  elseif score >= (cfg.helpedImprovement or 0.15) then
    result.verdict = 'helped'
  else
    result.verdict = 'unclear'
  end
  result.score = score
  result.newSpins = newSpins

  local few = (#before < 2 or #after < 2) and ' (based on only a few runs, so drive another to be sure)' or ''
  if result.verdict == 'helped' then
    local what = ''
    if #targets == 1 then what = ': ' .. targets[1].name:lower() .. ' happened less' end
    result.text = (#targets > 1 and 'The changes helped' or 'The change helped') .. what .. few .. '.'
  elseif result.verdict == 'worse' then
    result.text = (newSpins and 'You spun more on the new setup' or (#targets > 1 and 'The changes made things worse' or 'The change made things worse')) .. few .. '. You can revert to the previous version.'
  else
    result.text = 'No clear difference yet' .. few .. '. Try another run or two before deciding.'
  end
  return result
end

return M
