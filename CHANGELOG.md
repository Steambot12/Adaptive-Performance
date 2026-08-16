# Changelog

## [v1.3 - RELEASE] - 2026-08-16

**Added**

- Detect App button now opens a picker of user-installed apps currently running in the background — available on both the Game Package and Per-App Governor sections; tap an app to fill the package field (system apps are excluded)
- Chipset detection now shows the full marketing name (e.g. `Snapdragon 7+ Gen 2`) in Device Info instead of the raw SoC code, with a lookup table covering Snapdragon, Dimensity/Helio, Exynos, Tensor, and Unisoc
- Toast notifications now carry a neon edge color for instant feedback: green (success), red (error), yellow (removed)

**Fixed**

- Idle mode clamped the big and prime clusters to the little core's max frequency — max frequency is now backed up and restored per cluster (little / big / prime)
- `adaptperf-status` always reported `NOT RUNNING` — it now reads state directly from sysfs and on-disk config and detects the service via a heartbeat, so status is accurate
- Governor writes could fail silently on some ROMs — each write is now verified and retried across every CPU policy group
- Available governors were hardcoded — the list is now detected from the kernel per device
- Governor display and log no longer lag after actions on the main tab — they refresh in real time
- Removed dead gaming-mode code paths that never executed

**Improved**

- Full dashboard redesign — cleaner, more compatible layout for the WebView
- Realtime dashboard updates after every action (removed the background polling loops)
- Governor dropdowns are now editable, with game-add validation and immediate log refresh

**Changed**

- Version: 1.2 → 1.3
- Version code: 58 → 60

## [v1.2 - RELEASE] - 2026-03-17

**Fixed**

- Bottom navigation bar (Main / Tuning / Log) no longer pushed up when virtual keyboard opens
- visualViewport `reposition()` now uses `requestAnimationFrame` on first call so `offsetHeight` is measured after layout is complete
- Added fallback height constant (68px) when `offsetHeight` is still 0, preventing nav from jumping to wrong position
- Device Info fields (Device, Kernel, CPU Cores, Chipset, Idle Governor) no longer blank on first open — now retries every 3s until `static.json` is ready
- Version string corrected to 1.2 in both `module.prop` and UI subtitle

**Improved**

- Bottom nav keyboard lock: replaced basic `position: fixed; bottom: 0` with JS-based `visualViewport` anchor, keeping nav at bottom of visible screen on all Android WebView environments
- Governor dropdown no longer resets mid-interaction during config polling — auto-filled only once and only if user hasn't touched the selector
- Package name input fields now have `autocomplete`, `autocorrect`, and `spellcheck` disabled to prevent keyboard interference on Android
- Config polling interval (5s) skips dropdown update when user is actively selecting a governor

**Changed**

- Version code: 50 → 58
- Bottom nav positioning: CSS `bottom: 0` → JS `visualViewport`-locked `top` value
- `lockNavToScreen()` init call: direct invocation → `requestAnimationFrame` deferred
