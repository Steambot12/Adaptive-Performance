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
log "Adaptive Performance v1.2 - Stable"
log "================================================"

mkdir -p "$WEBROOT" 2>/dev/null
chmod 777 "$WEBROOT" 2>/dev/null
mkdir -p "$STOCK_CONFIG_DIR" 2>/dev/null
chmod 755 "$STOCK_CONFIG_DIR" 2>/dev/null

# Buat file default kosong bila belum ada
[ ! -f "$APP_GOVERNORS" ] && touch "$APP_GOVERNORS"
chmod 666 "$APP_GOVERNORS" 2>/dev/null

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

# ============================================================
# HARDWARE DETECTION  (dilakukan AWAL sebelum JSON di-generate)
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
  if echo "$platform$hardware$soc" | grep -qiE "mt[0-9]+|mediatek|dimensity"; then
    echo "mediatek"
  else
    echo "snapdragon"
  fi
}
CHIPSET=$(detect_chipset)

AVAILABLE_GOVERNORS=$(cat ${CPU_BASE}/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
# Fallback jika gagal baca
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
  local max_cpu=$((NUM_CORES - 1))
  log "Apply governor: $target_gov (0-$max_cpu)"
  local i=0
  while [ $i -le $max_cpu ]; do
    local cpu_dir="${CPU_BASE}/cpu${i}/cpufreq"
    if [ -d "$cpu_dir" ]; then
      [ -f "$STOCK_CONFIG_DIR/scaling_min_freq.txt" ] && \
        cat "$STOCK_CONFIG_DIR/scaling_min_freq.txt" > "$cpu_dir/scaling_min_freq" 2>/dev/null
      [ -f "$STOCK_CONFIG_DIR/scaling_max_freq.txt" ] && \
        cat "$STOCK_CONFIG_DIR/scaling_max_freq.txt" > "$cpu_dir/scaling_max_freq" 2>/dev/null
      echo "$target_gov" > "$cpu_dir/scaling_governor" 2>/dev/null
      local tunable_dir="$cpu_dir/${target_gov}"
      local tunable_backup="$STOCK_CONFIG_DIR/$target_gov"
      if [ -d "$tunable_dir" ] && [ -d "$tunable_backup" ] && [ -f "$tunable_backup/.backup_done" ]; then
        for tf in $(ls "$tunable_backup" 2>/dev/null); do
          [ "$tf" = ".backup_done" ] && continue
          local tgt="$tunable_dir/$tf"
          local src="$tunable_backup/$tf"
          [ -f "$tgt" ] && [ -w "$tgt" ] && [ -f "$src" ] && cat "$src" > "$tgt" 2>/dev/null
        done
      fi
    fi
    i=$((i + 1))
  done
  log "  Done: $target_gov applied"
}

# ============================================================
# GOVERNOR DETECTION  (hasil disimpan ke DEFAULT_GOVERNOR & GAMING_GOVERNOR)
# ============================================================
detect_default_governor() {
  # 1. Dari file user preference
  if [ -f "$DEFAULT_GOV_FILE" ]; then
    local saved=$(cat "$DEFAULT_GOV_FILE" 2>/dev/null | head -1 | tr -d ' \r\n\t')
    if [ -n "$saved" ] && echo " $AVAILABLE_GOVERNORS " | grep -q " $saved " && [ "$saved" != "performance" ]; then
      echo "$saved"; return
    fi
  fi
  # 2. Dari backup stock
  if [ -f "$STOCK_CONFIG_DIR/stock_governor.txt" ]; then
    local stock=$(cat "$STOCK_CONFIG_DIR/stock_governor.txt" 2>/dev/null | tr -d ' \r\n\t')
    if [ -n "$stock" ] && [ "$stock" != "performance" ]; then
      echo "$stock"; return
    fi
  fi
  # 3. Auto-detect berdasarkan chipset
  if [ "$CHIPSET" = "mediatek" ]; then
    for g in sugov_ext schedutil walt interactive ondemand; do
      echo " $AVAILABLE_GOVERNORS " | grep -q " $g " && echo "$g" && return
    done
  else
    for g in walt schedutil interactive ondemand; do
      echo " $AVAILABLE_GOVERNORS " | grep -q " $g " && echo "$g" && return
    done
  fi
  # 4. Pilih yang pertama bukan performance
  for g in $AVAILABLE_GOVERNORS; do
    [ "$g" != "performance" ] && echo "$g" && return
  done
  echo "schedutil"
}

detect_gaming_governor() {
  if [ "$CHIPSET" = "mediatek" ]; then
    for g in schedhorizon schedutil performance; do
      echo " $AVAILABLE_GOVERNORS " | grep -q " $g " && echo "$g" && return
    done
  else
    for g in schedutil performance; do
      echo " $AVAILABLE_GOVERNORS " | grep -q " $g " && echo "$g" && return
    done
  fi
  echo "$(echo "$AVAILABLE_GOVERNORS" | awk '{print $1}')"
}

load_gaming_governor() {
  if [ -f "$GOVERNOR_PREF" ]; then
    local pref=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d ' \r\n\t')
    if [ -n "$pref" ] && echo " $AVAILABLE_GOVERNORS " | grep -q " $pref "; then
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
  [ -z "$pkg" ] || [ -z "$gov" ] && return 1
  pkg=$(echo "$pkg" | tr -d ' \r\n\t')
  gov=$(echo "$gov" | tr -d ' \r\n\t')
  log "SET PER-APP: $pkg = $gov"
  if ! echo " $AVAILABLE_GOVERNORS " | grep -q " $gov "; then
    log "ERROR: Invalid governor: $gov"
    return 1
  fi
  if grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null; then
    log "ERROR: Already in game list: $pkg"
    return 1
  fi
  # Hapus entry lama jika ada
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
    log "INFO: $pkg not found"
  fi
  generate_app_governors_json
  local fg=$(get_foreground_app)
  if [ "$fg" = "$pkg" ]; then
    restore_governor_config "$DEFAULT_GOVERNOR"
    generate_dynamic_json "$fg" "idle"
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
  printf '{"status":"success","app_governors":[%s],"count":%d}\n' "$arr" "$cnt" > "$JSON_APP_GOVS"
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
    log "WARN: Duplicate: $pkg"
    return 1
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
    log "INFO: Not in list: $pkg"
    generate_games_json
    return 0
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
    generate_dynamic_json "$fg" "idle"
  fi
  return 0
}

set_gaming_governor() {
  local gov="$1"
  [ -z "$gov" ] && return 1
  gov=$(echo "$gov" | tr -d ' \r\n\t')
  if ! echo " $AVAILABLE_GOVERNORS " | grep -q " $gov "; then
    log "ERROR: Governor not available: $gov"; return 1
  fi
  echo "$gov" > "$GOVERNOR_PREF"
  chmod 666 "$GOVERNOR_PREF" 2>/dev/null
  sync
  GAMING_GOVERNOR="$gov"
  log "Gaming governor set: $gov"
  generate_config_json
  # Apply langsung jika game sedang aktif
  local fg=$(get_foreground_app)
  if [ -n "$fg" ] && is_game "$fg"; then
    log "Game active, apply immediately: $gov"
    restore_governor_config "$gov"
  fi
  generate_dynamic_json "$fg" "gaming"
  return 0
}

# ============================================================
# JSON GENERATORS
# ============================================================
generate_static_json() {
  local device=$(getprop ro.product.model 2>/dev/null)
  [ -z "$device" ] && device="Unknown"
  local kernel=$(uname -r 2>/dev/null)
  [ -z "$kernel" ] && kernel="Unknown"
  printf '{"cores":%d,"kernel":"%s","device":"%s","default_governor":"%s","chipset":"%s"}\n' \
    "$NUM_CORES" "$kernel" "$device" "$DEFAULT_GOVERNOR" "$CHIPSET" > "$JSON_STATIC"
  chmod 666 "$JSON_STATIC" 2>/dev/null
  log "static.json: device=$device cores=$NUM_CORES default=$DEFAULT_GOVERNOR"
}

generate_config_json() {
  local gaming_gov
  gaming_gov=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d ' \r\n\t')
  [ -z "$gaming_gov" ] && gaming_gov="$GAMING_GOVERNOR"
  # Buat list governor tersedia (hanya yang dikenal)
  local gov_opts=""
  local cnt=0
  for g in schedutil schedhorizon ondemand performance interactive conservative powersave walt sugov_ext; do
    if echo " $AVAILABLE_GOVERNORS " | grep -q " $g "; then
      [ $cnt -gt 0 ] && gov_opts="$gov_opts,"
      gov_opts="$gov_opts\"$g\""
      cnt=$((cnt + 1))
    fi
  done
  # Jika tidak ada yang cocok, masukkan semua
  if [ $cnt -eq 0 ]; then
    for g in $AVAILABLE_GOVERNORS; do
      [ $cnt -gt 0 ] && gov_opts="$gov_opts,"
      gov_opts="$gov_opts\"$g\""
      cnt=$((cnt + 1))
    done
  fi
  printf '{"chipset":"%s","default_idle":"%s","gaming_governor":"%s","available_governors":[%s]}\n' \
    "$CHIPSET" "$DEFAULT_GOVERNOR" "$gaming_gov" "$gov_opts" > "$JSON_CONFIG"
  chmod 666 "$JSON_CONFIG" 2>/dev/null
  log "config.json: idle=$DEFAULT_GOVERNOR gaming=$gaming_gov"
}

generate_games_json() {
  local arr=""
  local cnt=0
  if [ -f "$GAME_PACKAGES" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "#"*|"") continue ;; esac
      line=$(echo "$line" | tr -d ' \r\n\t')
      [ -z "$line" ] && continue
      [ $cnt -gt 0 ] && arr="$arr,"
      arr="$arr\"$line\""
      cnt=$((cnt + 1))
    done < "$GAME_PACKAGES"
  fi
  printf '{"status":"success","games":[%s],"count":%d}\n' "$arr" "$cnt" > "$JSON_GAMES"
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
  local governor=$(cat "${CPU_BASE}/cpu0/cpufreq/scaling_governor" 2>/dev/null)
  [ -z "$governor" ] && governor="unknown"
  local temp=$(get_temperature)
  local freqs=""
  local max_show=3
  [ $NUM_CORES -lt 4 ] && max_show=$((NUM_CORES - 1))
  local i=0
  while [ $i -le $max_show ]; do
    local freq=$(cat "${CPU_BASE}/cpu${i}/cpufreq/scaling_cur_freq" 2>/dev/null || echo 0)
    [ $i -gt 0 ] && freqs="$freqs,"
    freqs="$freqs$freq"
    i=$((i + 1))
  done
  printf '{"governor":"%s","foreground":"%s","temperature":%s,"frequencies":[%s],"state":"%s","timestamp":%s}\n' \
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
      log "THERMAL CRITICAL: ${temp}mC"
      restore_governor_config "$DEFAULT_GOVERNOR"
      THERMAL_TRIGGERED=1
    }
    return 1
  elif [ "$temp" -ge "$THERMAL_WARNING" ] 2>/dev/null; then
    [ "$THERMAL_TRIGGERED" -eq 0 ] && log "THERMAL WARNING: ${temp}mC"
    return 1
  else
    [ "$THERMAL_TRIGGERED" -eq 1 ] && {
      log "THERMAL OK: ${temp}mC"
      THERMAL_TRIGGERED=0
    }
    return 0
  fi
}

# ============================================================
# HTTP SERVER
# ============================================================
start_http_server() {
  killall httpd 2>/dev/null; sleep 1
  # Buat symlink log agar bisa diakses via HTTP
  ln -sf "$LOG" "$WEBROOT/log.txt" 2>/dev/null
  chmod 666 "$WEBROOT/log.txt" 2>/dev/null
  if command -v httpd >/dev/null 2>&1; then
    httpd -p 127.0.0.1:$HTTP_PORT -h "$WEBROOT" 2>/dev/null &
    log "HTTP server started on port $HTTP_PORT"
  else
    log "WARNING: httpd not found!"
  fi
}

# ============================================================
# API SERVER  - Single nc per siklus: terima + kirim dalam 1 koneksi
# nc -l mendengar, script baca stdin (request) lalu stdout (response)
# ============================================================
process_api_request() {
  # Baca baris pertama HTTP request dari stdin
  local GET_LINE
  read -r GET_LINE
  GET_LINE=$(echo "$GET_LINE" | tr -d '\r')
  [ -z "$GET_LINE" ] && printf 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' && return

  # Parse query string
  local QUERY=$(echo "$GET_LINE" | grep -oE '\?[^ H]+' | cut -c2-)
  local ACTION="" PKG="" GOVERNOR=""

  for param in $(echo "$QUERY" | tr '&' '\n'); do
    local KEY=$(echo "$param" | cut -d= -f1)
    local VAL=$(echo "$param" | cut -d= -f2- | \
      sed 's/%2[Ee]/./g; s/%20/ /g; s/+/ /g; s/%2[Ff]/\//g; s/%5[Ff]/_/g')
    case "$KEY" in
      action)   ACTION="$VAL" ;;
      pkg)      PKG="$VAL" ;;
      governor) GOVERNOR="$VAL" ;;
    esac
  done

  local BODY
  case "$ACTION" in
    add)
      if [ -z "$PKG" ]; then
        BODY='{"status":"error","message":"Missing pkg"}'
      elif add_package "$PKG"; then
        BODY='{"status":"success","message":"Added","package":"'"$PKG"'"}'
      else
        BODY='{"status":"error","message":"Duplicate or invalid"}'
      fi ;;
    remove)
      if [ -z "$PKG" ]; then
        BODY='{"status":"error","message":"Missing pkg"}'
      elif remove_package "$PKG"; then
        BODY='{"status":"success","message":"Removed","package":"'"$PKG"'"}'
      else
        BODY='{"status":"error","message":"Failed"}'
      fi ;;
    set_governor)
      if [ -z "$GOVERNOR" ]; then
        BODY='{"status":"error","message":"Missing governor"}'
      elif set_gaming_governor "$GOVERNOR"; then
        BODY='{"status":"success","message":"Governor set","governor":"'"$GOVERNOR"'"}'
      else
        BODY='{"status":"error","message":"Governor unavailable"}'
      fi ;;
    set_app_governor)
      if [ -z "$PKG" ] || [ -z "$GOVERNOR" ]; then
        BODY='{"status":"error","message":"Missing pkg or governor"}'
      elif set_app_governor "$PKG" "$GOVERNOR"; then
        BODY='{"status":"success","message":"App governor set","package":"'"$PKG"'","governor":"'"$GOVERNOR"'"}'
      else
        BODY='{"status":"error","message":"Invalid or conflict"}'
      fi ;;
    remove_app_governor)
      if [ -z "$PKG" ]; then
        BODY='{"status":"error","message":"Missing pkg"}'
      elif remove_app_governor "$PKG"; then
        BODY='{"status":"success","message":"Removed","package":"'"$PKG"'"}'
      else
        BODY='{"status":"error","message":"Failed"}'
      fi ;;
    get_status)
      local cg=$(cat "${CPU_BASE}/cpu0/cpufreq/scaling_governor" 2>/dev/null || echo "unknown")
      local ct=$(get_temperature)
      BODY='{"status":"success","governor":"'"$cg"'","default":"'"$DEFAULT_GOVERNOR"'","gaming":"'"$GAMING_GOVERNOR"'","temperature":'"$ct"'}' ;;
    "")
      BODY='{"status":"ok","version":"1.2"}' ;;
    *)
      BODY='{"status":"error","message":"Unknown action"}' ;;
  esac

  log "API[$ACTION] pkg=$PKG gov=$GOVERNOR -> $BODY"

  local BLEN=${#BODY}
  printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n%s' \
    "$BLEN" "$BODY"
}

start_api_server() {
  log "API server loop started on port $API_PORT"
  while true; do
    # nc -l menerima koneksi, pipe stdin->process->stdout ke client
    # Busybox nc: tidak ada -p, gunakan port sebagai argumen
    if nc -l $API_PORT 2>/dev/null <<EOF_PROC
$(process_api_request)
EOF_PROC
    then
      : # koneksi ok
    fi
    # Lebih reliable: gunakan process substitution pipe
  done
}

# Versi API server yang lebih portable untuk Magisk/Android
start_api_server() {
  log "API server started on port $API_PORT"
  while true; do
    local TMP="/data/local/tmp/ap_api_$$.tmp"
    # Terima request → simpan ke tmp
    nc -l $API_PORT -w 3 > "$TMP" 2>/dev/null
    [ ! -s "$TMP" ] && rm -f "$TMP" && sleep 0.2 && continue

    # Parse GET line
    local GET_LINE=$(head -1 "$TMP" 2>/dev/null | tr -d '\r\n')
    rm -f "$TMP"
    [ -z "$GET_LINE" ] && continue

    # Parse query
    local QUERY=$(echo "$GET_LINE" | grep -oE '\?[^ H]+' | cut -c2-)
    local ACTION="" PKG="" GOVERNOR=""
    for param in $(echo "$QUERY" | tr '&' '\n'); do
      local KEY=$(echo "$param" | cut -d= -f1)
      local VAL=$(echo "$param" | cut -d= -f2- | sed 's/%2[Ee]/./g; s/%20/ /g; s/+/ /g')
      case "$KEY" in
        action)   ACTION="$VAL" ;;
        pkg)      PKG="$VAL" ;;
        governor) GOVERNOR="$VAL" ;;
      esac
    done

    local BODY
    case "$ACTION" in
      add)
        [ -z "$PKG" ] && BODY='{"status":"error","message":"Missing pkg"}' || {
          add_package "$PKG" && BODY='{"status":"success","message":"Added","package":"'"$PKG"'"}' || \
          BODY='{"status":"error","message":"Duplicate or invalid"}'
        } ;;
      remove)
        [ -z "$PKG" ] && BODY='{"status":"error","message":"Missing pkg"}' || {
          remove_package "$PKG" && BODY='{"status":"success","message":"Removed","package":"'"$PKG"'"}' || \
          BODY='{"status":"error","message":"Failed"}'
        } ;;
      set_governor)
        [ -z "$GOVERNOR" ] && BODY='{"status":"error","message":"Missing governor"}' || {
          set_gaming_governor "$GOVERNOR" && BODY='{"status":"success","message":"Governor set","governor":"'"$GOVERNOR"'"}' || \
          BODY='{"status":"error","message":"Unavailable"}'
        } ;;
      set_app_governor)
        { [ -z "$PKG" ] || [ -z "$GOVERNOR" ]; } && BODY='{"status":"error","message":"Missing params"}' || {
          set_app_governor "$PKG" "$GOVERNOR" && BODY='{"status":"success","message":"Set","package":"'"$PKG"'","governor":"'"$GOVERNOR"'"}' || \
          BODY='{"status":"error","message":"Invalid or conflict"}'
        } ;;
      remove_app_governor)
        [ -z "$PKG" ] && BODY='{"status":"error","message":"Missing pkg"}' || {
          remove_app_governor "$PKG" && BODY='{"status":"success","message":"Removed"}' || \
          BODY='{"status":"error","message":"Failed"}'
        } ;;
      get_status)
        local cg=$(cat "${CPU_BASE}/cpu0/cpufreq/scaling_governor" 2>/dev/null || echo unknown)
        BODY='{"status":"success","governor":"'"$cg"'","gaming":"'"$GAMING_GOVERNOR"'","default":"'"$DEFAULT_GOVERNOR"'"}' ;;
      "")
        BODY='{"status":"ok","version":"1.2"}' ;;
      *)
        BODY='{"status":"error","message":"Unknown action"}' ;;
    esac

    log "API[$ACTION] $PKG $GOVERNOR"

    # Kirim HTTP response ke port yang sama (nc baru bind)
    local BLEN=${#BODY}
    local RESP
    RESP=$(printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n%s' "$BLEN" "$BODY")
    echo "$RESP" | nc -l $API_PORT -w 2 >/dev/null 2>&1 &
    sleep 0.3
  done
}

# ============================================================
# GAME DETECTION
# ============================================================
is_game() {
  local app="$1"
  [ -z "$app" ] || [ ! -f "$GAME_PACKAGES" ] && return 1
  while IFS= read -r pkg || [ -n "$pkg" ]; do
    case "$pkg" in "#"*|"") continue ;; esac
    pkg=$(echo "$pkg" | tr -d ' \r\n\t')
    [ "$app" = "$pkg" ] && return 0
  done < "$GAME_PACKAGES"
  return 1
}

# ============================================================
# MONITOR LOOP
# ============================================================
monitor_loop() {
  local current_state="idle"
  local last_fg=""
  local last_gov=""
  local game_cnt=0 idle_cnt=0 app_cnt=0

  restore_governor_config "$DEFAULT_GOVERNOR"
  log "Monitor loop started. Idle=$DEFAULT_GOVERNOR Gaming=$GAMING_GOVERNOR"

  while true; do
    local fg=$(get_foreground_app)

    # Reset counter jika foreground berubah
    if [ -n "$fg" ] && [ "$fg" != "$last_fg" ]; then
      last_fg="$fg"
      game_cnt=0; idle_cnt=0; app_cnt=0
      log "Foreground: $fg"
    fi

    # Thermal check
    if ! check_thermal; then
      current_state="thermal_throttle"
      last_gov=""
      generate_dynamic_json "$fg" "thermal_throttle"
      sleep 2; continue
    fi

    # PENTING: Reload gaming governor dari file setiap loop
    # Ini memastikan perubahan via API langsung ter-reflect
    local file_gov=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d ' \r\n\t')
    if [ -n "$file_gov" ] && echo " $AVAILABLE_GOVERNORS " | grep -q " $file_gov "; then
      GAMING_GOVERNOR="$file_gov"
    fi

    # Tentukan target state & governor
    local target_state="idle"
    local target_gov="$DEFAULT_GOVERNOR"
    local should_apply=0

    # Cek per-app governor
    local custom_gov
    custom_gov=$(get_app_governor "$fg" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$custom_gov" ]; then
      target_state="gaming"
      target_gov="$custom_gov"
      app_cnt=$((app_cnt + 1))
      game_cnt=0; idle_cnt=0
      [ $app_cnt -ge 2 ] && should_apply=1
    elif [ -n "$fg" ] && is_game "$fg"; then
      target_state="gaming"
      target_gov="$GAMING_GOVERNOR"
      game_cnt=$((game_cnt + 1))
      idle_cnt=0; app_cnt=0
      [ $game_cnt -ge 3 ] && should_apply=1
    else
      target_state="idle"
      target_gov="$DEFAULT_GOVERNOR"
      idle_cnt=$((idle_cnt + 1))
      game_cnt=0; app_cnt=0
      [ $idle_cnt -ge 3 ] && should_apply=1
    fi

    # Apply governor jika state atau governor berubah
    if [ $should_apply -eq 1 ]; then
      if [ "$current_state" != "$target_state" ] || [ "$last_gov" != "$target_gov" ]; then
        restore_governor_config "$target_gov"
        current_state="$target_state"
        last_gov="$target_gov"
        log "STATE: $target_state | GOV: $target_gov | FG: $fg"
      fi
    fi

    generate_dynamic_json "$fg" "$current_state"
    sleep 1
  done
}

# ============================================================
# STARTUP  -  urutan PENTING: detect dulu, baru generate JSON
# ============================================================
log "--- Hardware Detection ---"
backup_initial_config

# Detect governor SEBELUM generate JSON agar JSON langsung benar
DEFAULT_GOVERNOR=$(detect_default_governor)
GAMING_GOVERNOR=$(load_gaming_governor)

log "Idle governor   : $DEFAULT_GOVERNOR"
log "Gaming governor : $GAMING_GOVERNOR"
log "Thermal warning : $((THERMAL_WARNING/1000))C"
log "Thermal critical: $((THERMAL_CRITICAL/1000))C"

# Generate semua JSON awal
log "--- Generating initial JSON files ---"
generate_static_json
generate_config_json
generate_games_json
generate_app_governors_json
generate_dynamic_json "unknown" "idle"

if [ -s "$APP_GOVERNORS" ]; then
  log "Per-app governors:"
  while IFS='=' read -r p g; do
    [ -n "$p" ] && log "  $p -> $g"
  done < "$APP_GOVERNORS"
fi

log "--- Starting servers ---"
start_http_server
sleep 1
start_api_server &

log "MODULE READY v1.2"
log "Dashboard : http://127.0.0.1:$HTTP_PORT"
log "API       : http://127.0.0.1:$API_PORT"
log "=========================================="

monitor_loop
