#!/system/bin/sh
# Adaptive Performance – Clean Uninstall Script

MODDIR=${0%/*}
MODULE_PATH="/data/adb/modules/adaptive_performance"

# Stop service processes
for pid in $(pgrep -f "httpd.*9876" 2>/dev/null); do kill "$pid" 2>/dev/null; done
for pid in $(pgrep -f "nc.*9877" 2>/dev/null); do kill "$pid" 2>/dev/null; done
for pid in $(pgrep -f "service.sh" 2>/dev/null); do kill "$pid" 2>/dev/null; done

# Remove log and runtime files
rm -f /data/local/tmp/adaptive_perf.log 2>/dev/null

# Remove config files created by module
rm -f "$MODULE_PATH/governor_pref.txt" 2>/dev/null
rm -f "$MODULE_PATH/default_governor.txt" 2>/dev/null

# Remove JSON files generated at runtime
rm -f "$MODULE_PATH/webroot/dynamic.json" 2>/dev/null
rm -f "$MODULE_PATH/webroot/static.json" 2>/dev/null
rm -f "$MODULE_PATH/webroot/games.json" 2>/dev/null
rm -f "$MODULE_PATH/webroot/config.json" 2>/dev/null
rm -f "$MODULE_PATH/webroot/app_governors.json" 2>/dev/null
rm -f "$MODULE_PATH/webroot/log.txt" 2>/dev/null

# Remove stock config backups
rm -rf "$MODULE_PATH/stock_configs" 2>/dev/null

# Restore governor to stock (best effort)
# Try saved stock governor first, then common defaults
RESTORE_GOV=""
if [ -f "$MODULE_PATH/stock_configs/stock_governor.txt" ]; then
  RESTORE_GOV=$(cat "$MODULE_PATH/stock_configs/stock_governor.txt" 2>/dev/null | head -1 | tr -d ' \r\n\t')
fi

if [ -z "$RESTORE_GOV" ]; then
  AVAILABLE_GOVERNORS=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
  if echo "$AVAILABLE_GOVERNORS" | grep -q "schedutil"; then
    RESTORE_GOV="schedutil"
  elif echo "$AVAILABLE_GOVERNORS" | grep -q "walt"; then
    RESTORE_GOV="walt"
  else
    RESTORE_GOV=$(echo "$AVAILABLE_GOVERNORS" | awk '{print $1}')
  fi
fi

if [ -n "$RESTORE_GOV" ]; then
  NUM_CORES=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l)
  for cpu in $(seq 0 $((NUM_CORES - 1))); do
    echo "$RESTORE_GOV" > "/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor" 2>/dev/null
  done
fi

# Magisk will automatically remove the module folder
exit 0
