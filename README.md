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

1. **Answer four questions** the first time (experience, wheel or controller, solo/lead/chase, what you want from the car).
2. **Drive.** Recording starts by itself when you start drifting. A run ends when you spin, stop, or go 60 s without drifting.
3. **Tap how the car felt** (spins out, straightens up, can't start a drift, bogs down, twitchy, felt good), or skip.
4. **Read the recommendation.** It shows what changes, why it helps, what to feel on the next run, and the glossary term behind it.
5. **Save as new setup.** The app writes `DSA_<car>_v<n>.ini` next to your setups. It never overwrites your own files.
6. **Load it in the pits** (Setup → Load → pick the file) and drive again. After the next run the app compares before and after and offers to revert if it got worse.

The loop ends when you say it felt good and nothing is flagged. The **Setup** tab lists everything the car exposes and can generate a starter drift baseline. **History** shows every version with one-click revert. **Learn** is the glossary.

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

Built: F1–F9 (MVP) plus F10 starter baseline, F11 glossary with diagrams, and F12 history and revert. 106 tests pass.

**Not yet verified in game.** Development happened on macOS, where AC doesn't run. Every CSP-specific call is feature-checked and listed in [docs/SPIKE.md](docs/SPIKE.md), with a Diagnostics panel in the app's settings window to confirm them on a Windows PC.

Open questions from the brief that still need a decision: minimum CSP version (placeholder build 2651 in `manifest.ini` and `src/game/compat.lua`), whether controllers are officially supported (the app works with either today), where to release, and the final name.
