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
  for _, l in ipairs({ 'New to it', 'Wheel', 'Solo', 'More stability', 'Start' }) do mock.click(l) end
  mock.render(main)
end

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

  it('runs the whole loop: profile, run, feedback, save, load, compare, revert', function()
    local app, windows, state, main = fresh()

    -- F1 scanner
    assert.equals(20, #app.items)
    assert.equals(4, app.itemsByName.ARB_REAR.value)

    -- F2 first-run questionnaire
    assert.matches('Welcome', mock.render(main))
    answerProfile(main)
    assert.same({ experience = 'beginner', device = 'wheel', style = 'solo', goal = 'stability' }, app.profile)

    -- F3 run recorder
    drive(app, sim.scenarios.spin())
    assert.equals('feedback', app.phase)
    assert.equals('spin', app.lastRun.run.endReason)
    local text = mock.render(main)
    assert.matches('How did the car feel%?', text)
    assert.matches('%[Spins out%]', text)

    -- F5 + F4 + F6 + F7
    mock.click('Spins out')
    mock.render(main)
    assert.equals('result', app.phase)
    local rec = app.result.recommendation
    assert.equals('change', rec.kind)
    assert.equals('arb_rear', rec.plan.lever)
    text = mock.render(main)
    assert.matches('What changes', text)
    assert.matches('Why it helps', text)
    assert.matches('What to feel on the next run', text)
    assert.matches('Term: Side bite', text)

    -- F8 save as a new versioned file, never overwriting the driver's file
    mock.click('Save as new setup')
    mock.render(main)
    local path = state.setupsDir .. '/test_drift/test_track/DSA_test_drift_v1.ini'
    local written = mock.read(path)
    assert.is_string(written)
    assert.equals('3', ini.parse(written).sections.ARB_REAR.values.VALUE)
    assert.is_true(app.saved.verified)
    assert.equals(1, #app.saved.diff)
    assert.equals('4', ini.parse(mock.read(state.setupsDir .. '/test_drift/test_track/my_setup.ini')).sections.ARB_REAR.values.VALUE)
    assert.matches('Load it now', mock.render(main))

    -- Driver loads v1 in the pits; the app notices through the current-setup API.
    state.loadedSetup = ini.parse(written)
    state.inPits = true
    mock.feed(app, { state.sample, state.sample })
    app.lastLoadCheck = -10
    mock.feed(app, { state.sample })
    state.inPits = false
    assert.equals(1, app.history.activeN)
    assert.equals(3, app.itemsByName.ARB_REAR.value)

    -- F9 before/after on the next run
    drive(app, sim.scenarios.good())
    assert.equals('feedback', app.phase)
    mock.click('Felt good')
    mock.render(main)
    local cmp = app.result.compare
    assert.is_table(cmp)
    assert.equals('helped', cmp.verdict)
    assert.equals('done', app.result.recommendation.kind)
    text = mock.render(main)
    assert.matches('Did v1 help%?', text)
    assert.matches('dialled in', text)

    -- F12 history and revert
    text = mock.render(main)
    assert.matches('v1  DSA_test_drift_v1.ini', text)
    app:revertTo(0)
    assert.equals(0, app.history.activeN)
    assert.is_true(require('src/core/history').isBlockedFn(app.history)('arb_rear', -1))

    -- History and logs persisted
    assert.is_string(mock.read(state.appDir .. '/data/history/test_drift__test_track.json'))
    local p = io.popen('ls ' .. state.appDir .. '/logs/*/')
    local listing = p:read('*a'); p:close()
    assert.matches('run_1%.csv', listing)
    assert.matches('summary%.csv', listing)

    -- The original setup had no known file name, so the revert wrote a copy to load.
    local hud = function(dt) windows.hud(app, dt) end
    assert.matches('Load DSA_test_drift_v2.ini in the pits', mock.render(hud))
    state.loadedSetup = ini.parse(mock.read(app.saved.path))
    state.inPits = true
    app.lastLoadCheck = -10
    mock.feed(app, { state.sample })
    state.inPits = false
    assert.equals(2, app.history.activeN)
    assert.matches('DSA ready', mock.render(hud))

    -- Settings render
    assert.matches('Diagnostics', mock.render(function(dt) windows.settings(app, dt) end))
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
    drive(app, sim.scenarios.spin())
    mock.click('Spins out'); mock.render(main)
    mock.click('Save as new setup'); mock.render(main)
    state.loadedSetup = ini.parse(mock.read(app.saved.path))
    state.setupHookFn(app.saved.path)
    assert.equals(1, app.history.activeN)
    assert.is_true(app.saved.loaded)
  end)

  it('is read-only on online servers', function()
    local app, _, state, main = fresh({ online = true })
    answerProfile(main)
    drive(app, sim.scenarios.spin())
    mock.click('Spins out'); mock.render(main)
    local text = mock.render(main)
    assert.matches('read%-only', text)
    mock.click('Save as new setup'); mock.render(main)
    assert.is_nil(mock.read(state.setupsDir .. '/test_drift/test_track/DSA_test_drift_v1.ini'))
    assert.equals('change', app.result.recommendation.kind)
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
