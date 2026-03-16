#!/system/bin/sh
# Adaptive Performance v1.2 - Stable

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
log "Adaptive Performance v1.2 - Stable"
log "================================================"

mkdir -p "$WEBROOT" 2>/dev/null
chmod 777 "$WEBROOT" 2>/dev/null
mkdir -p "$STOCK_CONFIG_DIR" 2>/dev/null
chmod 755 "$STOCK_CONFIG_DIR" 2>/dev/null

if [ ! -f "$GAME_PACKAGES" ]; then
  cat > "$GAME_PACKAGES" << 'EOF'
com.miHoYo.GenshinImpact
com.activision.callofduty.shooter
com.mobile.legends
com.garena.game.df
com.proxima.dfm
com.YoStarEN.Kuro.WutheringWaves
com.tencent.ig
com.pubg.krmobile
EOF
fi
chmod 666 "$GAME_PACKAGES" 2>/dev/null

if [ ! -f "$APP_GOVERNORS" ]; then
  touch "$APP_GOVERNORS"
fi
chmod 666 "$APP_GOVERNORS" 2>/dev/null

if [ -s "$APP_GOVERNORS" ]; then
  log "Per-App Governors loaded:"
  while IFS='=' read -r pkg gov; do
    [ -z "$pkg" ] && continue
    pkg=$(echo "$pkg" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    gov=$(echo "$gov" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    log "  $pkg -> $gov"
  done < "$APP_GOVERNORS"
else
  log "No per-app governors configured"
fi

# ============================================================
# HARDWARE DETECTION
# ============================================================
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
log "Chipset: $CHIPSET | Cores: $NUM_CORES"

AVAILABLE_GOVERNORS=$(cat ${CPU_BASE}/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
log "Available governors: $AVAILABLE_GOVERNORS"

# ============================================================
# GOVERNOR BACKUP & RESTORE
# ============================================================
backup_initial_config() {
  log "Backing up initial kernel config..."
  local cpu0="${CPU_BASE}/cpu0/cpufreq"
  local current_gov=$(cat "$cpu0/scaling_governor" 2>/dev/null)
  echo "$current_gov" > "$STOCK_CONFIG_DIR/stock_governor.txt"
  cat "$cpu0/scaling_min_freq" 2>/dev/null > "$STOCK_CONFIG_DIR/scaling_min_freq.txt"
  cat "$cpu0/scaling_max_freq" 2>/dev/null > "$STOCK_CONFIG_DIR/scaling_max_freq.txt"
  backup_governor_tunables "$current_gov"
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
  return 0
}

restore_governor_config() {
  local target_gov="$1"
  local max_cpu=$((NUM_CORES - 1))
  log "Switching governor: $target_gov (cores: 0-$max_cpu)"
  for cpu in $(seq 0 $max_cpu); do
    local cpu_dir="${CPU_BASE}/cpu${cpu}/cpufreq"
    [ -d "$cpu_dir" ] || continue
    if [ -f "$STOCK_CONFIG_DIR/scaling_min_freq.txt" ]; then
      cat "$STOCK_CONFIG_DIR/scaling_min_freq.txt" > "$cpu_dir/scaling_min_freq" 2>/dev/null
    fi
    if [ -f "$STOCK_CONFIG_DIR/scaling_max_freq.txt" ]; then
      cat "$STOCK_CONFIG_DIR/scaling_max_freq.txt" > "$cpu_dir/scaling_max_freq" 2>/dev/null
    fi
    echo "$target_gov" > "$cpu_dir/scaling_governor" 2>/dev/null
    local tunable_dir="$cpu_dir/${target_gov}"
    local tunable_backup="$STOCK_CONFIG_DIR/$target_gov"
    if [ -d "$tunable_dir" ] && [ -d "$tunable_backup" ] && [ -f "$tunable_backup/.backup_done" ]; then
      for tunable_file in $(ls "$tunable_backup" 2>/dev/null); do
        [ "$tunable_file" = ".backup_done" ] && continue
        local tgt="$tunable_dir/$tunable_file"
        local src="$tunable_backup/$tunable_file"
        [ -f "$tgt" ] && [ -w "$tgt" ] && [ -f "$src" ] && cat "$src" > "$tgt" 2>/dev/null
      done
    fi
  done
  log "  Done: $target_gov applied to all $NUM_CORES cores"
}

# ============================================================
# GOVERNOR DETECTION
# ============================================================
detect_default_governor() {
  if [ -f "$DEFAULT_GOV_FILE" ]; then
    local saved=$(cat "$DEFAULT_GOV_FILE" 2>/dev/null | head -1 | tr -d '\r\n\t')
    if [ -n "$saved" ] && echo "$AVAILABLE_GOVERNORS" | grep -qw "$saved" && [ "$saved" != "performance" ]; then
      echo "$saved"; return
    fi
  fi
  if [ -f "$STOCK_CONFIG_DIR/stock_governor.txt" ]; then
    local stock=$(cat "$STOCK_CONFIG_DIR/stock_governor.txt" 2>/dev/null)
    if [ -n "$stock" ] && [ "$stock" != "performance" ]; then
      echo "$stock"; return
    fi
  fi
  if [ "$CHIPSET" = "mediatek" ]; then
    for g in sugov_ext schedutil walt interactive ondemand; do
      echo "$AVAILABLE_GOVERNORS" | grep -qw "$g" && { echo "$g"; return; }
    done
  else
    for g in walt schedutil interactive ondemand; do
      echo "$AVAILABLE_GOVERNORS" | grep -qw "$g" && { echo "$g"; return; }
    done
  fi
  for g in $AVAILABLE_GOVERNORS; do
    [ "$g" != "performance" ] && { echo "$g"; return; }
  done
  echo "performance"
}

detect_gaming_governor() {
  if [ "$CHIPSET" = "mediatek" ]; then
    for g in schedhorizon schedutil performance; do
      echo "$AVAILABLE_GOVERNORS" | grep -qw "$g" && { echo "$g"; return; }
    done
  else
    for g in schedutil performance; do
      echo "$AVAILABLE_GOVERNORS" | grep -qw "$g" && { echo "$g"; return; }
    done
  fi
  echo "$(echo "$AVAILABLE_GOVERNORS" | awk '{print $1}')"
}

load_gaming_governor() {
  if [ -f "$GOVERNOR_PREF" ]; then
    local pref=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -n "$pref" ] && echo "$AVAILABLE_GOVERNORS" | grep -qw "$pref"; then
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
    pkg=$(echo "$pkg" | tr -d '\r\n\t ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    gov=$(echo "$gov" | tr -d '\r\n\t ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ "$app" = "$pkg" ] && echo "$gov" && return 0
  done < "$APP_GOVERNORS"
  return 1
}

set_app_governor() {
  local pkg="$1"
  local gov="$2"
  log "SET PER-APP: $pkg = $gov"
  [ -z "$pkg" ] || [ -z "$gov" ] && return 1
  pkg=$(echo "$pkg" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  gov=$(echo "$gov" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if ! echo "$AVAILABLE_GOVERNORS" | grep -qw "$gov"; then
    log "ERROR: Invalid governor: $gov"
    return 1
  fi
  if [ -f "$GAME_PACKAGES" ] && grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null; then
    log "ERROR: Package already in game list: $pkg"
    return 1
  fi
  if grep -q "^${pkg}=" "$APP_GOVERNORS" 2>/dev/null; then
    grep -v "^${pkg}=" "$APP_GOVERNORS" > "${APP_GOVERNORS}.tmp" 2>/dev/null
    mv -f "${APP_GOVERNORS}.tmp" "$APP_GOVERNORS"
  fi
  echo "${pkg}=${gov}" >> "$APP_GOVERNORS"
  chmod 666 "$APP_GOVERNORS" 2>/dev/null
  sync
  log "OK: $pkg -> $gov saved"
  generate_app_governors_json
  return 0
}

remove_app_governor() {
  local pkg="$1"
  [ -z "$pkg" ] && { log "ERROR: empty pkg"; return 1; }
  pkg=$(echo "$pkg" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  log "REMOVE PER-APP: $pkg"
  if [ ! -f "$APP_GOVERNORS" ]; then
    touch "$APP_GOVERNORS"
    chmod 666 "$APP_GOVERNORS" 2>/dev/null
  fi
  if grep -q "^${pkg}=" "$APP_GOVERNORS" 2>/dev/null; then
    grep -v "^${pkg}=" "$APP_GOVERNORS" > "${APP_GOVERNORS}.tmp" 2>/dev/null
    mv -f "${APP_GOVERNORS}.tmp" "$APP_GOVERNORS"
    chmod 666 "$APP_GOVERNORS" 2>/dev/null
    sync
    log "OK: $pkg removed from per-app list"
  else
    log "INFO: $pkg not found in per-app list"
  fi
  generate_app_governors_json
  local current_fg=$(get_foreground_app)
  if [ "$current_fg" = "$pkg" ]; then
    log "App $pkg is foreground, reset governor to: $DEFAULT_GOVERNOR"
    restore_governor_config "$DEFAULT_GOVERNOR"
    generate_dynamic_json "$pkg" "idle"
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
  local ts=$(date +%s)000
  printf '{"status":"success","app_governors":[%s],"count":%d,"timestamp":%s}\n' \
    "$app_govs_array" "$count" "$ts" > "$JSON_APP_GOVS"
  chmod 666 "$JSON_APP_GOVS" 2>/dev/null
}

# ============================================================
# PACKAGE MANAGEMENT
# ============================================================
add_package() {
  local pkg="$1"
  [ -z "$pkg" ] && return 1
  pkg=$(echo "$pkg" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  echo "$pkg" | grep -Eq '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$' || {
    log "ERROR: Invalid package format: $pkg"
    return 1
  }
  if grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null; then
    log "WARN: Duplicate: $pkg"
    generate_games_json
    return 1
  fi
  if [ -f "$APP_GOVERNORS" ] && grep -q "^${pkg}=" "$APP_GOVERNORS" 2>/dev/null; then
    log "ERROR: Conflict with per-app list: $pkg"
    return 1
  fi
  echo "$pkg" >> "$GAME_PACKAGES"
  chmod 666 "$GAME_PACKAGES" 2>/dev/null
  sync
  log "ADDED game package: $pkg"
  generate_games_json
  return 0
}

remove_package() {
  local pkg="$1"
  [ -z "$pkg" ] && return 1
  pkg=$(echo "$pkg" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if ! grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null; then
    log "INFO: Not in game list: $pkg"
    generate_games_json
    return 0
  fi
  grep -Fxv "$pkg" "$GAME_PACKAGES" > "${GAME_PACKAGES}.tmp" 2>/dev/null
  mv -f "${GAME_PACKAGES}.tmp" "$GAME_PACKAGES"
  chmod 666 "$GAME_PACKAGES" 2>/dev/null
  sync
  log "REMOVED game package: $pkg"
  generate_games_json
  # Reset governor jika package ini sedang foreground
  local current_fg=$(get_foreground_app)
  if [ "$current_fg" = "$pkg" ]; then
    log "Removed pkg is foreground, reset governor to: $DEFAULT_GOVERNOR"
    restore_governor_config "$DEFAULT_GOVERNOR"
    generate_dynamic_json "$pkg" "idle"
  fi
  return 0
}

set_gaming_governor() {
  local gov="$1"
  [ -z "$gov" ] && return 1
  gov=$(echo "$gov" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if ! echo "$AVAILABLE_GOVERNORS" | grep -qw "$gov"; then
    log "ERROR: Governor not available: $gov"
    return 1
  fi
  echo "$gov" > "$GOVERNOR_PREF"
  chmod 666 "$GOVERNOR_PREF" 2>/dev/null
  sync
  GAMING_GOVERNOR="$gov"
  log "Gaming governor updated: $gov"
  generate_config_json
  # Jika saat ini sedang gaming mode, apply langsung
  local current_fg=$(get_foreground_app)
  if [ -n "$current_fg" ] && is_game "$current_fg" 2>/dev/null; then
    log "Gaming app active, applying new governor immediately: $gov"
    restore_governor_config "$gov"
  fi
  generate_dynamic_json "$(get_foreground_app)" "gaming"
  return 0
}

# ============================================================
# JSON GENERATORS
# ============================================================
generate_config_json() {
  local gaming_gov=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d '\r\n\t' || echo "$GAMING_GOVERNOR")
  local gov_options=""
  local count=0
  for gov in schedutil schedhorizon ondemand performance interactive conservative powersave walt sugov_ext; do
    if echo "$AVAILABLE_GOVERNORS" | grep -qw "$gov"; then
      [ $count -eq 0 ] && gov_options="\"$gov\"" || gov_options="$gov_options,\"$gov\""
      count=$((count + 1))
    fi
  done
  printf '{"chipset":"%s","default_idle":"%s","gaming_governor":"%s","available_governors":[%s],"all_governors":"%s"}\n' \
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
      line=$(echo "$line" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -z "$line" ] && continue
      [ $count -eq 0 ] && games_array="\"${line}\"" || games_array="${games_array},\"${line}\""
      count=$((count + 1))
    done < "$GAME_PACKAGES"
  fi
  local ts=$(date +%s)000
  printf '{"status":"success","games":[%s],"count":%d,"timestamp":%s}\n' \
    "$games_array" "$count" "$ts" > "$JSON_GAMES"
  chmod 666 "$JSON_GAMES" 2>/dev/null
}

generate_static_json() {
  local device=$(getprop ro.product.model 2>/dev/null || echo "Unknown")
  local kernel=$(uname -r 2>/dev/null || echo "Unknown")
  printf '{"cores":%d,"kernel":"%s","device":"%s","default_governor":"%s","chipset":"%s"}\n' \
    "$NUM_CORES" "$kernel" "$device" "$DEFAULT_GOVERNOR" "$CHIPSET" > "$JSON_STATIC"
  chmod 666 "$JSON_STATIC" 2>/dev/null
}

get_temperature() {
  local temp=0
  for i in 0 1 2 3 4 5; do
    if [ -f "/sys/class/thermal/thermal_zone${i}/temp" ]; then
      local t=$(cat "/sys/class/thermal/thermal_zone${i}/temp" 2>/dev/null || echo "0")
      if [ "$t" -gt 0 ] && [ "$t" -lt 150000 ]; then
        temp=$t; break
      fi
    fi
  done
  echo $temp
}

generate_dynamic_json() {
  local foreground="$1"
  local state="$2"
  local governor=$(cat "${CPU_BASE}/cpu0/cpufreq/scaling_governor" 2>/dev/null || echo "unknown")
  local temp=$(get_temperature)
  [ -z "$foreground" ] && foreground="unknown"
  local freqs=""
  local max_cpu=3
  [ $NUM_CORES -lt 4 ] && max_cpu=$((NUM_CORES - 1))
  for cpu in $(seq 0 $max_cpu); do
    local freq=$(cat "${CPU_BASE}/cpu${cpu}/cpufreq/scaling_cur_freq" 2>/dev/null || echo "0")
    [ $cpu -eq 0 ] && freqs="$freq" || freqs="$freqs,$freq"
  done
  printf '{"governor":"%s","foreground":"%s","temperature":%d,"frequencies":[%s],"state":"%s","timestamp":%d}\n' \
    "$governor" "$foreground" "$temp" "$freqs" "$state" "$(date +%s)" > "$JSON_DYNAMIC"
  chmod 666 "$JSON_DYNAMIC" 2>/dev/null
}

# ============================================================
# THERMAL PROTECTION
# ============================================================
check_thermal() {
  local temp=$(get_temperature)
  if [ "$temp" -ge "$THERMAL_CRITICAL" ] 2>/dev/null; then
    if [ "$THERMAL_TRIGGERED" -eq 0 ]; then
      log "THERMAL CRITICAL: ${temp} mC - forcing idle governor"
      restore_governor_config "$DEFAULT_GOVERNOR"
      THERMAL_TRIGGERED=1
    fi
    return 1
  elif [ "$temp" -ge "$THERMAL_WARNING" ] 2>/dev/null; then
    if [ "$THERMAL_TRIGGERED" -eq 0 ]; then
      log "THERMAL WARNING: ${temp} mC"
    fi
    return 1
  else
    if [ "$THERMAL_TRIGGERED" -eq 1 ]; then
      log "THERMAL OK: ${temp} mC - resuming"
      THERMAL_TRIGGERED=0
    fi
    return 0
  fi
}

# ============================================================
# HTTP SERVER
# ============================================================
start_http_server() {
  killall httpd 2>/dev/null
  sleep 1
  ln -sf "$LOG" "$WEBROOT/log.txt" 2>/dev/null
  chmod 666 "$WEBROOT/log.txt" 2>/dev/null
  command -v httpd >/dev/null 2>&1 && httpd -p 127.0.0.1:$HTTP_PORT -h "$WEBROOT" 2>/dev/null &
}

# ============================================================
# API SERVER
# Arsitektur: nc -l pipe ke handler, handler pipe response ke nc -l kedua.
# BENAR: 1 nc per siklus, baca request + tulis response via HEREDOC ke nc
# ============================================================
handle_request() {
  local GET_LINE="$1"
  local QUERY=$(echo "$GET_LINE" | grep -oE '\?[^ ]+' | cut -c2-)

  local ACTION="" PKG="" GOVERNOR=""

  if [ -n "$QUERY" ]; then
    for param in $(echo "$QUERY" | tr '&' '\n'); do
      local KEY=$(echo "$param" | cut -d= -f1)
      local VAL=$(echo "$param" | cut -d= -f2- | sed 's/%2E/./g; s/%2e/./g; s/%20/ /g; s/+/ /g; s/%2F/\//g')
      case "$KEY" in
        action)   ACTION="$VAL" ;;
        pkg)      PKG="$VAL" ;;
        governor) GOVERNOR="$VAL" ;;
      esac
    done
  fi

  local BODY=""
  case "$ACTION" in
    add)
      if [ -z "$PKG" ]; then
        BODY='{"status":"error","message":"Missing pkg"}'
      elif add_package "$PKG"; then
        BODY='{"status":"success","message":"Package added","package":"'"$PKG"'"}'
      else
        BODY='{"status":"error","message":"Duplicate or conflict"}'
      fi
      ;;
    remove)
      if [ -z "$PKG" ]; then
        BODY='{"status":"error","message":"Missing pkg"}'
      elif remove_package "$PKG"; then
        BODY='{"status":"success","message":"Package removed","package":"'"$PKG"'"}'
      else
        BODY='{"status":"error","message":"Failed to remove"}'
      fi
      ;;
    set_governor)
      if [ -z "$GOVERNOR" ]; then
        BODY='{"status":"error","message":"Missing governor"}'
      elif set_gaming_governor "$GOVERNOR"; then
        BODY='{"status":"success","message":"Governor updated","governor":"'"$GOVERNOR"'"}'
      else
        BODY='{"status":"error","message":"Governor not available"}'
      fi
      ;;
    set_app_governor)
      if [ -z "$PKG" ] || [ -z "$GOVERNOR" ]; then
        BODY='{"status":"error","message":"Missing pkg or governor"}'
      elif set_app_governor "$PKG" "$GOVERNOR"; then
        BODY='{"status":"success","message":"App governor set","package":"'"$PKG"'","governor":"'"$GOVERNOR"'"}'
      else
        BODY='{"status":"error","message":"Invalid governor or conflict"}'
      fi
      ;;
    remove_app_governor)
      if [ -z "$PKG" ]; then
        BODY='{"status":"error","message":"Missing pkg"}'
      elif remove_app_governor "$PKG"; then
        BODY='{"status":"success","message":"App governor removed","package":"'"$PKG"'"}'
      else
        BODY='{"status":"error","message":"Failed"}'
      fi
      ;;
    get_status)
      local cur_gov=$(cat "${CPU_BASE}/cpu0/cpufreq/scaling_governor" 2>/dev/null || echo "unknown")
      local cur_temp=$(get_temperature)
      BODY='{"status":"success","governor":"'"$cur_gov"'","default":"'"$DEFAULT_GOVERNOR"'","gaming":"'"$GAMING_GOVERNOR"'","temperature":'"$cur_temp"'}'
      ;;
    "")
      # Health check / empty request
      BODY='{"status":"ok"}'
      ;;
    *)
      BODY='{"status":"error","message":"Unknown action"}'
      ;;
  esac

  [ -z "$ACTION" ] && log "API: health check" || log "API: $ACTION $PKG $GOVERNOR -> ${BODY}"
  echo "$BODY"
}

start_api_server() {
  local TMP_REQ="/data/local/tmp/adaptperf_req.tmp"
  local TMP_RESP="/data/local/tmp/adaptperf_resp.tmp"
  while true; do
    # Terima koneksi, baca request ke file tmp
    rm -f "$TMP_REQ" "$TMP_RESP"
    nc -l -p $API_PORT -w 5 > "$TMP_REQ" 2>/dev/null

    # Ambil GET line
    local GET_LINE=$(head -1 "$TMP_REQ" 2>/dev/null | tr -d '\r')
    [ -z "$GET_LINE" ] && continue

    # Proses request, hasilkan body
    local BODY=$(handle_request "$GET_LINE")
    local BLEN=${#BODY}

    # Tulis HTTP response ke file, kirim via nc baru
    printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, OPTIONS\r\nConnection: close\r\n\r\n%s' \
      "$BLEN" "$BODY" > "$TMP_RESP"
    nc -l -p $API_PORT -w 2 < "$TMP_RESP" >/dev/null 2>&1 &
    # Beri sedikit jeda agar nc sempat bind sebelum client retry
    sleep 0.1
  done
}

# ============================================================
# GAME DETECTION
# ============================================================
is_game() {
  local app="$1"
  [ -z "$app" ] && return 1
  [ ! -f "$GAME_PACKAGES" ] && return 1
  while IFS= read -r package || [ -n "$package" ]; do
    case "$package" in "#"*|"") continue ;; esac
    package=$(echo "$package" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ "$app" = "$package" ] && return 0
  done < "$GAME_PACKAGES"
  return 1
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

  restore_governor_config "$DEFAULT_GOVERNOR"
  log "Monitor loop started. Default: $DEFAULT_GOVERNOR, Gaming: $GAMING_GOVERNOR"

  while true; do
    local foreground=$(get_foreground_app)

    if [ -n "$foreground" ] && [ "$foreground" != "$last_foreground" ]; then
      last_foreground="$foreground"
      log "Foreground: $foreground"
      game_counter=0; idle_counter=0; app_counter=0
    fi

    # Thermal check
    if ! check_thermal; then
      current_state="thermal_throttle"
      last_applied_governor=""
      generate_dynamic_json "$foreground" "thermal_throttle"
      sleep 2; continue
    fi

    # Reload gaming governor dari file (agar realtime update saat user ubah via API)
    local current_gaming_gov=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d '\r\n\t')
    if [ -n "$current_gaming_gov" ] && echo "$AVAILABLE_GOVERNORS" | grep -qw "$current_gaming_gov"; then
      GAMING_GOVERNOR="$current_gaming_gov"
    fi

    # Per-app governor check
    local app_custom_gov=""
    local has_custom_gov=1
    if [ -n "$foreground" ]; then
      app_custom_gov=$(get_app_governor "$foreground" 2>/dev/null)
      has_custom_gov=$?
    fi

    local target_state="idle"
    local should_apply=0
    local target_governor=""

    if [ $has_custom_gov -eq 0 ] && [ -n "$app_custom_gov" ]; then
      target_state="gaming"
      target_governor="$app_custom_gov"
      app_counter=$((app_counter + 1))
      game_counter=0; idle_counter=0
      [ $app_counter -ge 2 ] && should_apply=1
    else
      local is_game_running=0
      [ -n "$foreground" ] && is_game "$foreground" && is_game_running=1
      if [ $is_game_running -eq 1 ]; then
        target_state="gaming"
        target_governor="$GAMING_GOVERNOR"
        game_counter=$((game_counter + 1))
        idle_counter=0; app_counter=0
        [ $game_counter -ge 3 ] && should_apply=1
      else
        target_state="idle"
        target_governor="$DEFAULT_GOVERNOR"
        idle_counter=$((idle_counter + 1))
        game_counter=0; app_counter=0
        [ $idle_counter -ge 3 ] && should_apply=1
      fi
    fi

    if [ $should_apply -eq 1 ]; then
      if [ "$current_state" != "$target_state" ] || [ "$last_applied_governor" != "$target_governor" ]; then
        restore_governor_config "$target_governor"
        current_state="$target_state"
        last_applied_governor="$target_governor"
        log "STATE: $target_state -> $target_governor (fg: $foreground)"
      fi
    fi

    generate_dynamic_json "$foreground" "$current_state"
    sleep 1
  done
}

# ============================================================
# STARTUP
# ============================================================
backup_initial_config
DEFAULT_GOVERNOR=$(detect_default_governor)
log "Idle governor    : $DEFAULT_GOVERNOR"
GAMING_GOVERNOR=$(load_gaming_governor)
log "Gaming governor  : $GAMING_GOVERNOR"
log "Thermal warning  : $((THERMAL_WARNING/1000)) C"
log "Thermal critical : $((THERMAL_CRITICAL/1000)) C"

log "Generating initial JSONs..."
generate_static_json
generate_config_json
generate_games_json
generate_app_governors_json
generate_dynamic_json "unknown" "idle"

log "Starting HTTP server on port $HTTP_PORT..."
start_http_server

log "Starting API server on port $API_PORT..."
start_api_server &

log "MODULE READY"
log "Dashboard : http://127.0.0.1:$HTTP_PORT"
log "API       : http://127.0.0.1:$API_PORT"
log "================================================"

monitor_loop
