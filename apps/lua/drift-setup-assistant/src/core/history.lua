-- F12 (and the bookkeeping behind F8/F9): versions per car and track, which
-- one is loaded, the runs driven on each, and changes the driver reverted.

local util = require('src/core/util')

local M = {}

M.MAX_RUNS = 200

function M.new(car, track)
  return { car = car, track = track, versions = {}, runs = {}, blocked = {}, activeN = nil }
end

function M.get(h, n)
  for _, v in ipairs(h.versions) do if v.n == n then return v end end
  return nil
end

function M.findByFile(h, file)
  if not file then return nil end
  for _, v in ipairs(h.versions) do
    if v.file and v.file:lower() == file:lower() then return v end
  end
  return nil
end

function M.active(h)
  return h.activeN ~= nil and M.get(h, h.activeN) or nil
end

local function sameValues(a, b)
  for k, v in pairs(a or {}) do if b[k] ~= v then return false end end
  for k, v in pairs(b or {}) do if a[k] ~= v then return false end end
  return true
end

-- The driver's own setup. Stored as version 0 (or reused if already known).
function M.addBase(h, file, values, now)
  for _, v in ipairs(h.versions) do
    if v.kind == 'base' and v.file == file and sameValues(v.values, values) then return v end
  end
  -- A different base replaces the old one; older DSA versions keep their own values.
  for i = #h.versions, 1, -1 do
    if h.versions[i].kind == 'base' then table.remove(h.versions, i) end
  end
  local v = { n = 0, kind = 'base', file = file, values = util.deepcopy(values or {}), createdAt = now }
  table.insert(h.versions, 1, v)
  return v
end

-- fields: { n, file, parent, kind ('change'|'baseline'|'revert'|'final'), change, symptomId, symptomName, values }
function M.addVersion(h, fields, now)
  local v = util.deepcopy(fields)
  v.createdAt = now
  h.versions[#h.versions + 1] = v
  table.sort(h.versions, function(a, b) return a.n < b.n end)
  return v
end

function M.setActive(h, n) h.activeN = n end

function M.setVerdict(h, n, verdict)
  local v = M.get(h, n)
  if v then v.verdict = verdict end
end

-- extra: { excluded = bool, mistakes = { {kind, t, text} } }. Excluded runs are
-- kept for the log but never count toward tuning or comparisons.
function M.addRun(h, n, metrics, feedback, now, extra)
  local r = { version = n, metrics = metrics, feedback = feedback or {}, at = now }
  if extra then r.excluded, r.mistakes = extra.excluded or nil, extra.mistakes end
  h.runs[#h.runs + 1] = r
  while #h.runs > M.MAX_RUNS do table.remove(h.runs, 1) end
  return r
end

function M.runsFor(h, n, includeExcluded)
  local out = {}
  for _, r in ipairs(h.runs) do
    if r.version == n and (includeExcluded or not r.excluded) then out[#out + 1] = r end
  end
  return out
end

function M.metricsFor(h, n)
  local out = {}
  for _, r in ipairs(M.runsFor(h, n)) do out[#out + 1] = r.metrics end
  return out
end

function M.feedbackFor(h, n)
  local out = {}
  for _, r in ipairs(M.runsFor(h, n)) do
    for _, f in ipairs(r.feedback or {}) do out[#out + 1] = f end
  end
  return out
end

-- A version's changes as a list. Versions saved before multi-change support
-- have a single `change` plus `symptomId`.
function M.changesOf(v)
  if not v then return {} end
  if v.changes then return v.changes end
  if v.change then
    local c = util.deepcopy(v.change)
    c.symptomId = c.symptomId or v.symptomId
    c.symptomName = c.symptomName or v.symptomName
    return { c }
  end
  return {}
end

-- The changes that produced the active version, with its verdict, for the recommender.
function M.lastChanges(h)
  local v = M.active(h)
  local out = {}
  for _, c in ipairs(M.changesOf(v)) do
    out[#out + 1] = { lever = c.lever, direction = c.direction, verdict = v.verdict }
  end
  return out
end

function M.block(h, lever, direction, symptomId)
  for _, b in ipairs(h.blocked) do
    if b.lever == lever and b.direction == direction then return end
  end
  h.blocked[#h.blocked + 1] = { lever = lever, direction = direction, symptomId = symptomId }
end

function M.isBlockedFn(h)
  return function(lever, direction)
    for _, b in ipairs(h.blocked) do
      if b.lever == lever and b.direction == direction then return true end
    end
    return false
  end
end

-- Reverting to `targetN` blocks every change made after it on the path to the
-- active version, so the recommender doesn't suggest them again straight away.
function M.revert(h, targetN)
  local target = M.get(h, targetN)
  if not target then return nil end
  local v = M.active(h)
  local guard = 0
  while v and v.n ~= targetN and guard < 100 do
    local changes = M.changesOf(v)
    for _, c in ipairs(changes) do M.block(h, c.lever, c.direction, c.symptomId) end
    if #changes > 0 and v.verdict ~= 'worse' then v.verdict = 'reverted' end
    v = v.parent and M.get(h, v.parent) or nil
    guard = guard + 1
  end
  h.activeN = targetN
  return target
end

function M.maxN(h)
  local max = 0
  for _, v in ipairs(h.versions) do if v.n > max then max = v.n end end
  return max
end

-- Session start -----------------------------------------------------------------
-- h.start = { mode = 'baseline' | 'own', version = n, needed = 3 } once the driver
-- has chosen how to begin; h.calibrated is set after the first evaluation.

-- Histories from before this existed (already tuning) skip the start choice.
function M.migrate(h)
  if h.start == nil and #h.versions > 1 then
    h.start = { mode = 'own', version = h.activeN or 0, needed = 0 }
    h.calibrated = true
  end
  return h
end

function M.setStart(h, mode, n, needed)
  h.start = { mode = mode, version = n, needed = needed or 3 }
  h.calibrated = false
end

-- Counted runs on the starting version so far, and how many are needed.
function M.calibration(h)
  local needed = h.start and h.start.needed or 3
  local n = h.start and h.start.version or h.activeN
  return #M.runsFor(h, n), needed, n
end

return M
