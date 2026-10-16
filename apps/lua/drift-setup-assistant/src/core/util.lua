-- Small helpers shared by the pure core. No ac.* or CSP-only globals here,
-- so everything under src/core runs in plain LuaJIT / Lua 5.1+ for tests.

local M = {}

function M.clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

function M.round(x, decimals)
  local m = 10 ^ (decimals or 0)
  return math.floor(x * m + 0.5) / m
end

function M.sign(x)
  if x > 0 then return 1 elseif x < 0 then return -1 end
  return 0
end

function M.lerp(a, b, t) return a + (b - a) * t end

-- 0 at lo, 1 at hi, clamped. Works for hi < lo too (descending ramps).
function M.ramp(x, lo, hi)
  if hi == lo then return x >= hi and 1 or 0 end
  return M.clamp((x - lo) / (hi - lo), 0, 1)
end

function M.deepcopy(v, seen)
  if type(v) ~= 'table' then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local out = {}
  seen[v] = out
  for k, x in pairs(v) do out[M.deepcopy(k, seen)] = M.deepcopy(x, seen) end
  return out
end

function M.keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
  return out
end

function M.trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

function M.split(s, sep)
  local out, pattern = {}, '([^' .. sep .. ']*)'
  local i = 1
  for piece in (s .. sep):gmatch(pattern .. sep) do out[i] = piece; i = i + 1 end
  return out
end

function M.mean(list)
  if #list == 0 then return 0 end
  local s = 0
  for i = 1, #list do s = s + list[i] end
  return s / #list
end

function M.stddev(list)
  local n = #list
  if n < 2 then return 0 end
  local m, s = M.mean(list), 0
  for i = 1, n do s = s + (list[i] - m) ^ 2 end
  return math.sqrt(s / (n - 1))
end

function M.contains(list, value)
  for i = 1, #list do if list[i] == value then return true end end
  return false
end

-- Formats a number without trailing zeros: 2 -> "2", 2.50 -> "2.5".
function M.fmt(x, decimals)
  if type(x) ~= 'number' then return tostring(x) end
  local s = string.format('%.' .. (decimals or 2) .. 'f', x)
  s = s:gsub('(%..-)0+$', '%1'):gsub('%.$', '')
  if s == '-0' then s = '0' end
  return s
end

function M.compare(a, op, b)
  if a == nil then return false end
  if op == '>' then return a > b
  elseif op == '>=' then return a >= b
  elseif op == '<' then return a < b
  elseif op == '<=' then return a <= b
  elseif op == '==' then return a == b
  elseif op == '~=' or op == '!=' then return a ~= b
  end
  error('unknown operator ' .. tostring(op))
end

return M
