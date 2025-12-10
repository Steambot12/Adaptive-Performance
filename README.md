# ⚡ Adaptive Performance

<div align="center">

![Version](https://img.shields.io/badge/version-1.1-blue.svg)
![Platform](https://img.shields.io/badge/platform-Android%208.0+-green.svg)
![Magisk](https://img.shields.io/badge/Magisk-20.4+-red.svg)

**Intelligent CPU governor management for Android gaming and daily use**

[Features](#-features) • [Installation](#-installation) • [Usage](#-usage) • [Dashboard](#-web-dashboard) • [CLI Reference](#-cli-reference)

</div>

---

## 📖 About

Adaptive Performance is a module that automatically switches CPU governors based on the foreground application. It intelligently balances performance and battery life by applying optimal governors for gaming, specific apps, or idle states.

### Why Use This?

- **Gaming**: Automatically apply performance governor when launching games
- **Customization**: Set different governors for different apps (e.g., conservative for browser, performance for benchmarks)
- **Efficiency**: Return to power-saving mode when idle
- **Transparency**: Monitor everything via web dashboard with real-time updates

---

## ✨ Features

<table>
<tr>
<td width="50%">

**Core Functionality**
- 🎮 Auto-detect game packages
- ⚙️ Per-app governor customization
- 🔄 Automatic governor switching
- 💾 Persist configuration after reboot
- 🛡️ Stock thermal management

</td>
<td width="50%">

**Management Tools**
- 🌐 Web dashboard (port 9876)
- 🖥️ Full CLI interface
- 📊 Real-time monitoring
- 🔧 REST API (port 9877)
- 📝 Comprehensive logging

</td>
</tr>
<tr>
<td width="50%">

**Compatibility**
- 📱 Android 8.0+
- 🔌 Mediatek & Snapdragon
- 🧩 Universal device support
- 💽 Auto kernel config backup
- ⚡ Multi-core CPU support

</td>
<td width="50%">

**Safety**
- ✅ Non-destructive installation
- 🔙 Automatic config restoration
- 🧪 Conflict validation
- 🔒 Stock config preservation
- 🗑️ Clean uninstallation

</td>
</tr>
</table>

---

## 📋 Requirements

- **Magisk** 20.4+ or **KernelSU**
- **Android** 8.0 (Oreo) or higher
- **Root access** (obviously)
- **Custom kernel** with multiple governors *(optional but recommended)*

> **Note**: Module works with stock kernels but benefits greatly from custom kernels that offer more governor options (e.g., Kirisakura, Stratosphere, Genom).

---

## 📦 Installation

### Method 1: Magisk Manager / KernelSU (Recommended)

1. Download the latest `AdaptivePerformance-v1.1.zip` from [Releases](https://github.com/Steambot12/Adaptive-Performance/releases)
2. Open Magisk Manager/KernelSU → **Modules** → **Install from storage**
3. Select the downloaded ZIP file
4. Wait for installation to complete
5. **Reboot** your device
6. Verify installation:
adaptperf-status


### Method 2: ADB Sideload

adb push AdaptivePerformance-v1.1.zip /sdcard/
adb shell su -c magisk --install-module /sdcard/AdaptivePerformance-v1.1.zip
adb reboot


### What Happens During Installation

- ✅ Detects and saves stock CPU governor
- ✅ Backs up kernel configuration
- ✅ Creates default game list (Delta Force, Mobile Legends)
- ✅ Sets up CLI commands in `/system/bin/`
- ✅ Prepares web dashboard files

---

## 🚀 Quick Start

After installation and reboot, the module automatically starts. Here's how to get going:

### 1. Check Status
adaptperf-status


### 2. Access Dashboard
Open browser and navigate to:
http://127.0.0.1:9876


### 3. Add Your Games
adaptperf-add com.tencent.ig # PUBG Mobile
adaptperf-add com.dts.freefireth # Free Fire


### 4. Customize Governor (Optional)
Set gaming governor
adaptperf-setgov schedutil

Set per-app governor
adaptperf-setappgov com.android.chrome conservative


---

## 💻 Usage

### 🌐 Web Dashboard

The web interface provides comprehensive monitoring and management capabilities.

**Access Locally:**
http://127.0.0.1:9876


**Access from PC:**
Forward port via ADB
adb forward tcp:9876 tcp:9876

Open in browser
http://localhost:9876


#### Dashboard Features

| Tab | Features |
|-----|----------|
| **Main** | • Real-time mode indicator (IDLE/GAMING/CUSTOM)<br>• Current CPU governor<br>• Foreground application<br>• Device temperature monitoring<br>• Device & kernel information |
| **Tuning** | • Governor configuration (idle/gaming)<br>• Game package manager<br>• Per-app governor settings<br>• Auto-detect installed games<br>• Instant apply changes |
| **Log** | • Real-time log viewer<br>• Auto-refresh capability<br>• Clear display option<br>• Event tracking |

---

### 🖥️ CLI Reference

All commands are available globally after installation.

#### Game Management

Add game to list
adaptperf-add <package_name>

Remove game from list
adaptperf-remove <package_name>

List all registered games
adaptperf-list


**Examples:**
adaptperf-add com.garena.game.df
adaptperf-remove com.proxima.dfm


#### Governor Configuration

Set gaming governor (applied when game is running)
adaptperf-setgov <governor_name>

View available governors
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors


**Examples:**
adaptperf-setgov schedutil
adaptperf-setgov performance


#### Per-App Governor

Set custom governors for specific applications (non-games):

Set custom governor for an app
adaptperf-setappgov <package_name> <governor_name>

Remove custom governor
adaptperf-delappgov <package_name>

List all per-app configurations
adaptperf-listappgov


**Examples:**
Use conservative governor for Chrome
adaptperf-setappgov com.android.chrome conservative

Use ondemand for YouTube
adaptperf-setappgov com.google.android.youtube ondemand

Remove Chrome's custom governor
adaptperf-delappgov com.android.chrome


> **⚠️ Important**: A package cannot exist in both game list AND per-app governor config. Remove from one before adding to another.

#### Status & Monitoring

View module status and recent log
adaptperf-status

View full log
cat /data/local/tmp/adaptive_perf.log

Monitor log in real-time
tail -f /data/local/tmp/adaptive_perf.log


---

## 🔧 Advanced Configuration

### Configuration Files

All configuration files are located in `/data/adb/modules/adaptive_performance/`:

| File | Purpose | Format |
|------|---------|--------|
| `game_packages.txt` | Registered game packages | One package per line |
| `app_governors.txt` | Per-app governor mappings | `package=governor` |
| `governor_pref.txt` | Gaming governor preference | Single governor name |
| `default_governor.txt` | Idle/stock governor | Single governor name |
| `stock_configs/` | Kernel config backups | Directory with backup files |

### Manual Configuration

You can manually edit configuration files:

Edit game list
vi /data/adb/modules/adaptive_performance/game_packages.txt

Edit per-app governors
vi /data/adb/modules/adaptive_performance/app_governors.txt

Format for app_governors.txt:
com.android.chrome=conservative
com.google.android.youtube=ondemand

After manual edits, changes apply immediately (no reboot needed).

---

## 🌐 REST API

The module exposes a REST API on port **9877** for automation and scripting.

### Endpoints

| Endpoint | Method | Parameters | Description |
|----------|--------|------------|-------------|
| `/?action=add` | GET | `pkg` | Add game package |
| `/?action=remove` | GET | `pkg` | Remove game package |
| `/?action=set_governor` | GET | `governor` | Set gaming governor |
| `/?action=set_app_governor` | GET | `pkg`, `governor` | Set per-app governor |
| `/?action=remove_app_governor` | GET | `pkg` | Remove per-app governor |
| `/?action=detect_games` | GET | - | Auto-detect installed games |

### API Examples

**Using netcat (nc):**
Add game
echo "" | nc 127.0.0.1 9877 << EOF
GET /?action=add&pkg=com.tencent.ig HTTP/1.1
Host: 127.0.0.1
Connection: close

EOF


**Using curl (if available):**
curl "http://127.0.0.1:9877/?action=set_governor&governor=schedutil"


**Package name encoding:**
- Replace `.` with `%2E` in package names
- Example: `com.android.chrome` → `com%2Eandroid%2Echrome`

---

## 🎯 How It Works

### Monitoring Loop

The module runs a background service that:

1. **Detects** foreground app every 1 second
2. **Checks** if app matches:
   - Game list → Apply gaming governor
   - Per-app config → Apply custom governor
   - Neither → Apply idle governor
3. **Applies** governor to all CPU cores
4. **Logs** all state changes


### Governor Detection Logic

**For Idle Mode (Default):**
1. User-saved governor (if exists)
2. Stock governor (detected at install)
3. Auto-detect based on chipset:
   - **Mediatek**: `sugov_ext` → `schedutil` → `walt` → `interactive` → `ondemand`
   - **Snapdragon**: `walt` → `schedutil` → `interactive` → `ondemand`

**For Gaming Mode:**
1. User preference (from `governor_pref.txt`)
2. Auto-detect optimal governor:
   - **Mediatek**: `schedhorizon` → `schedutil` → `performance`
   - **Snapdragon**: `schedutil` → `performance`

### Backup & Restore

Module automatically backs up:
- ✅ Original governor name
- ✅ CPU frequency limits (min/max)
- ✅ Governor tunables (all parameters)

Backups are stored in `stock_configs/` and restored when switching to idle mode.

---

## 🐛 Troubleshooting

### Module Not Starting After Reboot

**Check log:**
cat /data/local/tmp/adaptive_perf.log


**Verify service:**
ps | grep service.sh


**Manual start (debug):**
su
sh /data/adb/modules/adaptive_performance/service.sh


### Governor Not Changing

**Check available governors:**
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors


**Possible causes:**
- Selected governor not supported by kernel
- Kernel doesn't allow governor changes
- Thermal throttling override

**Solution:**
List what your kernel supports
adaptperf-status

Try a different governor
adaptperf-setgov schedutil


### Dashboard Not Accessible

**Check HTTP server:**
ps | grep httpd
netstat -tuln | grep 9876


**Restart services:**
Kill existing processes
killall httpd nc

Reboot to restart module
reboot


**Port forwarding (for PC access):**
adb forward tcp:9876 tcp:9876
adb forward tcp:9877 tcp:9877


### Per-App Governor Not Applying

**Check for conflicts:**
List games
adaptperf-list

List per-app governors
adaptperf-listappgov


**Ensure package is not in both lists:**
Remove from game list if needed
adaptperf-remove com.example.app

Then set per-app governor
adaptperf-setappgov com.example.app conservative


**Monitor real-time:**
tail -f /data/local/tmp/adaptive_perf.log


### Temperature Reading Issues

Some devices don't expose temperature via standard thermal zones. This is normal and doesn't affect governor switching functionality.

---

## 🗑️ Uninstallation

### Via Magisk Manager / KernelSU

1. Open Magisk Manager / KernelSU
2. Go to **Modules**
3. Find **Adaptive Performance**
4. Click **Remove**
5. Reboot

### Manual Uninstall

rm -rf /data/adb/modules/adaptive_performance
reboot


### What Gets Cleaned

The uninstall script automatically:
- ✅ Stops all service processes (`httpd`, `nc`)
- ✅ Removes runtime files and logs
- ✅ Restores original CPU governor
- ✅ Cleans up all configuration files
- ✅ Removes module directory (Magisk handles this)

> **Note**: User data in `/data/local/tmp/` is preserved unless manually deleted.

---

## 📊 Default Configuration

### Pre-configured Games

The module includes these games by default:

com.garena.game.df # Delta Force
com.proxima.dfm # Delta Force Mobile
com.mobile.legends # Mobile Legends


### Default Ports

- **HTTP Dashboard**: `9876`
- **REST API**: `9877`

### Default Paths

- **Module directory**: `/data/adb/modules/adaptive_performance/`
- **Log file**: `/data/local/tmp/adaptive_perf.log`
- **CLI commands**: `/system/bin/adaptperf-*`

---

## 🛠️ Development & Contribution

### Building from Source

Clone repository
git clone https://github.com/Steambot12/Adaptive-Performance.git
cd Adaptive-Performance

Create flashable ZIP
zip -r9 AdaptivePerformance-v1.1.zip * -x ".git" ".md" ".zip"


### Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## 📝 Changelog

### v1.1 (Current - December 2025)

**New Features:**
- ✨ Per-app governor support
- 🌐 Enhanced web dashboard
- 🔍 Conflict detection and validation
- 📊 Improved logging system
- 🔧 Expanded REST API endpoints

**Improvements:**
- ⚡ Better governor detection logic
- 🔄 Faster app switching response
- 💾 More reliable config persistence
- 📝 Comprehensive CLI help messages

**Bug Fixes:**
- 🐛 Fixed race condition in app detection
- 🐛 Resolved thermal reading on some devices
- 🐛 Corrected governor tunable restoration

### v1.0 (Initial Release)

- 🎮 Basic game detection
- ⚙️ Automatic governor switching
- 🖥️ CLI tools
- 📊 Web dashboard (basic)

---


### Inspiration

This project was inspired by:
- Various kernel tweaker modules
- Performance optimization discussions on Group POCO F5
- Mobile gaming communities' need for adaptive performance

---

## 📞 Support & Contact

### Found a Bug?

Open an issue on GitHub with:
- Device model
- Android version
- Kernel name
- Log file (`/data/local/tmp/adaptive_perf.log`)
- Steps to reproduce

### Feature Requests

Open an issue with the `enhancement` label and describe:
- What you want
- Why it's useful
- How it should work

### Community

- **GitHub Issues**: [Report bugs & request features](https://github.com/Steambot12/Adaptive-Performance/issues)
- **Telegram**: *(Coming soon)*

---

<div align="center">

### 🌟 If you find this useful, consider starring the repo!

**Made with ❤️ by Steambot12**

[⬆ Back to Top](#-adaptive-performance)

</div>
