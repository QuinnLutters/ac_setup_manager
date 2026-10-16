-- AC-style INI parsing and writing, order-preserving so a setup file we write
-- looks like the one the game wrote.
--
-- Parsed shape: { order = { 'SEC1', 'SEC2' }, sections = { SEC1 = { order = {'KEY'}, values = { KEY = 'raw' } } } }

local util = require('src/core/util')

local M = {}

function M.new()
  return { order = {}, sections = {} }
end

function M.parse(text)
  local ini = M.new()
  local current
  for rawLine in (text .. '\n'):gmatch('([^\n]*)\n') do
    local line = rawLine:gsub('\r$', '')
    -- AC treats ';' and '//' as comment starters.
    line = line:gsub('%s*;.*$', ''):gsub('%s*//.*$', '')
    line = util.trim(line)
    if line ~= '' then
      local name = line:match('^%[(.-)%]$')
      if name then
        current = M.section(ini, util.trim(name))
      elseif current then
        local k, v = line:match('^([^=]+)=(.*)$')
        if k then M.set(ini, current.name, util.trim(k), util.trim(v)) end
      end
    end
  end
  return ini
end

function M.section(ini, name)
  local s = ini.sections[name]
  if not s then
    s = { name = name, order = {}, values = {} }
    ini.sections[name] = s
    ini.order[#ini.order + 1] = name
  end
  return s
end

function M.set(ini, sectionName, key, value)
  local s = M.section(ini, sectionName)
  if s.values[key] == nil then s.order[#s.order + 1] = key end
  s.values[key] = tostring(value)
end

function M.get(ini, sectionName, key, default)
  local s = ini.sections[sectionName]
  local v = s and s.values[key]
  if v == nil then return default end
  if type(default) == 'number' then return tonumber(v) or default end
  return v
end

function M.serialize(ini, headerComment)
  local out = {}
  if headerComment then
    for line in (headerComment .. '\n'):gmatch('([^\n]*)\n') do out[#out + 1] = '; ' .. line end
    out[#out + 1] = ''
  end
  for _, name in ipairs(ini.order) do
    local s = ini.sections[name]
    out[#out + 1] = '[' .. name .. ']'
    for _, k in ipairs(s.order) do out[#out + 1] = k .. '=' .. s.values[k] end
    out[#out + 1] = ''
  end
  return table.concat(out, '\n')
end

-- Converts CSP's ac.INIConfig.sections shape ({ SEC = { KEY = { 'v1', ... } } })
-- into ours. Order is lost there, so sort for stable output.
function M.fromCspSections(sections)
  local ini = M.new()
  for _, name in ipairs(util.keys(sections)) do
    M.section(ini, name)
    local sec = sections[name]
    for _, k in ipairs(util.keys(sec)) do
      local v = sec[k]
      if type(v) == 'table' then v = table.concat(v, ',') end
      M.set(ini, name, k, v)
    end
  end
  return ini
end

return M
