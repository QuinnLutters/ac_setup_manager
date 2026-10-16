# Drift Setup Assistant

An in-game Assetto Corsa app that tunes your car for drifting **one change at a time** and explains every change. It watches your runs, asks how the car felt, recommends one setup change, saves it as a new setup file, and then tells you whether it helped.

For the original Assetto Corsa (AC1) with Custom Shaders Patch. Works with a wheel or a controller.

## Install

1. Install [Content Manager](https://assettocorsa.club/content-manager.html) and use it to install **Custom Shaders Patch** (Settings → Custom Shaders Patch).
2. Copy the `apps/lua/drift-setup-assistant` folder from this repo into your game folder, so you end up with:
   ```
   <Steam>/steamapps/common/assettocorsa/apps/lua/drift-setup-assistant/manifest.ini
   ```
3. Start a practice session. Open **Drift Setup Assistant** from the CSP apps bar on the right of the screen. Optionally open **Drift Setup Assistant HUD** too.

## How to use it

1. **Answer three questions** the first time: your experience, how you drift (solo, lead or chase), and what you want from the car (more angle, stability or speed, easier entries, smoother transitions, more consistency, or more forgiving). The app reads your input device (wheel, controller or keyboard) from Assetto Corsa's own controls settings, so it doesn't ask. It only asks if it can't read them.
2. **Pick a starting point** for each new car and track: a drift baseline the app builds from the car's own ranges, or the setup you have loaded now.
3. **Drive 3 runs** on that starting setup. Recording starts by itself when you start drifting. A run ends when you spin, stop, or go 60 s without drifting. After each run, tap how the car felt or skip.
4. **Get the first changes.** The app looks at all 3 runs together and suggests fixes, one per problem it found, each with a checkbox. The main fixes are ticked for you; alternatives are listed unticked. Each one says what changes, why it helps, what to feel on the next run, and the glossary term behind it. Two ticked changes never move the same setting.
5. **Save as new setup.** Every ticked change goes into one new file, `DSA_<car>_v<n>.ini`, next to your setups. It never overwrites your own files.
6. **Load it in the pits** (Setup → Load → pick the file) and drive again. From then on you get an update after every run: the app compares before and after, offers to revert if it got worse, and suggests the next changes.

**Driver mistakes don't count.** If you hit a wall, put all four wheels off track, or spin without trying to catch it, the app says so after the run. The run is still logged, but it isn't used for setup changes or before/after comparisons. You can overrule it with "Count it anyway", or mark a clean-looking run with "My mistake".

The loop ends when you say it felt good and nothing is flagged. The **Setup** tab lists everything the car exposes and can also generate the drift baseline on its own. **History** shows every version and its changes, with one-click revert. **Learn** is the glossary.

On online servers the app runs read-only: it diagnoses and explains, but doesn't write setups.

## What's in the repo

```
apps/lua/drift-setup-assistant/    ← the app folder to drop into the game
  manifest.ini, drift-setup-assistant.lua, icon.png
  rules.json                       ← all tuning logic and thresholds (editable, no code)
  src/core/                        ← pure Lua: recorder, metrics, rule engine, files. No ac.* calls
  src/game/                        ← CSP adapters: telemetry, car data, storage, app controller
  src/ui/                          ← windows: main (Coach/Setup/History/Learn), settings, HUD
spec/                              ← busted tests, fixtures, mocked CSP runtime
tools/analyze.lua                  ← run the rule engine on a CSV log outside the game
tools/make_fixtures.lua            ← regenerate synthetic CSV fixtures
docs/SPIKE.md                      ← milestone 0 tech note and checklist
```

At runtime the app writes into its own folder: `data/history/*.json` (versions per car and track) and `logs/<session>/run_<n>.csv` + `summary.csv` (one row per telemetry sample, 25 Hz). Preferences live in `ac.storage`.

## Tuning the rules

Everything the engine decides comes from `rules.json`: drift detection thresholds, metric settings, each symptom's telemetry ramp (`warn` → `full`), the feedback that confirms it, its priority group, and the ordered list of changes to try. Thresholds are starting values to tune in playtests.

Recorded logs can be replayed offline:

```bash
luajit tools/analyze.lua path/to/run_3.csv --car spec/fixtures/cars/test_drift --feedback spins_out
```

## Development

The rule engine is pure Lua, so it's tested outside the game. Tests run on both LuaJIT (the game's runtime) and Lua 5.4.

```bash
luarocks --lua-dir="$(brew --prefix luajit)" --lua-version=5.1 install --local busted
```

```bash
~/.luarocks/bin/busted
```

`spec/game_smoke_spec.lua` runs the full in-game loop (profile → run → feedback → save → load → compare → revert) against a mocked CSP API. That catches glue-code bugs, but it can't prove the real CSP field names, so milestone 0 still has to happen in game.

## Status

Built: F1–F9 (MVP) plus F10 starter baseline, F11 glossary with diagrams, and F12 history and revert. After the first playtests: several changes per version (ticked by the driver), a 3-run start, driver-mistake detection and four more goals. This deliberately relaxes the brief's F6 rule of one change at a time. 129 tests pass.

**Not yet verified in game.** Development happened on macOS, where AC doesn't run. Every CSP-specific call is feature-checked and listed in [docs/SPIKE.md](docs/SPIKE.md), with a Diagnostics panel in the app's settings window to confirm them on a Windows PC.

Open questions from the brief that still need a decision: minimum CSP version (placeholder build 2651 in `manifest.ini` and `src/game/compat.lua`), whether controllers are officially supported (the app detects the device and works with wheel, controller or keyboard today), where to release, and the final name.
