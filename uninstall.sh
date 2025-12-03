#!/system/bin/sh
# Adaptive Performance – Clean Uninstall Script

MODDIR=${0%/*}

# Stop service processes
killall httpd 2>/dev/null
killall nc 2>/dev/null

# Hapus log dan file runtime
rm -f /data/local/tmp/adaptive_perf.log 2>/dev/null

# Hapus file config yang dibuat module
rm -f /data/adb/modules/adaptive_performance/governor_pref.txt 2>/dev/null
rm -f /data/adb/modules/adaptive_performance/default_governor.txt 2>/dev/null

# Hapus JSON files yang di-generate runtime
rm -f /data/adb/modules/adaptive_performance/webroot/dynamic.json 2>/dev/null
rm -f /data/adb/modules/adaptive_performance/webroot/static.json 2>/dev/null
rm -f /data/adb/modules/adaptive_performance/webroot/games.json 2>/dev/null
rm -f /data/adb/modules/adaptive_performance/webroot/config.json 2>/dev/null
rm -f /data/adb/modules/adaptive_performance/webroot/log.txt 2>/dev/null

# Restore governor ke default (best effort)
AVAILABLE_GOVERNORS=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
if echo "$AVAILABLE_GOVERNORS" | grep -q "schedutil"; then
  RESTORE_GOV="schedutil"
elif echo "$AVAILABLE_GOVERNORS" | grep -q "walt"; then
  RESTORE_GOV="walt"
else
  RESTORE_GOV=$(echo "$AVAILABLE_GOVERNORS" | awk '{print $1}')
fi

if [ -n "$RESTORE_GOV" ]; then
  NUM_CORES=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l)
  for cpu in $(seq 0 $((NUM_CORES - 1))); do
    echo "$RESTORE_GOV" > "/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor" 2>/dev/null
  done
fi

# Magisk akan otomatis hapus folder module
exit 0
