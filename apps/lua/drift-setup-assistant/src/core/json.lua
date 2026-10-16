-- Minimal JSON decode/encode. CSP ships its own JSON, but the rule engine has
-- to load rules.json outside the game too, so we carry a pure-Lua version.

local M = {}

local escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local function decodeError(str, i, msg)
  local line, col = 1, 1
  for j = 1, i - 1 do
    if str:sub(j, j) == '\n' then line = line + 1; col = 1 else col = col + 1 end
  end
  error(string.format('JSON error at line %d col %d: %s', line, col, msg), 0)
end

local function skip(str, i)
  while true do
    local c = str:sub(i, i)
    if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
      i = i + 1
    elseif c == '/' and str:sub(i + 1, i + 1) == '/' then
      -- Allow // comments so rules.json can carry notes for whoever tunes it.
      local e = str:find('\n', i, true)
      i = e and e + 1 or #str + 1
    else
      return i
    end
  end
end

local decodeValue

local function decodeString(str, i)
  local out, j = {}, i + 1
  while true do
    local c = str:sub(j, j)
    if c == '' then decodeError(str, j, 'unterminated string') end
    if c == '"' then return table.concat(out), j + 1 end
    if c == '\\' then
      local e = str:sub(j + 1, j + 1)
      if e == 'u' then
        local hex = str:sub(j + 2, j + 5)
        local code = tonumber(hex, 16) or decodeError(str, j, 'bad unicode escape')
        if code < 0x80 then out[#out + 1] = string.char(code)
        elseif code < 0x800 then
          out[#out + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
        else
          out[#out + 1] = string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
        end
        j = j + 6
      else
        out[#out + 1] = escapes[e] or decodeError(str, j, 'bad escape')
        j = j + 2
      end
    else
      out[#out + 1] = c
      j = j + 1
    end
  end
end

local function decodeArray(str, i)
  local out, n = {}, 0
  i = skip(str, i + 1)
  if str:sub(i, i) == ']' then return out, i + 1 end
  while true do
    local v
    v, i = decodeValue(str, i)
    n = n + 1
    out[n] = v
    i = skip(str, i)
    local c = str:sub(i, i)
    if c == ']' then return out, i + 1 end
    if c ~= ',' then decodeError(str, i, "expected ',' or ']'") end
    i = skip(str, i + 1)
  end
end

local function decodeObject(str, i)
  local out = {}
  i = skip(str, i + 1)
  if str:sub(i, i) == '}' then return out, i + 1 end
  while true do
    if str:sub(i, i) ~= '"' then decodeError(str, i, 'expected string key') end
    local k
    k, i = decodeString(str, i)
    i = skip(str, i)
    if str:sub(i, i) ~= ':' then decodeError(str, i, "expected ':'") end
    local v
    v, i = decodeValue(str, skip(str, i + 1))
    out[k] = v
    i = skip(str, i)
    local c = str:sub(i, i)
    if c == '}' then return out, i + 1 end
    if c ~= ',' then decodeError(str, i, "expected ',' or '}'") end
    i = skip(str, i + 1)
  end
end

decodeValue = function(str, i)
  i = skip(str, i)
  local c = str:sub(i, i)
  if c == '{' then return decodeObject(str, i) end
  if c == '[' then return decodeArray(str, i) end
  if c == '"' then return decodeString(str, i) end
  if str:sub(i, i + 3) == 'true' then return true, i + 4 end
  if str:sub(i, i + 4) == 'false' then return false, i + 5 end
  if str:sub(i, i + 3) == 'null' then return nil, i + 4 end
  local num = str:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
  if num and #num > 0 then return tonumber(num), i + #num end
  decodeError(str, i, "unexpected character '" .. c .. "'")
end

function M.decode(str)
  local v, i = decodeValue(str, 1)
  i = skip(str, i)
  if i <= #str then decodeError(str, i, 'trailing characters') end
  return v
end

local function isArray(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do if t[i] == nil then return false end end
  return true, n
end

local function encodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return map[c] or string.format('\\u%04x', c:byte())
  end) .. '"'
end

local function encode(v, indent, depth)
  local t = type(v)
  if t == 'nil' then return 'null' end
  if t == 'boolean' then return tostring(v) end
  if t == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then return 'null' end
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%d', v) end
    return string.format('%.6g', v)
  end
  if t == 'string' then return encodeString(v) end
  if t ~= 'table' then error('cannot encode ' .. t) end
  local nl = indent and '\n' .. string.rep(indent, depth + 1) or ''
  local close = indent and '\n' .. string.rep(indent, depth) or ''
  local sep = indent and ': ' or ':'
  local arr, n = isArray(v)
  if arr and n > 0 then
    local parts = {}
    for i = 1, n do parts[i] = encode(v[i], indent, depth + 1) end
    return '[' .. nl .. table.concat(parts, ',' .. nl) .. close .. ']'
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  if #keys == 0 then return arr and '[]' or '{}' end
  table.sort(keys)
  local parts = {}
  for i, k in ipairs(keys) do
    local val = v[k]
    if val == nil then val = v[tonumber(k)] end
    parts[i] = encodeString(k) .. sep .. encode(val, indent, depth + 1)
  end
  return '{' .. nl .. table.concat(parts, ',' .. nl) .. close .. '}'
end

function M.encode(v, pretty)
  return encode(v, pretty and '  ' or nil, 0)
end

return M
