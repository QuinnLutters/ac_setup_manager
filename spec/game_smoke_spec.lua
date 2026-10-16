-- End-to-end run of the in-game layer against a mocked CSP API: profile,
-- recording, feedback, recommendation, saving, loading, comparing, reverting.

local mock = require('helpers/csp_mock')
local sim = require('helpers/sim')
local ini = require('src/core/ini')

local function fresh(opts)
  for name in pairs(package.loaded) do
    if name:match('^src/game') or name:match('^src/ui') then package.loaded[name] = nil end
  end
  local state = mock.install(opts)
  local App = require('src/game/app')
  local windows = require('src/ui/windows')
  local app = App.new()
  local main = function(dt) windows.main(app, dt) end
  return app, windows, state, main
end

local function answerProfile(main)
  for _, l in ipairs({ 'New to it', 'Solo', 'More stability', 'Start' }) do mock.click(l) end
  mock.render(main)
end

local recommend = require('src/core/recommend')
local history = require('src/core/history')
local function store() return require('src/game/store') end

local function drive(app, samples)
  -- Continue the clock from where the last scenario ended.
  local offset = app.clock
  local shifted = {}
  for i, s in ipairs(samples) do
    local c = {}
    for k, v in pairs(s) do c[k] = v end
    c.t = s.t + offset
    shifted[i] = c
  end
  mock.feed(app, shifted)
end

local function spinRun(app, main)
  drive(app, sim.scenarios.spin())
  mock.click('Spins out'); mock.render(main)
end

-- Start from the current setup and drive the 3 starting runs.
local function calibrate(app, main)
  mock.click('Start from my current setup'); mock.render(main)
  for _ = 1, 3 do spinRun(app, main) end
  assert.equals('evaluated', app.result.kind)
end

local function loadInPits(app, state, text)
  state.loadedSetup = ini.parse(text)
  state.inPits = true
  app.lastLoadCheck = -10
  mock.feed(app, { state.sample })
  state.inPits = false
end

local function wallHit()
  local b = sim.builder():launch()
  b:drift(3, 35)
  b:go(0.25, { speed = 5, slip = 10, throttle = 0, brake = 0 })
  return b:stop().samples
end

describe('game layer (mocked CSP)', function()
  after_each(function() mock.cleanup() end)

  it('loads the entry script and survives a frame of every window', function()
    mock.install()
    dofile('apps/lua/drift-setup-assistant/drift-setup-assistant.lua')
    script.update(0.016)
    script.windowMain(0.016)
    script.windowSettings(0.016)
    script.windowHud(0.016)
    for _, l in ipairs(mock.state.logs) do assert.is_nil(l:match('error'), l) end
  end)

  it('runs the whole loop: profile, start, 3 runs, changes, save, load, compare, revert', function()
    local app, windows, state, main = fresh()

    -- F1 scanner
    assert.equals(20, #app.items)
    assert.equals(4, app.itemsByName.ARB_REAR.value)

    -- F2 first-run questionnaire
    assert.matches('Welcome', mock.render(main))
    answerProfile(main)
    assert.same({ experience = 'beginner', device = 'wheel', style = 'solo', goal = 'stability' }, app.profile)

    -- New car/track: choose where to start.
    local text = mock.render(main)
    assert.matches('How do you want to start%?', text)
    mock.click('Start from my current setup'); mock.render(main)
    assert.equals('own', app.history.start.mode)
    assert.is_nil(mock.render(main):find('How do you want to start?', 1, true))

    -- F3 run recorder + F5 feedback; the first two runs only count toward the start.
    drive(app, sim.scenarios.spin())
    assert.equals('feedback', app.phase)
    assert.equals('spin', app.lastRun.run.endReason)
    text = mock.render(main)
    assert.matches('How did the car feel%?', text)
    assert.matches('%[Spins out%]', text)
    mock.click('Spins out'); mock.render(main)
    assert.equals('calibrating', app.result.kind)
    assert.matches('Starting runs: 1 of 3', mock.render(main))
    spinRun(app, main)
    assert.matches('Starting runs: 2 of 3', mock.render(main))

    -- Third run: all three are evaluated together (F4 + F6 + F7).
    spinRun(app, main)
    assert.equals('evaluated', app.result.kind)
    assert.equals(3, app.result.evaluatedRuns)
    local rec = app.result.recommendation
    assert.equals('changes', rec.kind)
    assert.equals('arb_rear', recommend.checked(rec)[1].plan.lever)
    text = mock.render(main)
    assert.matches('based on your 3 starting runs', text)
    assert.matches('Suggested changes', text)
    assert.matches('Why it helps', text)
    assert.matches('What to feel on the next run', text)
    assert.matches('Term: Side bite', text)
    assert.matches('Save 1 change as new setup', text)

    -- Tick the alternative too: two changes in one version.
    mock.click('##spin:pressure_rear'); mock.render(main)
    assert.equals(2, #recommend.checked(rec))
    assert.matches('Save 2 changes as new setup', mock.render(main))

    -- F8 save as a new versioned file, never overwriting the driver's file
    mock.click('changes as new setup'); mock.render(main)
    local path = state.setupsDir .. '/test_drift/test_track/DSA_test_drift_v1.ini'
    local written = mock.read(path)
    assert.is_string(written)
    local parsed = ini.parse(written)
    assert.equals('3', parsed.sections.ARB_REAR.values.VALUE)
    assert.is_true(tonumber(parsed.sections.PRESSURE_LR.values.VALUE) < 30)
    assert.is_true(app.saved.verified)
    assert.equals(3, #app.saved.diff) -- rear bar + left and right rear pressure
    assert.equals(2, #history.changesOf(app.saved.version))
    assert.equals('4', ini.parse(mock.read(state.setupsDir .. '/test_drift/test_track/my_setup.ini')).sections.ARB_REAR.values.VALUE)
    assert.matches('Load it now', mock.render(main))

    -- Driver loads v1 in the pits; the app notices through the current-setup API.
    loadInPits(app, state, written)
    assert.equals(1, app.history.activeN)
    assert.equals(3, app.itemsByName.ARB_REAR.value)

    -- F9 before/after: after calibration, an update follows every run.
    drive(app, sim.scenarios.good())
    mock.click('Felt good'); mock.render(main)
    local cmp = app.result.compare
    assert.is_table(cmp)
    assert.equals('helped', cmp.verdict)
    assert.equals('done', app.result.recommendation.kind)
    text = mock.render(main)
    assert.matches('Did v1 help%?', text)
    assert.matches('dialled in', text)

    -- F12 history and revert: both changes are blocked afterwards.
    assert.matches('v1  DSA_test_drift_v1.ini', text)
    assert.matches('2 changes', text)
    app:revertTo(0)
    assert.equals(0, app.history.activeN)
    local blocked = history.isBlockedFn(app.history)
    assert.is_true(blocked('arb_rear', -1))
    assert.is_true(blocked('pressure_rear', -1))

    -- History and logs persisted
    assert.is_string(mock.read(state.appDir .. '/data/history/test_drift__test_track.json'))
    local p = io.popen('ls ' .. state.appDir .. '/logs/*/')
    local listing = p:read('*a'); p:close()
    assert.matches('run_1%.csv', listing)
    assert.matches('summary%.csv', listing)

    -- The original setup had no known file name, so the revert wrote a copy to load.
    local hud = function(dt) windows.hud(app, dt) end
    assert.matches('Load DSA_test_drift_v2.ini in the pits', mock.render(hud))
    loadInPits(app, state, mock.read(app.saved.path))
    assert.equals(2, app.history.activeN)
    assert.matches('DSA ready', mock.render(hud))

    -- Settings render
    assert.matches('Diagnostics', mock.render(function(dt) windows.settings(app, dt) end))
  end)

  it('can start from the drift baseline, counting runs only once it is loaded', function()
    local app, _, state, main = fresh()
    answerProfile(main)
    mock.click('Start from a drift baseline'); mock.render(main)
    assert.equals('baseline', app.history.start.mode)
    assert.equals(1, app.history.start.version)
    local written = mock.read(state.setupsDir .. '/test_drift/test_track/DSA_test_drift_v1.ini')
    assert.equals('100', ini.parse(written).sections.DIFF_POWER.values.VALUE)

    -- A run before loading the baseline doesn't count.
    spinRun(app, main)
    assert.matches('Load your starting setup first', mock.render(main))

    loadInPits(app, state, written)
    spinRun(app, main)
    spinRun(app, main)
    assert.equals('calibrating', app.result.kind)
    spinRun(app, main)
    assert.equals('evaluated', app.result.kind)
  end)

  it('keeps existing tuning sessions going without asking how to start', function()
    local app, _, state, main = fresh()
    answerProfile(main)
    calibrate(app, main)
    mock.click('change as new setup'); mock.render(main)
    -- Simulate an older history file (before the start choice existed).
    app.history.start, app.history.calibrated = nil, nil
    store().saveHistory(app.history)
    local app2 = require('src/game/app').new()
    assert.is_false(app2:needsStartChoice())
    assert.is_true(app2.history.calibrated)
  end)

  it('excludes runs with a driver mistake, and lets the driver overrule it', function()
    local app, _, _, main = fresh()
    answerProfile(main)
    mock.click('Start from my current setup'); mock.render(main)

    -- Hit a wall mid-drift: speed gone in a fraction of a second, no brake.
    drive(app, wallHit())
    assert.is_true(app.lastRun.excluded)
    local text = mock.render(main)
    assert.matches('You hit something', text)
    assert.matches("won't count", text)
    mock.click('Spins out'); mock.render(main)
    assert.equals('excluded', app.result.kind)
    assert.equals(0, (history.calibration(app.history)))
    local runs = history.runsFor(app.history, 0, true)
    assert.is_true(runs[#runs].excluded)

    -- Same thing, but the driver says it counts.
    drive(app, wallHit())
    mock.click('Count it anyway'); mock.render(main)
    mock.click('Spins out'); mock.render(main)
    assert.equals('calibrating', app.result.kind)
    assert.equals(1, (history.calibration(app.history)))

    -- A clean run the driver marks as their own mistake.
    drive(app, sim.scenarios.spin())
    assert.is_false(app.lastRun.excluded)
    mock.click("My mistake"); mock.render(main)
    mock.click('Spins out'); mock.render(main)
    assert.equals('excluded', app.result.kind)
    assert.equals(1, (history.calibration(app.history)))
  end)

  it('reads the input device from controls.ini instead of asking', function()
    local _, _, _, main = fresh()
    local text = mock.render(main)
    assert.matches('Three quick questions', text)
    assert.is_nil(text:find('What do you drive with?', 1, true))
    assert.matches('Input device: Wheel', text)
  end)

  it('detects a controller', function()
    local app, _, _, main = fresh({ inputMethod = 'X360' })
    answerProfile(main)
    assert.equals('controller', app.profile.device)
  end)

  it('updates a saved profile when the driver switches device', function()
    local app, _, state, main = fresh()
    answerProfile(main)
    assert.equals('wheel', app.profile.device)
    -- Next session: same saved profile, but the driver now has a controller set up.
    local f = io.open(state.root .. '/docs/cfg/controls.ini', 'wb')
    f:write('[HEADER]\nINPUT_METHOD=X360\n'); f:close()
    package.loaded['src/game/store'] = nil
    package.loaded['src/game/app'] = nil
    local app2 = require('src/game/app').new()
    assert.equals('beginner', app2.profile.experience)
    assert.equals('controller', app2.profile.device)
  end)

  it('falls back to asking when controls.ini is missing', function()
    local app, _, _, main = fresh({ inputMethod = false })
    local text = mock.render(main)
    assert.matches('Four quick questions', text)
    assert.matches('What do you drive with%?', text)
    for _, l in ipairs({ 'New to it', 'Keyboard', 'Solo', 'More stability', 'Start' }) do mock.click(l) end
    mock.render(main)
    assert.equals('keyboard', app.profile.device)
  end)

  it('asks for the base setup when CSP cannot report it', function()
    local app, _, _, main = fresh({ currentSetupApi = false })
    answerProfile(main)
    local text = mock.render(main)
    assert.matches('Which setup are you running%?', text)
    mock.click('my_setup.ini')
    mock.render(main)
    assert.equals(4, app.itemsByName.ARB_REAR.value)
    assert.equals('my_setup.ini', require('src/core/history').active(app.history).file)
  end)

  it('uses the setup-load hook when the build has one', function()
    local app, _, state, main = fresh({ setupHook = true })
    answerProfile(main)
    calibrate(app, main)
    mock.click('change as new setup'); mock.render(main)
    state.loadedSetup = ini.parse(mock.read(app.saved.path))
    state.setupHookFn(app.saved.path)
    assert.equals(1, app.history.activeN)
    assert.is_true(app.saved.loaded)
  end)

  it('is read-only on online servers', function()
    local app, _, state, main = fresh({ online = true })
    answerProfile(main)
    calibrate(app, main)
    local text = mock.render(main)
    assert.matches('read%-only', text)
    mock.click('change as new setup'); mock.render(main)
    assert.is_nil(mock.read(state.setupsDir .. '/test_drift/test_track/DSA_test_drift_v1.ini'))
    assert.equals('changes', app.result.recommendation.kind)
  end)

  it('tells the driver to update an old CSP', function()
    local app, _, _, main = fresh({ versionCode = 1000 })
    assert.matches('update needed', mock.render(main))
  end)

  it('saves a starter baseline from the Setup tab', function()
    local app, _, state, main = fresh()
    answerProfile(main)
    mock.click('Generate baseline'); mock.render(main)
    assert.is_table(app.baselinePreview)
    mock.click('Save baseline as new setup'); mock.render(main)
    local written = ini.parse(mock.read(state.setupsDir .. '/test_drift/test_track/DSA_test_drift_v1.ini'))
    assert.equals('100', written.sections.DIFF_POWER.values.VALUE)
  end)

  it('lets the driver map an unknown item', function()
    local app, _, _, main = fresh()
    answerProfile(main)
    mock.click('What is this?##XX_MAGIC_LEVER'); mock.render(main)
    mock.click('Alignment'); mock.render(main)
    mock.click('Steering lock##map'); mock.render(main)
    assert.equals('steer_lock', app.itemsByName.XX_MAGIC_LEVER.lever)
    assert.is_table(app.levers.steer_lock)
  end)
end)
