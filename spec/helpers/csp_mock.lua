-- A stand-in for the parts of the CSP Lua API the app uses, so the game layer
-- and UI can be exercised outside Assetto Corsa. It is not a full emulation:
-- it exists to catch nil errors and logic bugs in the glue code. Real field
-- names still have to be confirmed in game (milestone 0).

local ini = require('src/core/ini')

local M = {}

local function sh(cmd) return os.execute(cmd) end
local function q(path) return "'" .. path:gsub("'", "'\\''") .. "'" end

function M.read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local t = f:read('*a'); f:close(); return t
end

local function write(path, text)
  local f = io.open(path, 'wb'); f:write(text); f:close()
end

local function toCsp(parsed)
  local sections = {}
  for _, name in ipairs(parsed.order) do
    local sec = {}
    for k, v in pairs(parsed.sections[name].values) do sec[k] = { v } end
    sections[name] = sec
  end
  return { sections = sections }
end

-- vec2 / vec3 / rgbm -----------------------------------------------------------

local V2 = {}
V2.__index = V2
V2.__add = function(a, b) return vec2(a.x + b.x, a.y + b.y) end
V2.__sub = function(a, b) return vec2(a.x - b.x, a.y - b.y) end
function vec2(x, y) return setmetatable({ x = x or 0, y = y or 0 }, V2) end
function rgbm(r, g, b, m) return { r = r, g = g, b = b, mult = m } end

-- Setup ---------------------------------------------------------------------------

-- opts: { carFixture, setupHook = bool, currentSetupApi = bool, online = bool }
function M.install(opts)
  opts = opts or {}
  local root = os.tmpname()
  os.remove(root)
  sh('mkdir -p ' .. q(root .. '/app') .. ' ' .. q(root .. '/docs/setups'))
  sh('cp apps/lua/drift-setup-assistant/rules.json ' .. q(root .. '/app/rules.json'))

  local state = {
    root = root,
    appDir = root .. '/app',
    setupsDir = root .. '/docs/setups',
    sample = { t = 0, speed = 0, slip = 0, steer = 0, throttle = 0, brake = 0, handbrake = 0, clutch = 0, gear = 3, rpm = 6000 },
    inPits = false,
    loadedSetup = nil,      -- parsed ini of the setup "loaded in the car"
    logs = {},
    texts = {},
    clicks = {},
    setupHookFn = nil,
  }
  M.state = state

  local fixtureDir = 'spec/fixtures/cars/' .. (opts.carFixture or 'test_drift') .. '/'
  local setupText = assert(M.read(fixtureDir .. 'setup.ini'))
  local current = M.read(fixtureDir .. 'current_setup.ini')
  state.loadedSetup = current and ini.parse(current) or nil
  if current then
    -- The driver has this setup saved as their own file too.
    sh('mkdir -p ' .. q(state.setupsDir .. '/test_drift/test_track'))
    write(state.setupsDir .. '/test_drift/test_track/my_setup.ini', current)
  end

  -- The input method AC writes to Documents/Assetto Corsa/cfg/controls.ini.
  if opts.inputMethod ~= false then
    sh('mkdir -p ' .. q(root .. '/docs/cfg'))
    write(root .. '/docs/cfg/controls.ini', '[HEADER]\nINPUT_METHOD=' .. (opts.inputMethod or 'WHEEL') .. '\n')
  end

  _G.__dirname = state.appDir
  _G.script = {}

  -- io extensions ----------------------------------------------------------------
  io.load = function(path) return M.read(path) end
  io.save = function(path, text) write(path, text); return true end
  io.fileExists = function(path) local f = io.open(path, 'rb'); if f then f:close() return true end return false end
  io.dirExists = function(path) return os.execute('test -d ' .. q(path)) == true or os.execute('test -d ' .. q(path)) == 0 end
  io.createDir = function(path) sh('mkdir -p ' .. q(path)); return true end
  io.scanDir = function(dir, mask, cb)
    local pattern = (mask or '*'):gsub('%.', '%%.'):gsub('%*', '.*')
    local p = io.popen('ls -1 ' .. q(dir) .. ' 2>/dev/null')
    for name in p:lines() do
      if name:match('^' .. pattern .. '$') and cb then cb(name) end
    end
    p:close()
  end

  -- ac ---------------------------------------------------------------------------------
  local wheelsFor = function(s)
    local w = {}
    local names = { 'FL', 'FR', 'RL', 'RR' }
    for i = 0, 3 do
      local n = names[i + 1]
      w[i] = {
        slipAngle = s['slipAngle' .. n] or 0, slipRatio = s['slipRatio' .. n] or 0, ndSlip = s['ndSlip' .. n] or 0,
        load = 3000, tyreCoreTemperature = 80, tyrePressure = s['pressure' .. n] or 27, suspensionTravel = s['susp' .. n] or 0.05,
      }
    end
    return w
  end

  _G.ac = {
    FolderID = { Documents = 1, ACApps = 2 },
    getFolder = function(id) if id == 1 then return root .. '/docs' end return root end,
    getPatchVersionCode = function() return opts.versionCode or 3000 end,
    getSim = function() return { isOnlineRace = opts.online == true, isPaused = false } end,
    getCarID = function() return 'test_drift' end,
    getCarName = function() return 'Test Drift' end,
    getTrackID = function() return 'test_track' end,
    log = function(msg) state.logs[#state.logs + 1] = msg end,
    debug = function() end,
    -- Persists for the whole install, like ac.storage across sessions.
    storage = function(defaults)
      if not state.storage then
        state.storage = {}
        for k, v in pairs(defaults) do state.storage[k] = v end
      end
      return state.storage
    end,
    getCar = function()
      local s = state.sample
      local v = s.speed / 3.6
      local a = math.rad(s.slip)
      return {
        speedKmh = s.speed,
        velocity = { x = math.sin(a) * v, y = 0, z = math.cos(a) * v },
        look = { x = 0, y = 0, z = 1 }, side = { x = 1, y = 0, z = 0 }, up = { x = 0, y = 1, z = 0 },
        localAngularVelocity = { x = 0, y = math.rad(s.yawRate or 0), z = 0 },
        steer = s.steer * 450, steerLock = 450,
        gas = s.throttle, brake = s.brake, handbrake = s.handbrake, clutch = s.clutch, gear = s.gear, rpm = s.rpm,
        rpmLimiter = 8000, position = { x = 0, y = 0, z = 0 },
        isInPitlane = state.inPits, isInPit = state.inPits,
        wheels = wheelsFor(s),
      }
    end,
    INIConfig = {
      carData = function(_, file)
        if file == 'setup.ini' then return toCsp(ini.parse(setupText)) end
        if file == 'tyres.ini' then
          return { sections = { FRONT = { PRESSURE_IDEAL = { '26' } }, REAR = { PRESSURE_IDEAL = { '28' } } } }
        end
        return nil
      end,
    },
  }
  if opts.currentSetupApi ~= false then
    ac.INIConfig.currentSetup = function()
      return state.loadedSetup and toCsp(state.loadedSetup) or nil
    end
  end
  if opts.setupHook then
    ac.onSetupFile = function(fn) state.setupHookFn = fn end
  end

  -- ui: records text, clicks buttons whose label matches a queued click -------
  local function say(s) state.texts[#state.texts + 1] = tostring(s) end
  local function click(label)
    for i, want in ipairs(state.clicks) do
      if tostring(label):find(want, 1, true) then table.remove(state.clicks, i); return true end
    end
    return false
  end
  _G.ui = setmetatable({
    Font = { Title = 1, Small = 2, Main = 3 },
    StyleColor = { Text = 1, Button = 2, ButtonHovered = 3, ButtonActive = 4 },
    TabItemFlags = { SetSelected = 1 },
    text = say, textWrapped = say, textColored = function(s) say(s) end,
    button = function(label) say('[' .. label .. ']'); return click(label) end,
    checkbox = function(label) say('[x] ' .. label); return click(label) end,
    tabBar = function(_, fn) fn() end,
    tabItem = function(label, a, b) say('<' .. label .. '>'); (b or a)() end,
    availableSpaceX = function() return 400 end,
    getCursor = function() return vec2(0, 0) end,
    itemHovered = function() return false end,
  }, { __index = function() return function() end end })

  return state
end

function M.feed(app, samples, dt)
  dt = dt or (1 / 25)
  for _, s in ipairs(samples) do
    M.state.sample = s
    app:update(dt)
  end
end

function M.click(label) M.state.clicks[#M.state.clicks + 1] = label end

function M.render(windowFn)
  M.state.texts = {}
  windowFn(0.016)
  return table.concat(M.state.texts, '\n')
end

function M.cleanup()
  if M.state and M.state.root then os.execute('rm -rf ' .. q(M.state.root)) end
end

return M
