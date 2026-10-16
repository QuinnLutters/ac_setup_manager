-- Facade over the pure core: rules loading/validation and the run -> metrics
-- -> diagnosis -> recommendation pipeline. Used in game and by tests/tools.

local json = require('src/core/json')
local catalog = require('src/core/catalog')
local recorder = require('src/core/recorder')
local metrics = require('src/core/metrics')
local diagnosis = require('src/core/diagnosis')
local recommend = require('src/core/recommend')
local csv = require('src/core/csv')
local glossary = require('src/core/glossary')
local util = require('src/core/util')

local M = {}

-- Returns a list of problems; empty means the rules are usable.
function M.validate(rules)
  local errs = {}
  local function err(fmt, ...) errs[#errs + 1] = string.format(fmt, ...) end
  if type(rules) ~= 'table' then return { 'rules is not an object' } end
  if type(rules.symptoms) ~= 'table' or #rules.symptoms == 0 then err('rules.symptoms must be a non-empty list') return errs end
  local groups = rules.groups or { 'safety', 'balance', 'fine' }
  local seen = {}
  for i, s in ipairs(rules.symptoms) do
    local where = 'symptom ' .. (s.id or ('#' .. i))
    if not s.id then err('%s: missing id', where) end
    if s.id and seen[s.id] then err('%s: duplicate id', where) end
    if s.id then seen[s.id] = true end
    if not s.metric then err('%s: missing metric', where) end
    if type(s.warn) ~= 'number' or type(s.full) ~= 'number' then err('%s: warn and full must be numbers', where) end
    if not util.contains(groups, s.group) then err('%s: unknown group %s', where, tostring(s.group)) end
    if not s.why or not s.feel then err('%s: needs why and feel text', where) end
    if s.glossary and not glossary.get(s.glossary) then err('%s: unknown glossary term %s', where, s.glossary) end
    for j, c in ipairs(s.changes or {}) do
      if not catalog.LEVERS[c.lever] then err('%s change %d: unknown lever %s', where, j, tostring(c.lever)) end
      if c.direction ~= 1 and c.direction ~= -1 then err('%s change %d: direction must be 1 or -1', where, j) end
    end
  end
  for _, s in ipairs(rules.symptoms) do
    if s.outranks and not seen[s.outranks.symptom] then
      err('symptom %s: outranks unknown symptom %s', s.id, tostring(s.outranks.symptom))
    end
  end
  for i, b in ipairs(rules.baseline or {}) do
    if not catalog.LEVERS[b.lever] then err('baseline %d: unknown lever %s', i, tostring(b.lever)) end
  end
  return errs
end

function M.loadRules(text)
  local ok, rules = pcall(json.decode, text)
  if not ok then return nil, { tostring(rules) } end
  local errs = M.validate(rules)
  if #errs > 0 then return nil, errs end
  return rules
end

function M.feedbackOptions(rules, profile)
  local out = {}
  for _, o in ipairs(rules.feedbackOptions or {}) do
    local ok = true
    for k, v in pairs(o.profile or {}) do
      if not profile or profile[k] ~= v then ok = false end
    end
    if ok then out[#out + 1] = o end
  end
  return out
end

function M.newRecorder(rules)
  return recorder.new(rules.detection)
end

function M.analyzeRun(rules, run, ctx)
  local cfg = util.deepcopy(rules.metrics or {})
  cfg.enterAngle = rules.detection and rules.detection.enterAngle or cfg.enterAngle
  return metrics.compute(run, ctx, cfg)
end

function M.diagnose(rules, m, feedback, profile)
  return diagnosis.evaluate(rules, m, feedback or {}, profile)
end

function M.recommend(rules, diag, leverGroups, opts)
  return recommend.recommend(rules, diag, leverGroups, opts)
end

-- Replays a CSV log through the recorder. Returns the list of finished runs.
function M.runsFromCsv(rules, text)
  local samples = csv.decode(text)
  local rec = M.newRecorder(rules)
  local runs = {}
  for _, s in ipairs(samples) do
    local run = rec:push(s)
    if run then runs[#runs + 1] = run end
  end
  if #samples > 0 then
    local run = rec:abort(samples[#samples].t, 'log_end')
    if run then runs[#runs + 1] = run end
  end
  return runs
end

-- Full pipeline for one run. Returns { metrics, diagnosis, recommendation }.
function M.pipeline(rules, run, ctx, leverGroups, opts)
  opts = opts or {}
  local m = M.analyzeRun(rules, run, ctx)
  local d = M.diagnose(rules, m, opts.feedback, opts.profile)
  local r = M.recommend(rules, d, leverGroups, {
    history = opts.history, metrics = m, profile = opts.profile, feedback = opts.feedback,
  })
  return { metrics = m, diagnosis = d, recommendation = r }
end

return M
