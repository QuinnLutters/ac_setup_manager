-- Regenerates the synthetic CSV logs in spec/fixtures/logs from spec/helpers/sim.lua.
-- Replace or add to these with real logs from playtests (apps/lua/drift-setup-assistant/logs).
--
--   luajit tools/make_fixtures.lua

package.path = 'apps/lua/drift-setup-assistant/?.lua;spec/?.lua;' .. package.path

local sim = require('helpers/sim')
local csv = require('src/core/csv')

os.execute('mkdir -p spec/fixtures/logs')
local names = {}
for name in pairs(sim.scenarios) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
  local path = 'spec/fixtures/logs/' .. name .. '.csv'
  local f = assert(io.open(path, 'wb'))
  f:write('# synthetic ' .. name .. ' run from spec/helpers/sim.lua\n')
  f:write(csv.encode(sim.scenarios[name]()))
  f:close()
  print('wrote ' .. path)
end
