-- F4 (part 2): scores every symptom in rules.json from run metrics, driver
-- feedback and profile. Telemetry detects, feedback confirms and sets priority.

local util = require('src/core/util')

local M = {}

local function feedbackMatches(rule, feedback)
  if not rule.feedback or not feedback then return false end
  for _, f in ipairs(feedback) do
    if util.contains(rule.feedback, f) then return true end
  end
  return false
end

local function profileAllows(rule, profile)
  if not rule.requiresProfile then return true end
  for k, v in pairs(rule.requiresProfile) do
    if not profile or profile[k] ~= v then return false end
  end
  return true
end

local function profileFactor(rules, ruleId, profile)
  local mods, factor = rules.profileModifiers, 1
  if not mods or not profile then return 1 end
  for field, byValue in pairs(mods) do
    local value = profile[field]
    local entry = value and byValue[value]
    if entry and entry[ruleId] then factor = factor * entry[ruleId] end
  end
  return factor
end

-- Returns a list of { id, rule, confidence, telemetry, confirmed, fired, metricValue }
-- ranked most important first. `feedback` is a list of option ids (may be empty).
function M.evaluate(rules, metrics, feedback, profile)
  local conf = rules.confidence or {}
  local wT, wF = conf.telemetryWeight or 0.85, conf.feedbackWeight or 0.55
  local feltGood = feedback and util.contains(feedback, 'felt_good')
  local groupRank = {}
  for i, g in ipairs(rules.groups or { 'safety', 'balance', 'fine' }) do groupRank[g] = i end

  local out = {}
  for _, rule in ipairs(rules.symptoms) do
    local value = metrics[rule.metric]
    local tele = 0
    if type(value) == 'number' then tele = util.ramp(value, rule.warn, rule.full) end
    local confirmed = feedbackMatches(rule, feedback)
    local c = 1 - (1 - wT * tele) * (1 - wF * (confirmed and 1 or 0))
    c = c * profileFactor(rules, rule.id, profile)
    if feltGood then c = c * (1 - (conf.feltGoodDamping or 0.3)) end
    if rule.requiresFeedback and not confirmed then c = 0 end
    if not profileAllows(rule, profile) then c = 0 end
    c = util.clamp(c, 0, 1)
    out[#out + 1] = {
      id = rule.id,
      rule = rule,
      name = rule.name,
      group = rule.group,
      groupRank = groupRank[rule.group] or 99,
      metricValue = value,
      telemetry = tele,
      confirmed = confirmed,
      confidence = c,
      fired = c >= (rule.threshold or conf.defaultThreshold or 0.5),
    }
  end

  local byId = {}
  for _, s in ipairs(out) do byId[s.id] = s end
  -- `outranks`: a fired symptom whose telemetry is strong enough takes the other's place.
  for _, s in ipairs(out) do
    local o = s.rule.outranks
    local other = o and byId[o.symptom]
    if other and s.fired and other.fired and s.telemetry >= (o.minTelemetry or 0.5) then
      s.groupRank = math.min(s.groupRank, other.groupRank)
      s.outranked = other.id
    end
  end

  table.sort(out, function(a, b)
    if a.fired ~= b.fired then return a.fired end
    if a.groupRank ~= b.groupRank then return a.groupRank < b.groupRank end
    if (a.outranked == b.id) ~= (b.outranked == a.id) then return a.outranked == b.id end
    if a.confirmed ~= b.confirmed then return a.confirmed end
    return a.confidence > b.confidence
  end)
  return out
end

function M.fired(list)
  local out = {}
  for _, s in ipairs(list) do if s.fired then out[#out + 1] = s end end
  return out
end

return M
