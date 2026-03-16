#!/system/bin/sh
# Adaptive Performance v1.2 - Fixed Edition

MODDIR=${0%/*}

HTTP_PORT=9876
API_PORT=9877
LOG=/data/local/tmp/adaptive_perf.log
LOG_MAX_SIZE=1048576

GAME_PACKAGES="$MODDIR/game_packages.txt"
GOVERNOR_PREF="$MODDIR/governor_pref.txt"
APP_GOVERNORS="$MODDIR/app_governors.txt"
DEFAULT_GOV_FILE="$MODDIR/default_governor.txt"
STOCK_CONFIG_DIR="$MODDIR/stock_configs"

JSON_DYNAMIC="$MODDIR/webroot/dynamic.json"
JSON_STATIC="$MODDIR/webroot/static.json"
JSON_GAMES="$MODDIR/webroot/games.json"
JSON_CONFIG="$MODDIR/webroot/config.json"
JSON_APP_GOVS="$MODDIR/webroot/app_governors.json"

WEBROOT="$MODDIR/webroot"
CPU_BASE="/sys/devices/system/cpu"

# Thermal protection thresholds (millidegree Celsius)
THERMAL_WARNING=65000
THERMAL_CRITICAL=75000
THERMAL_TRIGGERED=0

log() {
  # Rotate log if too large
  if [ -f "$LOG" ] && [ $(wc -c < "$LOG" 2>/dev/null || echo 0) -gt $LOG_MAX_SIZE ]; then
    tail -200 "$LOG" > "${LOG}.tmp" 2>/dev/null && mv -f "${LOG}.tmp" "$LOG"
  fi
  echo "[$(date '+%H:%M:%S')] $1" >> $LOG 2>&1
}

while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 1
done

log "================================================"
log "Adaptive Performance v1.2 - Fixed Edition"
log "================================================"

mkdir -p $WEBROOT 2>/dev/null
chmod 777 $WEBROOT 2>/dev/null
mkdir -p $STOCK_CONFIG_DIR 2>/dev/null
chmod 755 $STOCK_CONFIG_DIR 2>/dev/null

# API FIFO for stable IPC (fix race condition)
API_FIFO="/data/local/tmp/adaptperf_api.fifo"
rm -f "$API_FIFO" 2>/dev/null
mkfifo "$API_FIFO" 2>/dev/null
chmod 666 "$API_FIFO" 2>/dev/null

if [ ! -f "$GAME_PACKAGES" ]; then
  cat > "$GAME_PACKAGES" << 'EOF'
com.miHoYo.GenshinImpact
com.activision.callofduty.shooter
com.mobile.legends
com.garena.game.df
com.proxima.dfm
com.YoStarEN.Kuro.WutheringWaves
EOF
fi
chmod 666 "$GAME_PACKAGES" 2>/dev/null

if [ ! -f "$APP_GOVERNORS" ]; then
  touch "$APP_GOVERNORS"
fi
chmod 666 "$APP_GOVERNORS" 2>/dev/null

if [ -s "$APP_GOVERNORS" ]; then
  log "📋 Per-App Governors loaded from previous session:"
  while IFS='=' read -r pkg gov; do
    [ -z "$pkg" ] && continue
    pkg=$(echo "$pkg" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    gov=$(echo "$gov" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    log "  • $pkg → $gov"
  done < "$APP_GOVERNORS"
else
  log "📋 No per-app governors configured"
fi

get_num_cores() {
  ls -d ${CPU_BASE}/cpu[0-9]* 2>/dev/null | wc -l
}
NUM_CORES=$(get_num_cores)

detect_chipset() {
  local platform=$(getprop ro.board.platform 2>/dev/null)
  local hardware=$(getprop ro.hardware 2>/dev/null)
  local soc=$(getprop ro.soc.model 2>/dev/null)
  if echo "$platform$hardware$soc" | grep -qiE "mt[0-9]+|mediatek|dimensity"; then
    echo "mediatek"
  else
    echo "snapdragon"
  fi
}
CHIPSET=$(detect_chipset)
log "Chipset: $CHIPSET"

AVAILABLE_GOVERNORS=$(cat ${CPU_BASE}/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
log "Available governors: $AVAILABLE_GOVERNORS"

backup_initial_config() {
  log "📦 Backing up initial kernel config..."
  local cpu0="${CPU_BASE}/cpu0/cpufreq"
  local current_gov=$(cat $cpu0/scaling_governor 2>/dev/null)
  echo "$current_gov" > "$STOCK_CONFIG_DIR/stock_governor.txt"
  log "Stock governor: $current_gov"
  cat $cpu0/scaling_min_freq 2>/dev/null > "$STOCK_CONFIG_DIR/scaling_min_freq.txt"
  cat $cpu0/scaling_max_freq 2>/dev/null > "$STOCK_CONFIG_DIR/scaling_max_freq.txt"
  backup_governor_tunables "$current_gov"
  log "✅ Initial config backed up"
}

backup_governor_tunables() {
  local gov="$1"
  local cpu0="${CPU_BASE}/cpu0/cpufreq"
  local tunable_dir="$cpu0/${gov}"
  if [ -f "$STOCK_CONFIG_DIR/$gov/.backup_done" ]; then
    return 0
  fi
  if [ ! -d "$tunable_dir" ]; then
    return 1
  fi
  mkdir -p "$STOCK_CONFIG_DIR/$gov" 2>/dev/null
  local count=0
  for tunable in $(ls $tunable_dir 2>/dev/null); do
    local file="$tunable_dir/$tunable"
    if [ -f "$file" ] && [ -r "$file" ]; then
      cat "$file" 2>/dev/null > "$STOCK_CONFIG_DIR/$gov/$tunable"
      count=$((count + 1))
    fi
  done
  touch "$STOCK_CONFIG_DIR/$gov/.backup_done"
  log "  └─ Backed up $count tunables for $gov"
  return 0
}

restore_governor_config() {
  local target_gov="$1"
  local max_cpu=$((NUM_CORES - 1))

  log "🔧 Switching to: $target_gov (all $NUM_CORES cores)"

  for cpu in $(seq 0 $max_cpu); do
    local cpu_dir="${CPU_BASE}/cpu${cpu}/cpufreq"
    [ -d "$cpu_dir" ] || continue

    # Restore min/max freq
    if [ -f "$STOCK_CONFIG_DIR/scaling_min_freq.txt" ]; then
      cat "$STOCK_CONFIG_DIR/scaling_min_freq.txt" > "$cpu_dir/scaling_min_freq" 2>/dev/null
    fi
    if [ -f "$STOCK_CONFIG_DIR/scaling_max_freq.txt" ]; then
      cat "$STOCK_CONFIG_DIR/scaling_max_freq.txt" > "$cpu_dir/scaling_max_freq" 2>/dev/null
    fi

    # Set governor
    echo "$target_gov" > "$cpu_dir/scaling_governor" 2>/dev/null

    # Restore tunables for this core
    local tunable_dir="$cpu_dir/${target_gov}"
    local tunable_backup="$STOCK_CONFIG_DIR/$target_gov"
    if [ -d "$tunable_dir" ] && [ -d "$tunable_backup" ] && [ -f "$tunable_backup/.backup_done" ]; then
      local restored=0
      for tunable_file in $(ls $tunable_backup 2>/dev/null); do
        [ "$tunable_file" = ".backup_done" ] && continue
        local target_path="$tunable_dir/$tunable_file"
        local source_path="$tunable_backup/$tunable_file"
        if [ -f "$target_path" ] && [ -w "$target_path" ] && [ -f "$source_path" ]; then
          cat "$source_path" > "$target_path" 2>/dev/null
          restored=$((restored + 1))
        fi
      done
      [ $cpu -eq 0 ] && log "  ├─ cpu0: restored $restored tunables for $target_gov"
    fi
  done

  log "  └─ Done: $target_gov applied to all cores"
}

detect_default_governor() {
  local default_gov=""
  if [ -f "$DEFAULT_GOV_FILE" ]; then
    local saved_gov=$(cat "$DEFAULT_GOV_FILE" 2>/dev/null | head -1 | tr -d '\r\n\t')
    if [ -n "$saved_gov" ] && echo "$AVAILABLE_GOVERNORS" | grep -q "$saved_gov"; then
      if [ "$saved_gov" != "performance" ]; then
        echo "$saved_gov"
        return
      fi
    fi
  fi
  if [ -f "$STOCK_CONFIG_DIR/stock_governor.txt" ]; then
    local stock_gov=$(cat "$STOCK_CONFIG_DIR/stock_governor.txt" 2>/dev/null)
    if [ -n "$stock_gov" ] && [ "$stock_gov" != "performance" ]; then
      echo "$stock_gov"
      return
    fi
  fi
  if [ "$CHIPSET" = "mediatek" ]; then
    if echo "$AVAILABLE_GOVERNORS" | grep -q "sugov_ext"; then
      default_gov="sugov_ext"
    elif echo "$AVAILABLE_GOVERNORS" | grep -q "schedutil"; then
      default_gov="schedutil"
    elif echo "$AVAILABLE_GOVERNORS" | grep -q "walt"; then
      default_gov="walt"
    elif echo "$AVAILABLE_GOVERNORS" | grep -q "interactive"; then
      default_gov="interactive"
    elif echo "$AVAILABLE_GOVERNORS" | grep -q "ondemand"; then
      default_gov="ondemand"
    else
      for gov in $AVAILABLE_GOVERNORS; do
        if [ "$gov" != "performance" ]; then
          default_gov="$gov"
          break
        fi
      done
      [ -z "$default_gov" ] && default_gov="performance"
    fi
  else
    if echo "$AVAILABLE_GOVERNORS" | grep -q "walt"; then
      default_gov="walt"
    elif echo "$AVAILABLE_GOVERNORS" | grep -q "schedutil"; then
      default_gov="schedutil"
    elif echo "$AVAILABLE_GOVERNORS" | grep -q "interactive"; then
      default_gov="interactive"
    elif echo "$AVAILABLE_GOVERNORS" | grep -q "ondemand"; then
      default_gov="ondemand"
    else
      for gov in $AVAILABLE_GOVERNORS; do
        if [ "$gov" != "performance" ]; then
          default_gov="$gov"
          break
        fi
      done
      [ -z "$default_gov" ] && default_gov="performance"
    fi
  fi
  echo "$default_gov"
}

detect_gaming_governor() {
  local gaming_gov=""
  if [ "$CHIPSET" = "mediatek" ]; then
    if echo "$AVAILABLE_GOVERNORS" | grep -q "schedhorizon"; then
      gaming_gov="schedhorizon"
    elif echo "$AVAILABLE_GOVERNORS" | grep -q "schedutil"; then
      gaming_gov="schedutil"
    elif echo "$AVAILABLE_GOVERNORS" | grep -q "performance"; then
      gaming_gov="performance"
    else
      gaming_gov="schedutil"
    fi
  else
    if echo "$AVAILABLE_GOVERNORS" | grep -q "schedutil"; then
      gaming_gov="schedutil"
    elif echo "$AVAILABLE_GOVERNORS" | grep -q "performance"; then
      gaming_gov="performance"
    else
      gaming_gov=$(echo "$AVAILABLE_GOVERNORS" | awk '{print $1}')
    fi
  fi
  echo "$gaming_gov"
}

load_gaming_governor() {
  if [ -f "$GOVERNOR_PREF" ]; then
    local pref=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -n "$pref" ] && echo "$AVAILABLE_GOVERNORS" | grep -q "$pref"; then
      echo "$pref"
      return
    fi
  fi
  local default=$(detect_gaming_governor)
  echo "$default" > "$GOVERNOR_PREF" 2>/dev/null
  chmod 666 "$GOVERNOR_PREF" 2>/dev/null
  echo "$default"
}

get_foreground_app() {
  FG=$(dumpsys window 2>/dev/null | grep -i "mCurrentFocus" | grep -oE '[a-z][a-z0-9_.]*\.[a-zA-Z0-9_.]+' | head -1)
  [ -z "$FG" ] && FG=$(dumpsys activity activities 2>/dev/null | grep "mResumedActivity" | grep -oE '[a-z][a-z0-9_.]*\.[a-zA-Z0-9_.]+' | head -1)
  echo "$FG"
}

get_app_governor() {
    local app="$1"
    [ -z "$app" ] || [ ! -f "$APP_GOVERNORS" ] && return 1
    while IFS='=' read -r pkg gov; do
        [ -z "$pkg" ] && continue
        pkg=$(echo "$pkg" | tr -d '\r\n\t ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        gov=$(echo "$gov" | tr -d '\r\n\t ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ "$app" = "$pkg" ] && echo "$gov" && return 0
    done < "$APP_GOVERNORS"
    return 1
}

set_app_governor() {
    local pkg="$1"
    local gov="$2"
    log "🔧 SET PER-APP: $pkg = $gov"
    [ -z "$pkg" ] || [ -z "$gov" ] && return 1
    pkg=$(echo "$pkg" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    gov=$(echo "$gov" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    echo "$AVAILABLE_GOVERNORS" | grep -q "$gov" || {
        log "❌ Invalid governor: $gov"
        return 1
    }
    if [ -f "$GAME_PACKAGES" ] && grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null; then
        log "❌ Conflict: Package exists in game list"
        return 1
    fi
    if [ -f "$APP_GOVERNORS" ] && grep -q "^${pkg}=" "$APP_GOVERNORS" 2>/dev/null; then
        grep -v "^${pkg}=" "$APP_GOVERNORS" > "${APP_GOVERNORS}.tmp" 2>/dev/null
        mv -f "${APP_GOVERNORS}.tmp" "$APP_GOVERNORS"
    fi
    echo "${pkg}=${gov}" >> "$APP_GOVERNORS"
    chmod 666 "$APP_GOVERNORS" 2>/dev/null
    sync
    sleep 0.3
    sync
    log "✅ Configured: $pkg → $gov (persists after reboot)"
    generate_app_governors_json
    return 0
}

remove_app_governor() {
    local pkg="$1"
    log "🗑️  REMOVE PER-APP GOVERNOR: $pkg"
    [ -z "$pkg" ] && {
        log "❌ Empty package"
        return 1
    }
    pkg=$(echo "$pkg" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ ! -f "$APP_GOVERNORS" ]; then
        touch "$APP_GOVERNORS"
        chmod 666 "$APP_GOVERNORS" 2>/dev/null
    fi
    local was_in_file=0
    if grep -q "^${pkg}=" "$APP_GOVERNORS" 2>/dev/null; then
        was_in_file=1
        grep -v "^${pkg}=" "$APP_GOVERNORS" > "${APP_GOVERNORS}.tmp" 2>/dev/null
        mv -f "${APP_GOVERNORS}.tmp" "$APP_GOVERNORS"
        chmod 666 "$APP_GOVERNORS" 2>/dev/null
        sync
        sleep 0.2
        sync
        log "✅ Removed from file"
    fi
    generate_app_governors_json
    local current_fg=$(get_foreground_app)
    if [ "$current_fg" = "$pkg" ]; then
        log "🚨 Active app removed - resetting to default governor"
        restore_governor_config "$DEFAULT_GOVERNOR"
        log "✅ Reset to: $DEFAULT_GOVERNOR"
    fi
    return 0
}

generate_app_governors_json() {
    local app_govs_array=""
    local count=0
    if [ -f "$APP_GOVERNORS" ] && [ -s "$APP_GOVERNORS" ]; then
        while IFS='=' read -r pkg gov; do
            [ -z "$pkg" ] && continue
            pkg=$(echo "$pkg" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            gov=$(echo "$gov" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$pkg" ] || [ -z "$gov" ] && continue
            if [ $count -eq 0 ]; then
                app_govs_array="{\"package\":\"${pkg}\",\"governor\":\"${gov}\"}"
            else
                app_govs_array="${app_govs_array},{\"package\":\"${pkg}\",\"governor\":\"${gov}\"}"
            fi
            count=$((count + 1))
        done < "$APP_GOVERNORS"
    fi
    local timestamp=$(date +%s)000
    printf '{"status":"success","app_governors":[%s],"count":%d,"timestamp":%s}' \
        "$app_govs_array" "$count" "$timestamp" > "$JSON_APP_GOVS"
    chmod 666 "$JSON_APP_GOVS" 2>/dev/null
}

backup_initial_config
DEFAULT_GOVERNOR=$(detect_default_governor)
log "💤 Idle governor: $DEFAULT_GOVERNOR"
GAMING_GOVERNOR=$(load_gaming_governor)
log "🎮 Gaming governor: $GAMING_GOVERNOR"

generate_config_json() {
  local gaming_gov=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d '\r\n\t' || echo "$GAMING_GOVERNOR")
  local gov_options=""
  local count=0
  for gov in schedutil schedhorizon ondemand performance interactive conservative powersave walt sugov_ext; do
    if echo "$AVAILABLE_GOVERNORS" | grep -q "$gov"; then
      [ $count -eq 0 ] && gov_options="\"$gov\"" || gov_options="$gov_options,\"$gov\""
      count=$((count + 1))
    fi
  done
  printf '{"chipset":"%s","default_idle":"%s","gaming_governor":"%s","available_governors":[%s],"all_governors":"%s"}' \
    "$CHIPSET" "$DEFAULT_GOVERNOR" "$gaming_gov" "$gov_options" "$AVAILABLE_GOVERNORS" > "$JSON_CONFIG"
  chmod 666 "$JSON_CONFIG" 2>/dev/null
}

generate_games_json() {
  local games_array=""
  local count=0
  if [ -f "$GAME_PACKAGES" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      case "$line" in "#"*) continue ;; esac
      line=$(echo "$line" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' 2>/dev/null)
      [ -z "$line" ] && continue
      [ $count -eq 0 ] && games_array="\"${line}\"" || games_array="${games_array},\"${line}\""
      count=$((count + 1))
    done < "$GAME_PACKAGES"
  fi
  local timestamp=$(date +%s)000
  printf '{"status":"success","games":[%s],"count":%d,"timestamp":%s}' \
    "$games_array" "$count" "$timestamp" > "$JSON_GAMES"
  chmod 666 "$JSON_GAMES" 2>/dev/null
}

generate_static_json() {
  local device=$(getprop ro.product.model 2>/dev/null || echo "Unknown")
  local kernel=$(uname -r 2>/dev/null || echo "Unknown")
  printf '{"cores":%d,"kernel":"%s","device":"%s","default_governor":"%s","chipset":"%s"}' \
    "$NUM_CORES" "$kernel" "$device" "$DEFAULT_GOVERNOR" "$CHIPSET" > "$JSON_STATIC"
  chmod 666 "$JSON_STATIC" 2>/dev/null
}

generate_dynamic_json() {
  local foreground="$1"
  local state="$2"
  local governor=$(cat ${CPU_BASE}/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
  local temp=$(get_temperature)
  [ -z "$foreground" ] && foreground="unknown"
  local freqs=""
  local max_cpu=3
  [ $NUM_CORES -lt 4 ] && max_cpu=$((NUM_CORES - 1))
  for cpu in $(seq 0 $max_cpu); do
    local freq=$(cat ${CPU_BASE}/cpu${cpu}/cpufreq/scaling_cur_freq 2>/dev/null || echo "0")
    [ $cpu -eq 0 ] && freqs="$freq" || freqs="$freqs,$freq"
  done
  printf '{"governor":"%s","foreground":"%s","temperature":%d,"frequencies":[%s],"state":"%s","timestamp":%d}' \
    "$governor" "$foreground" "$temp" "$freqs" "$state" "$(date +%s)" > "$JSON_DYNAMIC"
  chmod 666 "$JSON_DYNAMIC" 2>/dev/null
}

add_package() {
  local pkg="$1"
  [ -z "$pkg" ] && return 1
  pkg=$(echo "$pkg" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' 2>/dev/null)
  echo "$pkg" | grep -Eq '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$' 2>/dev/null || return 1
  if grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null; then
    log "⚠️ Duplicate: Package already in game list"
    generate_games_json
    return 1
  fi
  if [ -f "$APP_GOVERNORS" ] && grep -q "^${pkg}=" "$APP_GOVERNORS" 2>/dev/null; then
    log "❌ Conflict: Package in per-app governor list"
    return 1
  fi
  echo "$pkg" >> "$GAME_PACKAGES"
  chmod 666 "$GAME_PACKAGES" 2>/dev/null
  sync
  log "➕ ADDED to game list: $pkg"
  generate_games_json
  return 0
}

remove_package() {
  local pkg="$1"
  [ -z "$pkg" ] && return 1
  pkg=$(echo "$pkg" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' 2>/dev/null)
  if ! grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null; then
    generate_games_json
    return 0
  fi
  grep -Fxv "$pkg" "$GAME_PACKAGES" > "${GAME_PACKAGES}.tmp" 2>/dev/null
  mv -f "${GAME_PACKAGES}.tmp" "$GAME_PACKAGES"
  chmod 666 "$GAME_PACKAGES" 2>/dev/null
  sync
  log "🗑️ REMOVED from game list: $pkg"
  generate_games_json
  return 0
}

set_gaming_governor() {
  local gov="$1"
  [ -z "$gov" ] && return 1
  gov=$(echo "$gov" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' 2>/dev/null)
  echo "$AVAILABLE_GOVERNORS" | grep -q "$gov" || return 1
  echo "$gov" > "$GOVERNOR_PREF"
  chmod 666 "$GOVERNOR_PREF" 2>/dev/null
  sync
  GAMING_GOVERNOR="$gov"
  log "⚙️ Gaming governor updated: $gov"
  generate_config_json
  return 0
}

# ============================================================
# API SERVER - Fixed: gunakan FIFO + single nc listener
# Tidak ada lagi double nc / race condition
# ============================================================
start_api_server() {
  # Background listener: tulis raw request ke FIFO
  while true; do
    REQUEST=$(nc -l -p $API_PORT -w 2 2>/dev/null | head -5)
    echo "$REQUEST" > "$API_FIFO" 2>/dev/null &
    sleep 0.1
  done &

  # Processor: baca dari FIFO, proses, kirim response
  while true; do
    if [ -p "$API_FIFO" ]; then
      REQUEST=$(cat "$API_FIFO" 2>/dev/null)
    else
      sleep 0.5
      continue
    fi

    GET_LINE=$(echo "$REQUEST" | head -1)
    QUERY=$(echo "$GET_LINE" | grep -oE '\?[^ ]+' | cut -c2-)
    ACTION=""
    PKG=""
    GOVERNOR=""

    if [ -n "$QUERY" ]; then
      for param in $(echo "$QUERY" | tr '&' '\n'); do
        KEY=$(echo "$param" | cut -d= -f1)
        VAL=$(echo "$param" | cut -d= -f2- | sed 's/%2E/./g; s/%20/ /g; s/+/ /g' 2>/dev/null)
        case "$KEY" in
          "action") ACTION="$VAL" ;;
          "pkg") PKG="$VAL" ;;
          "governor") GOVERNOR="$VAL" ;;
        esac
      done
    fi

    [ -z "$ACTION" ] && sleep 0.2 && continue

    RESPONSE=""
    case "$ACTION" in
      "add")
        [ -z "$PKG" ] && RESPONSE='{"status":"error","message":"Missing pkg"}' || {
          add_package "$PKG" && RESPONSE='{"status":"success","message":"Added","package":"'$PKG'"}' || RESPONSE='{"status":"error","message":"Failed or duplicate"}'
        }
        ;;
      "remove")
        [ -z "$PKG" ] && RESPONSE='{"status":"error","message":"Missing pkg"}' || {
          remove_package "$PKG" && RESPONSE='{"status":"success","message":"Removed","package":"'$PKG'"}' || RESPONSE='{"status":"error","message":"Failed"}'
        }
        ;;
      "set_governor")
        [ -z "$GOVERNOR" ] && RESPONSE='{"status":"error","message":"Missing governor"}' || {
          set_gaming_governor "$GOVERNOR" && RESPONSE='{"status":"success","message":"Governor set","governor":"'$GOVERNOR'"}' || RESPONSE='{"status":"error","message":"Failed"}'
        }
        ;;
      "set_app_governor")
        [ -z "$PKG" ] || [ -z "$GOVERNOR" ] && RESPONSE='{"status":"error","message":"Missing pkg or governor"}' || {
          set_app_governor "$PKG" "$GOVERNOR" && RESPONSE='{"status":"success","message":"App governor set","package":"'$PKG'","governor":"'$GOVERNOR'"}' || RESPONSE='{"status":"error","message":"Failed"}'
        }
        ;;
      "remove_app_governor")
        [ -z "$PKG" ] && RESPONSE='{"status":"error","message":"Missing pkg"}' || {
          remove_app_governor "$PKG" && RESPONSE='{"status":"success","message":"App governor removed","package":"'$PKG'"}' || RESPONSE='{"status":"error","message":"Failed"}'
        }
        ;;
      *)
        RESPONSE='{"status":"error","message":"Invalid action"}'
        ;;
    esac

    # Kirim response sekali, satu nc, tanpa race
    printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n%s" \
      "${#RESPONSE}" "$RESPONSE" | nc -l -p $API_PORT -w 1 >/dev/null 2>&1

    sleep 0.2
  done
}

is_game() {
  local app="$1"
  [ -z "$app" ] && return 1
  [ ! -f "$GAME_PACKAGES" ] && return 1
  while IFS= read -r package || [ -n "$package" ]; do
    case "$package" in "#"|"") continue ;; esac
    package=$(echo "$package" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' 2>/dev/null)
    [ "$app" = "$package" ] && return 0
  done < "$GAME_PACKAGES"
  return 1
}

apply_performance() {
  local new_gaming_gov=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d '\r\n\t')
  if [ -n "$new_gaming_gov" ] && echo "$AVAILABLE_GOVERNORS" | grep -q "$new_gaming_gov"; then
    GAMING_GOVERNOR="$new_gaming_gov"
  fi
  restore_governor_config "$GAMING_GOVERNOR"
  log "🎮 MODE: GAMING → $GAMING_GOVERNOR"
}

apply_powersave() {
  restore_governor_config "$DEFAULT_GOVERNOR"
  log "💤 MODE: IDLE → $DEFAULT_GOVERNOR"
}

apply_app_governor() {
  local app_gov="$1"
  restore_governor_config "$app_gov"
  log "🎯 MODE: PER-APP → $app_gov"
}

get_temperature() {
  local temp=0
  for i in 0 1 2 3 4 5; do
    if [ -f "/sys/class/thermal/thermal_zone${i}/temp" ]; then
      local t=$(cat /sys/class/thermal/thermal_zone${i}/temp 2>/dev/null || echo "0")
      if [ "$t" -gt 0 ] && [ "$t" -lt 150000 ]; then
        temp=$t
        break
      fi
    fi
  done
  echo $temp
}

# ============================================================
# THERMAL PROTECTION
# Jika suhu >= THERMAL_CRITICAL -> paksa idle governor
# Jika suhu >= THERMAL_WARNING  -> log warning saja
# Jika suhu kembali normal, resume governor sebelumnya
# ============================================================
check_thermal() {
  local temp=$(get_temperature)
  if [ "$temp" -ge "$THERMAL_CRITICAL" ] 2>/dev/null; then
    if [ "$THERMAL_TRIGGERED" -eq 0 ]; then
      log "🌡️  CRITICAL TEMP: ${temp} mC → forcing idle governor"
      restore_governor_config "$DEFAULT_GOVERNOR"
      THERMAL_TRIGGERED=1
    fi
    return 1
  elif [ "$temp" -ge "$THERMAL_WARNING" ] 2>/dev/null; then
    log "⚠️  WARNING TEMP: ${temp} mC"
    return 1
  else
    if [ "$THERMAL_TRIGGERED" -eq 1 ]; then
      log "🌡️  Temp normal (${temp} mC) → resuming adaptive mode"
      THERMAL_TRIGGERED=0
    fi
    return 0
  fi
}

start_http_server() {
  killall httpd 2>/dev/null
  sleep 1
  ln -sf "$LOG" "$WEBROOT/log.txt" 2>/dev/null
  chmod 666 "$WEBROOT/log.txt" 2>/dev/null
  command -v httpd >/dev/null 2>&1 && httpd -p 127.0.0.1:$HTTP_PORT -h "$WEBROOT" 2>/dev/null &
}

monitor_loop() {
  local current_state="idle"
  local last_foreground=""
  local last_applied_governor=""
  local game_counter=0
  local idle_counter=0
  local app_counter=0

  apply_powersave

  while true; do
    foreground=$(get_foreground_app)

    if [ "$foreground" != "$last_foreground" ] && [ -n "$foreground" ]; then
      last_foreground="$foreground"
      log "📱 Foreground app: $foreground"
      game_counter=0
      idle_counter=0
      app_counter=0
    fi

    # Skip governor switching if thermal protection active
    if ! check_thermal; then
      generate_dynamic_json "$foreground" "thermal_throttle"
      sleep 2
      continue
    fi

    app_custom_gov=""
    has_custom_gov=1
    if [ -n "$foreground" ]; then
      app_custom_gov=$(get_app_governor "$foreground" 2>/dev/null)
      has_custom_gov=$?
    fi

    local target_state="idle"
    local should_apply_governor=0
    local target_governor=""

    # Priority 1: Per-app custom governor
    if [ $has_custom_gov -eq 0 ] && [ -n "$app_custom_gov" ]; then
      target_state="gaming"
      target_governor="$app_custom_gov"
      app_counter=$((app_counter + 1))
      game_counter=0
      idle_counter=0
      [ $app_counter -ge 2 ] && should_apply_governor=1

    else
      is_game_running=0
      [ -n "$foreground" ] && is_game "$foreground" && is_game_running=1

      if [ $is_game_running -eq 1 ]; then
        target_state="gaming"
        target_governor="$GAMING_GOVERNOR"
        game_counter=$((game_counter + 1))
        idle_counter=0
        app_counter=0
        [ $game_counter -ge 3 ] && should_apply_governor=1
      else
        target_state="idle"
        target_governor="$DEFAULT_GOVERNOR"
        idle_counter=$((idle_counter + 1))
        game_counter=0
        app_counter=0
        [ $idle_counter -ge 3 ] && should_apply_governor=1
      fi
    fi

    if [ $should_apply_governor -eq 1 ]; then
      # Only apply if state or governor actually changed
      if [ "$current_state" != "$target_state" ] || [ "$last_applied_governor" != "$target_governor" ]; then
        case "$target_state" in
          "gaming")
            if [ $has_custom_gov -eq 0 ] && [ -n "$app_custom_gov" ]; then
              apply_app_governor "$target_governor"
            else
              apply_performance
              target_governor="$GAMING_GOVERNOR"
            fi
            ;;
          "idle")
            apply_powersave
            target_governor="$DEFAULT_GOVERNOR"
            ;;
        esac
        current_state="$target_state"
        last_applied_governor="$target_governor"
      fi
    fi

    generate_dynamic_json "$foreground" "$target_state"
    sleep 1
  done
}

log "Generating initial JSONs..."
generate_static_json &
generate_config_json &
generate_games_json &
generate_app_governors_json &
generate_dynamic_json "unknown" "idle" &
wait

log "Starting HTTP server on port $HTTP_PORT..."
start_http_server

log "Starting API server on port $API_PORT..."
start_api_server &

log "✅ MODULE FULLY INITIALIZED!"
log "📊 Dashboard: http://127.0.0.1:$HTTP_PORT"
log "🔄 API Server: http://127.0.0.1:$API_PORT"
log "💤 Idle: $DEFAULT_GOVERNOR | 🎮 Gaming: $GAMING_GOVERNOR"
log "🌡️  Thermal warning: $((THERMAL_WARNING/1000))°C | Critical: $((THERMAL_CRITICAL/1000))°C"
log "================================================"

monitor_loop
