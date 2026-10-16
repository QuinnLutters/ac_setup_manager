-- Drift Setup Assistant: entry point. CSP calls script.update every frame and
-- the window functions named in manifest.ini while each window is open.

local App = require('src/game/app')
local windows = require('src/ui/windows')
local compat = require('src/game/compat')

local app = App.new()
local lastError

-- Keep the app alive if one frame throws; show the error instead of dying.
local function guarded(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok and err ~= lastError then
    lastError = err
    compat.log('error:', err)
  end
end

local function showError()
  if lastError then
    ui.textColored('Something went wrong: ' .. tostring(lastError), rgbm(1, 0.4, 0.35, 1))
    if ui.button('Dismiss error') then lastError = nil end
  end
end

function script.update(dt)
  guarded(app.update, app, dt)
end

function script.windowMain(dt)
  showError()
  guarded(windows.main, app, dt)
end

function script.windowSettings(dt)
  guarded(windows.settings, app, dt)
end

function script.windowHud(dt)
  guarded(windows.hud, app, dt)
end
