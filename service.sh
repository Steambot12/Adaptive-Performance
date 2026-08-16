#!/system/bin/sh
# Adaptive Performance v1.3

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

THERMAL_WARNING=65000
THERMAL_CRITICAL=75000
THERMAL_TRIGGERED=0

DEFAULT_GOVERNOR="schedutil"
GAMING_GOVERNOR="schedutil"

# ============================================================
# LOGGING
# ============================================================
log() {
  if [ -f "$LOG" ] && [ $(wc -c < "$LOG" 2>/dev/null || echo 0) -gt $LOG_MAX_SIZE ]; then
    tail -200 "$LOG" > "${LOG}.tmp" 2>/dev/null && mv -f "${LOG}.tmp" "$LOG"
  fi
  echo "[$(date '+%H:%M:%S')] $1" >> "$LOG" 2>&1
}

while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 1
done

log "================================================"
log "Adaptive Performance v1.3"
log "================================================"

mkdir -p "$WEBROOT" 2>/dev/null
chmod 777 "$WEBROOT" 2>/dev/null
mkdir -p "$STOCK_CONFIG_DIR" 2>/dev/null
chmod 755 "$STOCK_CONFIG_DIR" 2>/dev/null

[ ! -f "$APP_GOVERNORS" ] && touch "$APP_GOVERNORS"
chmod 666 "$APP_GOVERNORS" 2>/dev/null

if [ -s "$APP_GOVERNORS" ]; then
  log "Per-App Governors loaded:"
  while IFS='=' read -r pkg gov; do
    [ -z "$pkg" ] && continue
    pkg=$(echo "$pkg" | tr -d ' \r\n\t')
    gov=$(echo "$gov" | tr -d ' \r\n\t')
    log "  $pkg -> $gov"
  done < "$APP_GOVERNORS"
fi

if [ ! -f "$GAME_PACKAGES" ]; then
  cat > "$GAME_PACKAGES" << 'EOF'
com.miHoYo.GenshinImpact
com.HoYoverse.hkrpgoversea
com.activision.callofduty.shooter
com.mobile.legends
com.garena.game.df
com.garena.game.fcthai
com.proxima.dfm
com.YoStarEN.Kuro.WutheringWaves
com.tencent.ig
com.pubg.krmobile
com.pubg.imobile
com.supercell.clashofclans
com.supercell.clashroyale
com.riotgames.league.wildrift
com.dts.freefireth
com.dts.freefiremax
com.levelinfinite.hotta.gp
EOF
fi
chmod 666 "$GAME_PACKAGES" 2>/dev/null

# ============================================================
# HARDWARE DETECTION
# ============================================================
get_num_cores() {
  ls -d ${CPU_BASE}/cpu[0-9]* 2>/dev/null | wc -l
}
NUM_CORES=$(get_num_cores)
[ -z "$NUM_CORES" ] || [ "$NUM_CORES" -eq 0 ] && NUM_CORES=4

detect_chipset() {
  local platform=$(getprop ro.board.platform 2>/dev/null)
  local hardware=$(getprop ro.hardware 2>/dev/null)
  local soc=$(getprop ro.soc.model 2>/dev/null)
  local combined="$platform$hardware$soc"
  if echo "$combined" | grep -qiE "mt[0-9]+|mediatek|dimensity"; then
    echo "mediatek"
  elif echo "$combined" | grep -qiE "exynos|samsung|universal[0-9]|s5e"; then
    echo "exynos"
  elif echo "$combined" | grep -qiE "unisoc|spreadtrum|ums[0-9]|sc[0-9]"; then
    echo "unisoc"
  elif echo "$combined" | grep -qiE "tensor|gs[0-9]|zuma|whitechapel"; then
    echo "tensor"
  else
    echo "snapdragon"
  fi
}
CHIPSET=$(detect_chipset)

AVAILABLE_GOVERNORS=$(cat ${CPU_BASE}/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
[ -z "$AVAILABLE_GOVERNORS" ] && AVAILABLE_GOVERNORS="schedutil ondemand performance"

log "Chipset: $CHIPSET | Cores: $NUM_CORES"
log "Available governors: $AVAILABLE_GOVERNORS"

# ============================================================
# GOVERNOR BACKUP & RESTORE
# ============================================================
backup_initial_config() {
  log "Backing up initial kernel config..."
  local cpu0="${CPU_BASE}/cpu0/cpufreq"
  local current_gov=$(cat "$cpu0/scaling_governor" 2>/dev/null)
  [ -n "$current_gov" ] && echo "$current_gov" > "$STOCK_CONFIG_DIR/stock_governor.txt"
  cat "$cpu0/scaling_min_freq" 2>/dev/null > "$STOCK_CONFIG_DIR/scaling_min_freq.txt"
  cat "$cpu0/scaling_max_freq" 2>/dev/null > "$STOCK_CONFIG_DIR/scaling_max_freq.txt"
  [ -n "$current_gov" ] && backup_governor_tunables "$current_gov"
  log "Backup done. Stock governor: $current_gov"
}

backup_governor_tunables() {
  local gov="$1"
  local cpu0="${CPU_BASE}/cpu0/cpufreq"
  local tunable_dir="$cpu0/${gov}"
  [ -f "$STOCK_CONFIG_DIR/$gov/.backup_done" ] && return 0
  [ ! -d "$tunable_dir" ] && return 1
  mkdir -p "$STOCK_CONFIG_DIR/$gov" 2>/dev/null
  local count=0
  for tunable in $(ls "$tunable_dir" 2>/dev/null); do
    local file="$tunable_dir/$tunable"
    if [ -f "$file" ] && [ -r "$file" ]; then
      cat "$file" 2>/dev/null > "$STOCK_CONFIG_DIR/$gov/$tunable"
      count=$((count + 1))
    fi
  done
  touch "$STOCK_CONFIG_DIR/$gov/.backup_done"
  log "  Backed up $count tunables for $gov"
}

restore_governor_config() {
  local target_gov="$1"
  [ -z "$target_gov" ] && return 1
  local cpu0="${CPU_BASE}/cpu0/cpufreq"
  log "Switching to: $target_gov"
  [ -f "$STOCK_CONFIG_DIR/scaling_min_freq.txt" ] && \
    cat "$STOCK_CONFIG_DIR/scaling_min_freq.txt" > "$cpu0/scaling_min_freq" 2>/dev/null
  [ -f "$STOCK_CONFIG_DIR/scaling_max_freq.txt" ] && \
    cat "$STOCK_CONFIG_DIR/scaling_max_freq.txt" > "$cpu0/scaling_max_freq" 2>/dev/null
  echo "$target_gov" > "$cpu0/scaling_governor" 2>/dev/null
  backup_governor_tunables "$target_gov"
  local tunable_backup="$STOCK_CONFIG_DIR/$target_gov"
  local tunable_dir="$cpu0/${target_gov}"
  if [ -d "$tunable_backup" ] && [ -f "$tunable_backup/.backup_done" ] && [ -d "$tunable_dir" ]; then
    for tf in $(ls "$tunable_backup" 2>/dev/null); do
      [ "$tf" = ".backup_done" ] && continue
      local tgt="$tunable_dir/$tf"
      local src="$tunable_backup/$tf"
      [ -f "$tgt" ] && [ -w "$tgt" ] && [ -f "$src" ] && cat "$src" > "$tgt" 2>/dev/null
    done
  fi
  local max_cpu=$((NUM_CORES - 1))
  local i=1
  while [ $i -le $max_cpu ]; do
    local cpu_dir="${CPU_BASE}/cpu${i}/cpufreq"
    if [ -d "$cpu_dir" ]; then
      echo "$target_gov" > "$cpu_dir/scaling_governor" 2>/dev/null
      [ -f "$STOCK_CONFIG_DIR/scaling_min_freq.txt" ] && \
        cat "$STOCK_CONFIG_DIR/scaling_min_freq.txt" > "$cpu_dir/scaling_min_freq" 2>/dev/null
      [ -f "$STOCK_CONFIG_DIR/scaling_max_freq.txt" ] && \
        cat "$STOCK_CONFIG_DIR/scaling_max_freq.txt" > "$cpu_dir/scaling_max_freq" 2>/dev/null
    fi
    i=$((i + 1))
  done
  log "Done: $target_gov applied to all cores"
}

# ============================================================
# GOVERNOR DETECTION
# ============================================================
detect_default_governor() {
  if [ -f "$DEFAULT_GOV_FILE" ]; then
    local saved=$(cat "$DEFAULT_GOV_FILE" 2>/dev/null | head -1 | tr -d ' \r\n\t')
    if [ -n "$saved" ] && echo "$AVAILABLE_GOVERNORS" | grep -q "$saved" && [ "$saved" != "performance" ]; then
      echo "$saved"; return
    fi
  fi
  if [ -f "$STOCK_CONFIG_DIR/stock_governor.txt" ]; then
    local stock=$(cat "$STOCK_CONFIG_DIR/stock_governor.txt" 2>/dev/null | tr -d ' \r\n\t')
    [ -n "$stock" ] && [ "$stock" != "performance" ] && echo "$stock" && return
  fi
  if [ "$CHIPSET" = "mediatek" ]; then
    for g in sugov_ext blu_schedutil schedutil walt interactive ondemand; do
      echo "$AVAILABLE_GOVERNORS" | grep -q "$g" && echo "$g" && return
    done
  else
    for g in walt blu_schedutil schedutil interactive ondemand; do
      echo "$AVAILABLE_GOVERNORS" | grep -q "$g" && echo "$g" && return
    done
  fi
  for g in $AVAILABLE_GOVERNORS; do
    [ "$g" != "performance" ] && echo "$g" && return
  done
  echo "schedutil"
}

detect_gaming_governor() {
  if [ "$CHIPSET" = "mediatek" ]; then
    for g in schedhorizon blu_schedutil schedutil performance; do
      echo "$AVAILABLE_GOVERNORS" | grep -q "$g" && echo "$g" && return
    done
  else
    for g in vorpal blu_schedutil schedutil performance; do
      echo "$AVAILABLE_GOVERNORS" | grep -q "$g" && echo "$g" && return
    done
  fi
  echo "$(echo "$AVAILABLE_GOVERNORS" | awk '{print $1}')"
}

load_gaming_governor() {
  if [ -f "$GOVERNOR_PREF" ]; then
    local pref=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d ' \r\n\t')
    if [ -n "$pref" ] && echo "$AVAILABLE_GOVERNORS" | grep -q "$pref"; then
      echo "$pref"; return
    fi
  fi
  local def=$(detect_gaming_governor)
  echo "$def" > "$GOVERNOR_PREF" 2>/dev/null
  chmod 666 "$GOVERNOR_PREF" 2>/dev/null
  echo "$def"
}

# ============================================================
# FOREGROUND APP
# ============================================================
get_foreground_app() {
  local fg
  fg=$(dumpsys window 2>/dev/null | grep -i "mCurrentFocus" | grep -oE '[a-z][a-z0-9_.]*\.[a-zA-Z0-9_.]+' | head -1)
  [ -z "$fg" ] && fg=$(dumpsys activity activities 2>/dev/null | grep "mResumedActivity" | grep -oE '[a-z][a-z0-9_.]*\.[a-zA-Z0-9_.]+' | head -1)
  echo "$fg"
}

# ============================================================
# PER-APP GOVERNOR
# ============================================================
get_app_governor() {
  local app="$1"
  [ -z "$app" ] || [ ! -f "$APP_GOVERNORS" ] && return 1
  while IFS='=' read -r pkg gov; do
    [ -z "$pkg" ] && continue
    pkg=$(echo "$pkg" | tr -d ' \r\n\t')
    gov=$(echo "$gov" | tr -d ' \r\n\t')
    [ "$app" = "$pkg" ] && echo "$gov" && return 0
  done < "$APP_GOVERNORS"
  return 1
}

set_app_governor() {
  local pkg="$1"
  local gov="$2"
  log "SET PER-APP: $pkg = $gov"
  [ -z "$pkg" ] || [ -z "$gov" ] && return 1
  pkg=$(echo "$pkg" | tr -d ' \r\n\t')
  gov=$(echo "$gov" | tr -d ' \r\n\t')
  echo "$AVAILABLE_GOVERNORS" | grep -q "$gov" || { log "ERROR: Invalid governor: $gov"; return 1; }
  if grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null; then
    log "ERROR: Already in game list: $pkg"; return 1
  fi
  if grep -q "^${pkg}=" "$APP_GOVERNORS" 2>/dev/null; then
    grep -v "^${pkg}=" "$APP_GOVERNORS" > "${APP_GOVERNORS}.tmp" 2>/dev/null
    mv -f "${APP_GOVERNORS}.tmp" "$APP_GOVERNORS"
  fi
  echo "${pkg}=${gov}" >> "$APP_GOVERNORS"
  chmod 666 "$APP_GOVERNORS" 2>/dev/null
  sync
  log "OK: $pkg -> $gov"
  generate_app_governors_json
  return 0
}

remove_app_governor() {
  local pkg="$1"
  [ -z "$pkg" ] && return 1
  pkg=$(echo "$pkg" | tr -d ' \r\n\t')
  log "REMOVE PER-APP: $pkg"
  [ ! -f "$APP_GOVERNORS" ] && touch "$APP_GOVERNORS" && chmod 666 "$APP_GOVERNORS" 2>/dev/null
  if grep -q "^${pkg}=" "$APP_GOVERNORS" 2>/dev/null; then
    grep -v "^${pkg}=" "$APP_GOVERNORS" > "${APP_GOVERNORS}.tmp" 2>/dev/null
    mv -f "${APP_GOVERNORS}.tmp" "$APP_GOVERNORS"
    chmod 666 "$APP_GOVERNORS" 2>/dev/null
    sync
    log "OK: $pkg removed"
  else
    log "INFO: $pkg not found in file"
  fi
  generate_app_governors_json
  local fg=$(get_foreground_app)
  if [ "$fg" = "$pkg" ]; then
    log "Active app removed - resetting to idle governor"
    restore_governor_config "$DEFAULT_GOVERNOR"
  fi
  return 0
}

generate_app_governors_json() {
  local arr=""
  local cnt=0
  if [ -f "$APP_GOVERNORS" ] && [ -s "$APP_GOVERNORS" ]; then
    while IFS='=' read -r pkg gov; do
      [ -z "$pkg" ] && continue
      pkg=$(echo "$pkg" | tr -d ' \r\n\t')
      gov=$(echo "$gov" | tr -d ' \r\n\t')
      [ -z "$pkg" ] || [ -z "$gov" ] && continue
      [ $cnt -gt 0 ] && arr="$arr,"
      arr="$arr{\"package\":\"$pkg\",\"governor\":\"$gov\"}"
      cnt=$((cnt + 1))
    done < "$APP_GOVERNORS"
  fi
  local ts=$(date +%s)000
  printf '{"status":"success","app_governors":[%s],"count":%d,"timestamp":%s}\n' \
    "$arr" "$cnt" "$ts" > "$JSON_APP_GOVS"
  chmod 666 "$JSON_APP_GOVS" 2>/dev/null
}

# ============================================================
# PACKAGE MANAGEMENT
# ============================================================
add_package() {
  local pkg="$1"
  [ -z "$pkg" ] && return 1
  pkg=$(echo "$pkg" | tr -d ' \r\n\t')
  echo "$pkg" | grep -Eq '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$' || {
    log "ERROR: Invalid package: $pkg"; return 1
  }
  if grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null; then
    log "WARN: Duplicate: $pkg"; return 1
  fi
  if [ -f "$APP_GOVERNORS" ] && grep -q "^${pkg}=" "$APP_GOVERNORS" 2>/dev/null; then
    log "ERROR: Conflict with per-app: $pkg"; return 1
  fi
  echo "$pkg" >> "$GAME_PACKAGES"
  chmod 666 "$GAME_PACKAGES" 2>/dev/null
  sync
  log "ADDED: $pkg"
  generate_games_json
  return 0
}

remove_package() {
  local pkg="$1"
  [ -z "$pkg" ] && return 1
  pkg=$(echo "$pkg" | tr -d ' \r\n\t')
  if ! grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null; then
    generate_games_json; return 0
  fi
  grep -Fxv "$pkg" "$GAME_PACKAGES" > "${GAME_PACKAGES}.tmp" 2>/dev/null
  mv -f "${GAME_PACKAGES}.tmp" "$GAME_PACKAGES"
  chmod 666 "$GAME_PACKAGES" 2>/dev/null
  sync
  log "REMOVED: $pkg"
  generate_games_json
  local fg=$(get_foreground_app)
  if [ "$fg" = "$pkg" ]; then
    restore_governor_config "$DEFAULT_GOVERNOR"
  fi
  return 0
}

set_gaming_governor() {
  local gov="$1"
  [ -z "$gov" ] && return 1
  gov=$(echo "$gov" | tr -d ' \r\n\t')
  echo "$AVAILABLE_GOVERNORS" | grep -q "$gov" || { log "ERROR: Governor not available: $gov"; return 1; }
  echo "$gov" > "$GOVERNOR_PREF"
  chmod 666 "$GOVERNOR_PREF" 2>/dev/null
  sync
  GAMING_GOVERNOR="$gov"
  log "Gaming governor set: $gov"
  generate_config_json
  local fg=$(get_foreground_app)
  if [ -n "$fg" ] && is_game "$fg"; then
    log "Game active, apply immediately: $gov"
    restore_governor_config "$gov"
  fi
  return 0
}

# ============================================================
# JSON GENERATORS
# ============================================================
generate_static_json() {
  local device=$(getprop ro.product.model 2>/dev/null || echo "Unknown")
  local kernel=$(uname -r 2>/dev/null || echo "Unknown")
  printf '{"cores":%d,"kernel":"%s","device":"%s","default_governor":"%s","chipset":"%s"}' \
    "$NUM_CORES" "$kernel" "$device" "$DEFAULT_GOVERNOR" "$CHIPSET" > "$JSON_STATIC"
  chmod 666 "$JSON_STATIC" 2>/dev/null
  log "static.json OK: device=$device cores=$NUM_CORES"
}

generate_config_json() {
  local gaming_gov
  gaming_gov=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d ' \r\n\t')
  [ -z "$gaming_gov" ] && gaming_gov="$GAMING_GOVERNOR"
  local gov_opts=""
  local cnt=0
  for g in $AVAILABLE_GOVERNORS; do
    [ $cnt -eq 0 ] && gov_opts="\"$g\"" || gov_opts="$gov_opts,\"$g\""
    cnt=$((cnt + 1))
  done
  printf '{"chipset":"%s","default_idle":"%s","gaming_governor":"%s","available_governors":[%s],"all_governors":"%s"}' \
    "$CHIPSET" "$DEFAULT_GOVERNOR" "$gaming_gov" "$gov_opts" "$AVAILABLE_GOVERNORS" > "$JSON_CONFIG"
  chmod 666 "$JSON_CONFIG" 2>/dev/null
  log "config.json OK: idle=$DEFAULT_GOVERNOR gaming=$gaming_gov"
}

generate_games_json() {
  local arr=""
  local cnt=0
  if [ -f "$GAME_PACKAGES" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      line=$(echo "$line" | tr -d ' \r\n\t')
      [ -z "$line" ] && continue
      [ $cnt -gt 0 ] && arr="$arr,"
      arr="$arr\"$line\""
      cnt=$((cnt + 1))
    done < "$GAME_PACKAGES"
  fi
  local ts=$(date +%s)000
  printf '{"status":"success","games":[%s],"count":%d,"timestamp":%s}' \
    "$arr" "$cnt" "$ts" > "$JSON_GAMES"
  chmod 666 "$JSON_GAMES" 2>/dev/null
}

get_temperature() {
  local temp=0
  local i=0
  while [ $i -le 9 ]; do
    local f="/sys/class/thermal/thermal_zone${i}/temp"
    if [ -f "$f" ]; then
      local t=$(cat "$f" 2>/dev/null || echo 0)
      if [ "$t" -gt 1000 ] && [ "$t" -lt 200000 ] 2>/dev/null; then
        temp=$t; break
      fi
    fi
    i=$((i + 1))
  done
  echo $temp
}

generate_dynamic_json() {
  local foreground="$1"
  local state="$2"
  [ -z "$foreground" ] && foreground="unknown"
  [ -z "$state" ] && state="idle"
  local governor=$(cat "${CPU_BASE}/cpu0/cpufreq/scaling_governor" 2>/dev/null || echo "unknown")
  local temp=$(get_temperature)
  local freqs=""
  local max_show=3
  [ $NUM_CORES -lt 4 ] && max_show=$((NUM_CORES - 1))
  for cpu in $(seq 0 $max_show); do
    local freq=$(cat "${CPU_BASE}/cpu${cpu}/cpufreq/scaling_cur_freq" 2>/dev/null || echo 0)
    [ $cpu -eq 0 ] && freqs="$freq" || freqs="$freqs,$freq"
  done
  printf '{"governor":"%s","foreground":"%s","temperature":%d,"frequencies":[%s],"state":"%s","timestamp":%d}' \
    "$governor" "$foreground" "$temp" "$freqs" "$state" "$(date +%s)" > "$JSON_DYNAMIC"
  chmod 666 "$JSON_DYNAMIC" 2>/dev/null
}

# ============================================================
# THERMAL PROTECTION
# ============================================================
check_thermal() {
  local temp=$(get_temperature)
  if [ "$temp" -ge "$THERMAL_CRITICAL" ] 2>/dev/null; then
    [ "$THERMAL_TRIGGERED" -eq 0 ] && {
      log "THERMAL CRITICAL: ${temp}mC - forcing idle governor"
      restore_governor_config "$DEFAULT_GOVERNOR"
      THERMAL_TRIGGERED=1
    }
    return 1
  elif [ "$temp" -ge "$THERMAL_WARNING" ] 2>/dev/null; then
    [ "$THERMAL_TRIGGERED" -eq 0 ] && log "THERMAL WARNING: ${temp}mC"
    return 1
  else
    [ "$THERMAL_TRIGGERED" -eq 1 ] && { log "THERMAL OK: ${temp}mC"; THERMAL_TRIGGERED=0; }
    return 0
  fi
}

# ============================================================
# GAME CHECK
# ============================================================
is_game() {
  local app="$1"
  [ -z "$app" ] || [ ! -f "$GAME_PACKAGES" ] && return 1
  while IFS= read -r pkg || [ -n "$pkg" ]; do
    case "$pkg" in ''|'#'*) continue ;; esac
    pkg=$(echo "$pkg" | tr -d ' \r\n\t')
    [ "$app" = "$pkg" ] && return 0
  done < "$GAME_PACKAGES"
  return 1
}

# ============================================================
# APPLY HELPERS
# ============================================================
apply_performance() {
  local new_gov=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d ' \r\n\t')
  if [ -n "$new_gov" ] && echo "$AVAILABLE_GOVERNORS" | grep -q "$new_gov"; then
    GAMING_GOVERNOR="$new_gov"
  fi
  restore_governor_config "$GAMING_GOVERNOR"
  log "MODE: GAMING ($GAMING_GOVERNOR)"
}

apply_powersave() {
  restore_governor_config "$DEFAULT_GOVERNOR"
  log "MODE: IDLE ($DEFAULT_GOVERNOR)"
}

apply_app_governor() {
  local gov="$1"
  restore_governor_config "$gov"
  log "MODE: PER-APP ($gov)"
}

# ============================================================
# HTTP SERVER
# ============================================================
start_http_server() {
  # Kill any stale instances
  for pid in $(pgrep -f "httpd.*$HTTP_PORT" 2>/dev/null); do kill "$pid" 2>/dev/null; done
  sleep 1
  ln -sf "$LOG" "$WEBROOT/log.txt" 2>/dev/null
  chmod 666 "$WEBROOT/log.txt" 2>/dev/null
  if command -v httpd >/dev/null 2>&1; then
    httpd -p 127.0.0.1:$HTTP_PORT -h "$WEBROOT" 2>/dev/null &
    log "HTTP server started :$HTTP_PORT"
  else
    log "WARN: httpd not found"
  fi
}

# ============================================================
# API SERVER
# Fix #3: Only log when ACTION is non-empty (real request).
# Idle nc connections (browser preflight/empty) are silently ignored.
# ============================================================
start_api_server() {
  log "API server started :$API_PORT"

  while true; do
    # Read request from nc
    REQUEST=$(echo "" | nc -l -p $API_PORT 2>/dev/null | head -10)
    GET_LINE=$(echo "$REQUEST" | head -1)
    QUERY=$(echo "$GET_LINE" | grep -oE '\?[^ ]+' | cut -c2-)

    ACTION=""
    PKG=""
    GOVERNOR=""

    if [ -n "$QUERY" ]; then
      for param in $(echo "$QUERY" | tr '&' '\n'); do
        KEY=$(echo "$param" | cut -d= -f1)
        VAL=$(echo "$param" | cut -d= -f2- | sed 's/%2[Ee]/./g; s/%20/ /g; s/+/ /g; s/%5[Ff]/_/g; s/%2[Dd]/-/g' 2>/dev/null)
        case "$KEY" in
          action)   ACTION="$VAL" ;;
          pkg)      PKG="$VAL" ;;
          governor) GOVERNOR="$VAL" ;;
        esac
      done
    fi

    # Skip empty/non-action requests silently (no log spam)
    if [ -z "$ACTION" ]; then
      sleep 0.1
      continue
    fi

    RESPONSE=""
    case "$ACTION" in
      add)
        [ -z "$PKG" ] && RESPONSE='{"status":"error","message":"Missing pkg"}' || {
          add_package "$PKG" \
            && RESPONSE='{"status":"success","message":"Added","package":"'"$PKG"'"}' \
            || RESPONSE='{"status":"error","message":"Failed or duplicate"}'
        }
        ;;
      remove)
        [ -z "$PKG" ] && RESPONSE='{"status":"error","message":"Missing pkg"}' || {
          remove_package "$PKG" \
            && RESPONSE='{"status":"success","message":"Removed","package":"'"$PKG"'"}' \
            || RESPONSE='{"status":"error","message":"Failed"}'
        }
        ;;
      set_governor)
        [ -z "$GOVERNOR" ] && RESPONSE='{"status":"error","message":"Missing governor"}' || {
          set_gaming_governor "$GOVERNOR" \
            && RESPONSE='{"status":"success","message":"Governor set","governor":"'"$GOVERNOR"'"}' \
            || RESPONSE='{"status":"error","message":"Governor unavailable"}'
        }
        ;;
      set_app_governor)
        { [ -z "$PKG" ] || [ -z "$GOVERNOR" ]; } && RESPONSE='{"status":"error","message":"Missing pkg or governor"}' || {
          set_app_governor "$PKG" "$GOVERNOR" \
            && RESPONSE='{"status":"success","message":"App governor set","package":"'"$PKG"'","governor":"'"$GOVERNOR"'"}' \
            || RESPONSE='{"status":"error","message":"Failed or conflict"}'
        }
        ;;
      remove_app_governor)
        [ -z "$PKG" ] && RESPONSE='{"status":"error","message":"Missing pkg"}' || {
          remove_app_governor "$PKG" \
            && RESPONSE='{"status":"success","message":"App governor removed","package":"'"$PKG"'"}' \
            || RESPONSE='{"status":"error","message":"Failed"}'
        }
        ;;
      get_status)
        local cg=$(cat "${CPU_BASE}/cpu0/cpufreq/scaling_governor" 2>/dev/null || echo unknown)
        local ct=$(get_temperature)
        RESPONSE='{"status":"success","governor":"'"$cg"'","default":"'"$DEFAULT_GOVERNOR"'","gaming":"'"$GAMING_GOVERNOR"'","temperature":'"$ct"'}'
        ;;
      *)
        RESPONSE='{"status":"error","message":"Invalid action"}'
        ;;
    esac

    log "API: action=$ACTION pkg=$PKG gov=$GOVERNOR"

    # Send response — client polls via dashboard so fire-and-forget is fine
    printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n%s' \
      "${#RESPONSE}" "$RESPONSE" | nc -l -p $API_PORT -w 2 >/dev/null 2>&1 &

    sleep 0.2
  done
}

# ============================================================
# MONITOR LOOP
# ============================================================
monitor_loop() {
  local current_state="idle"
  local last_foreground=""
  local last_applied_governor=""
  local game_counter=0
  local idle_counter=0
  local app_counter=0

  apply_powersave

  while true; do
    local foreground=$(get_foreground_app)

    if [ -n "$foreground" ] && [ "$foreground" != "$last_foreground" ]; then
      last_foreground="$foreground"
      log "Foreground: $foreground"
      game_counter=0; idle_counter=0; app_counter=0
    fi

    if ! check_thermal; then
      current_state="thermal_throttle"
      last_applied_governor=""
      generate_dynamic_json "$foreground" "thermal_throttle"
      sleep 2; continue
    fi

    local fg_gov=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d ' \r\n\t')
    [ -n "$fg_gov" ] && echo "$AVAILABLE_GOVERNORS" | grep -q "$fg_gov" && GAMING_GOVERNOR="$fg_gov"

    local target_state="idle"
    local target_governor="$DEFAULT_GOVERNOR"
    local should_apply=0

    local app_custom_gov
    app_custom_gov=$(get_app_governor "$foreground" 2>/dev/null)
    local has_custom=$?

    if [ $has_custom -eq 0 ] && [ -n "$app_custom_gov" ]; then
      target_state="custom"
      target_governor="$app_custom_gov"
      app_counter=$((app_counter + 1)); game_counter=0; idle_counter=0
      [ $app_counter -ge 2 ] && should_apply=1
    elif [ -n "$foreground" ] && is_game "$foreground"; then
      target_state="gaming"
      target_governor="$GAMING_GOVERNOR"
      game_counter=$((game_counter + 1)); idle_counter=0; app_counter=0
      [ $game_counter -ge 3 ] && should_apply=1
    else
      target_state="idle"
      target_governor="$DEFAULT_GOVERNOR"
      idle_counter=$((idle_counter + 1)); game_counter=0; app_counter=0
      [ $idle_counter -ge 3 ] && should_apply=1
    fi

    if [ $should_apply -eq 1 ]; then
      if [ "$current_state" != "$target_state" ] || [ "$last_applied_governor" != "$target_governor" ]; then
        case "$target_state" in
          gaming)
            apply_performance
            target_governor="$GAMING_GOVERNOR"
            ;;
          custom)
            apply_app_governor "$target_governor"
            ;;
          idle) apply_powersave ;;
        esac
        current_state="$target_state"
        last_applied_governor="$target_governor"
      fi
    fi

    generate_dynamic_json "$foreground" "$current_state"
    sleep 1
  done
}

# ============================================================
# STARTUP
# ============================================================
log "=== Hardware Detection ==="
backup_initial_config
DEFAULT_GOVERNOR=$(detect_default_governor)
GAMING_GOVERNOR=$(load_gaming_governor)
log "Idle governor  : $DEFAULT_GOVERNOR"
log "Gaming governor: $GAMING_GOVERNOR"
log "Thermal: warn=${THERMAL_WARNING}mC crit=${THERMAL_CRITICAL}mC"

log "=== Generating JSON ==="
generate_static_json
generate_config_json
generate_games_json
generate_app_governors_json
generate_dynamic_json "unknown" "idle"

log "=== Starting Servers ==="
start_http_server
sleep 2
start_api_server &

log "=== MODULE READY v1.3 ==="
log "Dashboard : http://127.0.0.1:$HTTP_PORT"
log "API Server: http://127.0.0.1:$API_PORT"
log "================================================"

monitor_loop
