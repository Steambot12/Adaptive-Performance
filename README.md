# Adaptive Performance

![Version](https://img.shields.io/badge/version-1.2-blue.svg)
![Platform](https://img.shields.io/badge/platform-Android%208.0+-green.svg)
![Magisk](https://img.shields.io/badge/Magisk-20.4+-red.svg)

Adaptive Performance is a Magisk / KernelSU module that automatically switches CPU governors based on the foreground application. It balances performance and battery life by applying the right governor for gaming, specific apps, or idle states — without any manual intervention.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Web Dashboard](#web-dashboard)
- [CLI Reference](#cli-reference)
- [REST API](#rest-api)
- [Configuration Files](#configuration-files)
- [How It Works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Uninstallation](#uninstallation)
- [Changelog](#changelog)

---

## Features

**Core**
- Automatic CPU governor switching based on foreground app
- Game list: apply a dedicated gaming governor when a registered game is running
- Per-app governor: assign a specific governor to any non-game application
- Priority system: Per-app governor > Game list > Idle governor
- Persist all configuration across reboots
- Stock thermal management is preserved — no override

**Dashboard & Monitoring**
- Web dashboard accessible via browser at port 9876
- Real-time status: mode (IDLE / GAMING / CUSTOM), active governor, foreground app, temperature
- Device info: device name, kernel, CPU cores, chipset, idle governor
- Live log viewer with auto-refresh
- REST API on port 9877 for scripting and automation

**Compatibility**
- Android 8.0 and above
- Mediatek and Snapdragon chipsets
- Works with stock kernels; benefits from custom kernels with additional governor options
- Supports multi-core CPU configurations

**Safety**
- Non-destructive installation — original governor and kernel tunables are backed up
- Automatic restoration to stock governor on idle
- Conflict validation: prevents a package from appearing in both game list and per-app config
- Clean uninstallation with full config removal

---

## Requirements

- Magisk 20.4+ or KernelSU
- Android 8.0 (Oreo) or higher
- Root access
- Custom kernel with multiple governors is optional but recommended for wider governor choices

---

## Installation

**Via Magisk Manager or KernelSU (recommended)**

1. Download the latest `AdaptivePerformance-v1.2.zip` from [Releases](https://github.com/Steambot12/Adaptive-Performance/releases)
2. Open Magisk Manager or KernelSU → Modules → Install from storage
3. Select the downloaded ZIP
4. Wait for installation to complete
5. Reboot the device

**Via ADB**

```
adb push AdaptivePerformance-v1.2.zip /sdcard/
adb shell su -c magisk --install-module /sdcard/AdaptivePerformance-v1.2.zip
adb reboot
```

**What happens during installation**

- Detects and saves the stock CPU governor
- Backs up kernel governor tunables
- Creates a default game list (Delta Force, Mobile Legends)
- Sets up CLI commands in `/system/bin/`
- Prepares web dashboard files

---

## Quick Start

After installation and reboot, the module starts automatically.

**Check module status**
```
adaptperf-status
```

**Open the web dashboard**
```
http://127.0.0.1:9876
```

**Add games to the game list**
```
adaptperf-add com.tencent.ig
adaptperf-add com.dts.freefireth
```

**Set the gaming governor**
```
adaptperf-setgov schedutil
```

**Set a per-app governor**
```
adaptperf-setappgov com.android.chrome conservative
```

---

## Web Dashboard

Access the dashboard locally from the device browser:
```
http://127.0.0.1:9876
```

Access from a PC via ADB port forwarding:
```
adb forward tcp:9876 tcp:9876
adb forward tcp:9877 tcp:9877
```
Then open `http://localhost:9876` in the PC browser.

**Dashboard Tabs**

| Tab | Description |
|---------|-------------|
| Main | Real-time mode indicator, active CPU governor, foreground app, temperature, and device information |
| Tuning | Governor configuration, game package manager, per-app governor settings, auto-detect foreground app |
| Log | Live log viewer with manual refresh and clear options |

---

## CLI Reference

All commands are available globally after installation.

**Game Management**

```
# Add a game package
adaptperf-add <package_name>

# Remove a game package
adaptperf-remove <package_name>

# List all registered games
adaptperf-list
```

Example:
```
adaptperf-add com.garena.game.df
adaptperf-remove com.proxima.dfm
```

**Governor Configuration**

```
# Set the gaming governor
adaptperf-setgov <governor_name>

# View governors supported by your kernel
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
```

Example:
```
adaptperf-setgov schedutil
adaptperf-setgov performance
```

**Per-App Governor**

```
# Assign a governor to a specific app
adaptperf-setappgov <package_name> <governor_name>

# Remove per-app governor for an app
adaptperf-delappgov <package_name>

# List all per-app governor configs
adaptperf-listappgov
```

Example:
```
adaptperf-setappgov com.android.chrome conservative
adaptperf-setappgov com.google.android.youtube ondemand
adaptperf-delappgov com.android.chrome
```

Note: A package cannot exist in both the game list and per-app governor config simultaneously. Remove it from one list before adding to the other.

**Status and Logs**

```
# View module status and recent activity
adaptperf-status

# View full log
cat /data/local/tmp/adaptive_perf.log

# Monitor log in real time
tail -f /data/local/tmp/adaptive_perf.log
```

---

## REST API

The module exposes a REST API on port **9877**.

| Endpoint | Parameter(s) | Description |
|----------|--------------|-------------|
| `/?action=add` | `pkg` | Add game package |
| `/?action=remove` | `pkg` | Remove game package |
| `/?action=set_governor` | `governor` | Set gaming governor |
| `/?action=set_app_governor` | `pkg`, `governor` | Set per-app governor |
| `/?action=remove_app_governor` | `pkg` | Remove per-app governor |

Example using curl:
```
curl "http://127.0.0.1:9877/?action=set_governor&governor=schedutil"
curl "http://127.0.0.1:9877/?action=add&pkg=com.tencent.ig"
```

---

## Configuration Files

All configuration files are stored in `/data/adb/modules/adaptive_performance/`.

| File | Purpose | Format |
|------|---------|--------|
| `game_packages.txt` | Registered game packages | One package per line |
| `app_governors.txt` | Per-app governor mappings | `package=governor` |
| `governor_pref.txt` | Gaming governor preference | Single governor name |
| `default_governor.txt` | Idle/stock governor | Single governor name |
| `stock_configs/` | Kernel config backups | Directory |

Manual edits to these files take effect immediately without a reboot.

Example format for `app_governors.txt`:
```
com.android.chrome=conservative
com.google.android.youtube=ondemand
```

---

## How It Works

The module runs a background service (`service.sh`) that monitors the foreground application every 1 second.

For each detected foreground app, it checks in this order:
1. If the package is in the **game list** — apply the gaming governor
2. If the package has a **per-app governor** config — apply that governor
3. Otherwise — apply the idle (stock) governor

**Governor detection on idle:**
- Mediatek: `sugov_ext` → `schedutil` → `walt` → `interactive` → `ondemand`
- Snapdragon: `walt` → `schedutil` → `interactive` → `ondemand`

**Governor detection for gaming:**
- Mediatek: `schedhorizon` → `schedutil` → `performance`
- Snapdragon: `schedutil` → `performance`

The module backs up the original governor name, CPU frequency limits, and governor tunables on install. These are fully restored when switching back to idle mode.

---

## Troubleshooting

**Module not starting after reboot**
```
cat /data/local/tmp/adaptive_perf.log
ps | grep service.sh

# Manual start for debugging
su -c sh /data/adb/modules/adaptive_performance/service.sh
```

**Governor not changing**
- Verify the governor is supported by your kernel:
```
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
```
- Try a different governor: `adaptperf-setgov schedutil`
- Some kernels restrict governor changes under thermal throttling

**Dashboard not accessible**
```
ps | grep httpd
netstat -tuln | grep 9876
```
If the HTTP server is not running, reboot the device to restart the module service.

**Per-app governor not applying**

Check for conflicts — a package must not be in both lists:
```
adaptperf-list
adaptperf-listappgov
```
If the package is in the game list, remove it first:
```
adaptperf-remove com.example.app
adaptperf-setappgov com.example.app conservative
```

**Temperature not showing**

Some devices do not expose temperature via standard thermal zones. This does not affect governor switching.

---

## Uninstallation

**Via Magisk Manager or KernelSU**

1. Open Magisk Manager or KernelSU
2. Go to Modules
3. Find Adaptive Performance and tap Remove
4. Reboot

**Manual**
```
rm -rf /data/adb/modules/adaptive_performance
reboot
```

The uninstall process automatically stops running services, restores the original CPU governor, and removes all configuration and log files.

---

## Changelog

### v1.2 (March 2026)

**Fixed**
- Bottom navigation bar no longer pushed up when virtual keyboard opens
- `visualViewport` reposition now uses `requestAnimationFrame` on first call to ensure correct height measurement after layout
- Added fallback nav height (68px) to prevent incorrect positioning edge case
- Device Info fields (Device, Kernel, CPU Cores, Chipset, Idle Governor) no longer blank on first open — retries every 3 seconds until `static.json` is ready
- Version string corrected to 1.2 in `module.prop` and UI

**Improved**
- Governor dropdown no longer resets during config polling when user is actively selecting a value
- Package name input fields have autocomplete, autocorrect, and spellcheck disabled to prevent keyboard interference on Android
- Config polling skips dropdown update when `govSelectDirty` flag is set

**Changed**
- Version code: 50 to 58
- Bottom nav positioning: CSS `bottom: 0` replaced with JS `visualViewport`-locked `top` value

### v1.1 (December 2025)

**Added**
- Per-app governor system
- CLI commands: `adaptperf-setappgov`, `adaptperf-delappgov`, `adaptperf-listappgov`
- Per-app governor tab in web dashboard
- Conflict detection between game list and per-app config
- New API endpoints: `set_app_governor`, `remove_app_governor`
- Duplicate detection when adding games

**Improved**
- Dashboard shows three modes: IDLE / GAMING / CUSTOM
- Faster app switching response (2s for per-app vs 3s for games)
- More reliable config persistence
- Enhanced log viewer
- Governor detection for Mediatek and Snapdragon

**Fixed**
- Race condition in app detection loop
- Governor not reverting to idle when removing an active per-app config
- Memory leak in monitoring loop
- Log file not created on first boot
- HTTP server not binding on some ROMs

### v1.0 (Initial Release)

- Basic game detection and automatic governor switching
- CLI tools
- Web dashboard (basic)

---

## Support

To report a bug, open an issue on [GitHub Issues](https://github.com/Steambot12/Adaptive-Performance/issues) and include:
- Device model and Android version
- Kernel name
- Log file contents (`/data/local/tmp/adaptive_perf.log`)
- Steps to reproduce the issue

---

Made by Steambot12
