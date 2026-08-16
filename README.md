# Adaptive Performance

![Version](https://img.shields.io/badge/version-1.3-blue.svg)
![Platform](https://img.shields.io/badge/platform-Android%208.0+-green.svg)
![Magisk](https://img.shields.io/badge/Magisk-20.4+-red.svg)

Magisk / KernelSU module that automatically switches CPU governors based on the foreground application. Balances performance and battery life by applying the right governor for gaming, specific apps, or idle states — without manual intervention.

---

## Features

**Core**
- Automatic CPU governor switching based on foreground app
- Game list: apply a dedicated gaming governor when a registered game is running
- Per-app governor: assign a specific governor to any non-game application
- Priority: **Per-app governor > Game list > Idle governor**
- All configuration persists across reboots
- Stock thermal management preserved — no override

**Supported Chipsets**
- Qualcomm Snapdragon
- Mediatek (Dimensity, Helio)
- Samsung Exynos
- Google Tensor
- Unisoc (Spreadtrum)
- Any other chipset with standard cpufreq interface

**Supported Governors**
- All governors available on your kernel are detected and usable — including `schedutil`, `schedhorizon`, `vorpal`, `blu_schedutil`, `walt`, `interactive`, `ondemand`, `conservative`, `powersave`, `performance`, `sugov_ext`, and any custom governors your kernel provides

**Dashboard & Monitoring**
- Web dashboard at `http://127.0.0.1:9876`
- Real-time: mode (IDLE / GAMING / CUSTOM), active governor, foreground app, temperature
- Device info: model, kernel, CPU cores, chipset, idle governor
- Live log viewer with auto-refresh
- REST API on port 9877

**Safety**
- Non-destructive — original governor and tunables are backed up
- Automatic restore to stock governor on idle
- Conflict validation: package cannot be in both game list and per-app config
- Clean uninstall with full config removal and governor restore

---

## Requirements

- Magisk 20.4+ or KernelSU
- Android 8.0+
- Root access

---

## Installation

**Via Magisk Manager or KernelSU**

1. Download latest ZIP from [Releases](https://github.com/Steambot12/Adaptive-Performance/releases)
2. Magisk Manager / KernelSU → Modules → Install from storage
3. Select the ZIP
4. Reboot

**Via ADB**

```
adb push AdaptivePerformance-v1.3.zip /sdcard/
adb shell su -c magisk --install-module /sdcard/AdaptivePerformance-v1.3.zip
adb reboot
```

---

## Quick Start

After reboot, the module starts automatically.

```sh
# Check status
adaptperf-status

# Open dashboard
# http://127.0.0.1:9876

# Add games
adaptperf-add com.tencent.ig
adaptperf-add com.dts.freefireth

# Set gaming governor
adaptperf-setgov schedutil

# Set per-app governor
adaptperf-setappgov com.android.chrome conservative
```

---

## Web Dashboard

**Local access:**
```
http://127.0.0.1:9876
```

**From PC via ADB:**
```sh
adb forward tcp:9876 tcp:9876
adb forward tcp:9877 tcp:9877
# Then open http://localhost:9876
```

| Tab | Description |
|---------|-------------|
| Main | Mode indicator, CPU governor, foreground app, temperature, device info |
| Tuning | Governor config, game list manager, per-app governor settings |
| Log | Live log viewer |

---

## CLI Reference

**Game Management**
```sh
adaptperf-add <package>        # Add game
adaptperf-remove <package>     # Remove game
adaptperf-list                 # List all games
```

**Governor**
```sh
adaptperf-setgov <governor>    # Set gaming governor

# View available governors on your kernel
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
```

**Per-App Governor**
```sh
adaptperf-setappgov <package> <governor>   # Set per-app governor
adaptperf-delappgov <package>              # Remove per-app governor
adaptperf-listappgov                       # List all per-app configs
```

A package cannot be in both the game list and per-app config. Remove from one before adding to the other.

**Status**
```sh
adaptperf-status
cat /data/local/tmp/adaptive_perf.log       # Full log
tail -f /data/local/tmp/adaptive_perf.log   # Live log
```

---

## REST API

Port **9877**, localhost only.

| Endpoint | Parameters | Description |
|----------|------------|-------------|
| `/?action=add` | `pkg` | Add game package |
| `/?action=remove` | `pkg` | Remove game package |
| `/?action=set_governor` | `governor` | Set gaming governor |
| `/?action=set_idle_governor` | `governor` | Set idle governor |
| `/?action=set_app_governor` | `pkg`, `governor` | Set per-app governor |
| `/?action=remove_app_governor` | `pkg` | Remove per-app governor |
| `/?action=get_status` | — | Get current status |

```sh
curl "http://127.0.0.1:9877/?action=set_governor&governor=schedutil"
curl "http://127.0.0.1:9877/?action=add&pkg=com.tencent.ig"
```

---

## How It Works

Background service (`service.sh`) monitors the foreground app every 1 second.

**Priority order (highest first):**
1. **Per-app governor** — if the package has a custom governor config, use it
2. **Game list** — if the package is in the game list, use the gaming governor
3. **Idle** — default/stock governor

**Default idle governor auto-detection:**
- Mediatek: `sugov_ext` → `blu_schedutil` → `schedutil` → `walt` → `interactive` → `ondemand`
- Snapdragon/Others: `walt` → `blu_schedutil` → `schedutil` → `interactive` → `ondemand`

**Default gaming governor auto-detection:**
- Mediatek: `schedhorizon` → `blu_schedutil` → `schedutil` → `performance`
- Snapdragon/Others: `vorpal` → `blu_schedutil` → `schedutil` → `performance`

The module backs up the original governor, CPU frequency limits, and governor tunables on install. These are restored when switching back to idle.

---

## Configuration Files

All in `/data/adb/modules/adaptive_performance/`:

| File | Format | Purpose |
|------|--------|---------|
| `game_packages.txt` | One package per line | Game list |
| `app_governors.txt` | `package=governor` | Per-app governors |
| `governor_pref.txt` | Single governor name | Gaming governor preference |
| `default_governor.txt` | Single governor name | Stock governor (detected at install) |
| `stock_configs/` | Directory | Kernel config backups |

Manual edits take effect on the next monitor loop cycle (~1 second).

---

## Troubleshooting

**Module not starting**
```sh
cat /data/local/tmp/adaptive_perf.log
ps -A | grep service.sh
su -c sh /data/adb/modules/adaptive_performance/service.sh   # manual start
```

**Governor not changing**
```sh
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
```
Verify the governor exists in that list. Some kernels restrict changes under thermal throttling.

**Dashboard not accessible**
```sh
ps -A | grep httpd
netstat -tuln | grep 9876
```

**Per-app governor not applying**
Check for conflicts — a package must not be in both lists:
```sh
adaptperf-list
adaptperf-listappgov
```

---

## Uninstallation

Magisk Manager / KernelSU → Modules → Remove → Reboot.

The uninstall restores the original CPU governor and removes all config and log files.

---

## Changelog

### v1.3 (August 2026)

**Fixed**
- `generate_config_json` no longer hardcodes governor list — all kernel-available governors now appear in dashboard dropdown (fixes missing vorpal, blu_schedutil, etc.)
- `detect_chipset` now identifies Exynos, Unisoc, and Tensor chipsets instead of falling back to "snapdragon"
- Per-app governor state now shows "CUSTOM" instead of "GAMING" in dashboard
- `uninstall.sh` now cleans up `app_governors.json` and `stock_configs/` directory
- Version string mismatch: customize.sh showed v1.1, now v1.3
- `killall httpd` in HTTP server replaced with targeted PID kill to avoid killing unrelated httpd processes
- API server response timing improved (reduced sleep from 0.3s to 0.2s)
- Game package add now verifies success via JSON refresh (no-cors response is opaque)
- Per-app governor add now verifies success via JSON refresh
- Dashboard log tab now auto-refreshes every 3s (was 5s)
- Duplicate game package and per-app conflict detection with error notifications
- Removed idle governor from main dashboard (moved to tuning tab)

**Added**
- Governor auto-detection for `vorpal` and `blu_schedutil`
- Exynos, Unisoc, and Tensor chipset detection
- `set_idle_governor` API endpoint — change idle governor from dashboard or CLI
- Idle and gaming governor both editable via dropdowns in tuning tab
- `get_status` API endpoint documented

**Improved**
- Uninstall now tries saved stock governor before generic fallback
- Service process cleanup more reliable (targeted pgrep instead of killall)
- Default game list now ships empty — user adds their own packages

### v1.2 (March 2026)

**Fixed**
- Bottom navigation bar keyboard push issue (visualViewport fix)
- Device Info blank on first load (retry until static.json ready)
- Governor dropdown reset during config polling

### v1.1 (December 2025)

**Added**
- Per-app governor system with CLI and dashboard support
- Conflict detection between game list and per-app config

### v1.0 (Initial Release)

- Basic game detection and governor switching
- CLI tools and web dashboard

---

Made by Steambot12
