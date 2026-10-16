# Milestone 0 spike: tech note

**Status: not run yet.** It needs a Windows PC with AC1, Content Manager and CSP. The code is written so the spike is mostly a checklist: open the app, read the Diagnostics panel, write one test file, load it. Fill in the results table below and make the go/no-go call.

The brief names three technical unknowns. Each one is isolated behind a single module, so a wrong guess means changing one file, not the app.

## 1. Telemetry field names

**Code:** `src/game/telemetry.lua` (fields listed in `CAR_FIELDS` and `WHEEL_FIELDS`).

Every field is read through `compat.field`, which returns nil instead of throwing when a field is missing. The app keeps working with whatever exists and skips metrics it can't compute.

| Used for | Field assumed | Fallback |
| --- | --- | --- |
| Speed | `car.speedKmh` | none |
| Body slip angle | `car.velocity` against `car.look` / `car.side` | `car.localVelocity` (x = lateral, z = forward) |
| Yaw rate | `car.localAngularVelocity.y` (rad/s) | `car.angularVelocity` · `car.up` |
| Steering | `car.steer` (deg) / `car.steerLock` | normalise against the most lock seen this session (disables the "runs out of lock" metric) |
| Inputs | `car.gas`, `brake`, `handbrake`, `clutch`, `gear`, `rpm`, `rpmLimiter` | limiter from `engine.ini` |
| Per wheel (`car.wheels[0..3]`, FL FR RL RR) | `slipAngle`, `slipRatio`, `ndSlip`, `load`, `tyreCoreTemperature`, `tyrePressure`, `suspensionTravel` | metric is skipped |

**Check:** settings window → Diagnostics → "Car fields" and "Wheel fields". Then drive a run with CSV logging on, open `logs/.../run_1.csv` and sanity-check: `slip` should read ~0 driving straight and 20–50 in a drift; `steer` should reach ±1 at full lock; `slipRatio` units (fraction vs percent) decide `wheelspinSlipRatio` in `rules.json`.

**If a field is missing:** add the right name to `WHEEL_FIELDS`/the sampler, or fall back to shared memory (the brief's plan B) inside `telemetry.sample` only.

## 2. Reading setup.ini and the current setup

**Code:** `src/game/cardata.lua`, `src/game/compat.lua` (`carData`, `currentSetup`, `onSetupFile`, `setupsDir`).

- `ac.INIConfig.carData(0, 'setup.ini')` for MIN/MAX/STEP. Check on 3 cars (one Kunos stock, two drift-pack) that the Setup tab lists every item with sensible ranges.
- `ac.INIConfig.currentSetup()` (also tries `carSetup`) for the loaded values. If neither exists, the Coach tab asks the driver to pick the file they loaded, which works but is clunkier.
- `ac.onSetupFile(callback)` to notice a load in the pits. If missing, the app polls the current setup while you're in the pits, or the driver presses "I've loaded it".
- Setups folder from `ac.FolderID.UserSetups`, else `Documents/setups`, else `Documents/Assetto Corsa/setups`. Diagnostics shows which one it found.

## 3. Writing a setup file that loads correctly (clicks vs real values)

**Code:** `src/core/setupfile.lua` (`build`), `src/core/setup_items.lua` (`snap`, `display`).

The app assumes a setup file's `VALUE` uses the same units as `MIN`/`MAX`/`STEP` in `setup.ini`. `SHOW_CLICKS` only changes how the value is displayed. That's the main risk the brief names.

**Check per test car:**
1. Settings → Diagnostics → **Write spike test file**. This writes `DSA_<car>_spiketest.ini` with the current values unchanged.
2. Load it in the pit setup screen.
3. Press **Verify loaded values**. Every item should match. Any row listed means that item stores clicks (or another unit) and needs a conversion in `setup_items`.
4. Repeat with one real recommendation per category (tyres, alignment, ARB, springs, dampers, diff, brakes) and check the setup screen shows the expected new value.

## Also to confirm

- Mistake detection fields: `car.collidedWith` / `car.collisionDepth` (wall and car contact) and `car.wheelsOutside` (track limits), read in `telemetry.sample`. The detector only trusts contact when speed really drops, and ignores a field that's on for most of a run, so a wrong guess can't exclude every run. Hit a wall once and run off track once with logging on, and check the `collided` and `offTrack` columns in the CSV.

- Input device detection: the app reads `INPUT_METHOD` from `Documents/Assetto Corsa/cfg/controls.ini` (`WHEEL`, `X360`, `KEYBOARD`), in `cardata.inputDevice`. Diagnostics shows the raw value. Check it with a wheel and with a controller, and note any other values (for example from Content Manager presets) that need mapping.

- Minimum CSP build: find the oldest build with every API above, then set `MIN_VERSION_CODE` in `compat.lua` and `REQUIRED_VERSION` in `manifest.ini` (both 2651 for now, a placeholder).
- HUD window flags (`NO_BACKGROUND, NO_TITLE_BAR`) and `LAZY = NONE` in `manifest.ini`.
- `ROD_LENGTH` direction (assumed: higher value = higher ride height) and `PACKER_RANGE` units (assumed metres) for the bottoming metric.
- Gear ratios stored as `RATIOS=file.rto` lists: treated as not adjustable for now, so "bogs down" gives driving advice instead. Decide whether to support them after the spike.

## Results (fill in)

| Check | Car 1 (stock) | Car 2 (drift pack) | Car 3 (drift pack) |
| --- | --- | --- | --- |
| CSP build | | | |
| All car fields present | | | |
| All wheel fields present | | | |
| setup.ini items listed correctly | | | |
| Current setup readable | | | |
| Load hook available | | | |
| Spike file loads with identical values | | | |
| One change per category loads correctly | | | |

**Go** if telemetry fields exist (directly or via shared memory) and the spike file round-trips on all three cars. **No-go** if setup files can't be written in a form the game loads; then the app falls back to "explain only" mode, which already exists for online servers.
