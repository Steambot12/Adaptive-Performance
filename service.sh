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
# HARDWARE DETECTION
# ============================================================
get_num_cores() {
  ls -d "${CPU_BASE}/cpu"[0-9]* 2>/dev/null | wc -l
}
NUM_CORES=$(get_num_cores)
[ -z "$NUM_CORES" ] || [ "$NUM_CORES" -eq 0 ] && NUM_CORES=4

detect_chipset() {
  local p h s
  p=$(getprop ro.board.platform 2>/dev/null)
  h=$(getprop ro.hardware 2>/dev/null)
  s=$(getprop ro.soc.model 2>/dev/null)
  echo "$p$h$s" | grep -qiE 'mt[0-9]+|mediatek|dimensity' && echo mediatek || echo snapdragon
}
CHIPSET=$(detect_chipset)

AVAILABLE_GOVERNORS=$(cat "${CPU_BASE}/cpu0/cpufreq/scaling_available_governors" 2>/dev/null)
[ -z "$AVAILABLE_GOVERNORS" ] && AVAILABLE_GOVERNORS="schedutil ondemand performance"

log "Chipset=$CHIPSET Cores=$NUM_CORES"
log "Governors: $AVAILABLE_GOVERNORS"

# ============================================================
# BACKUP & RESTORE
# ============================================================
backup_initial_config() {
  local cpu0="${CPU_BASE}/cpu0/cpufreq"
  local gov=$(cat "$cpu0/scaling_governor" 2>/dev/null)
  [ -n "$gov" ] && echo "$gov" > "$STOCK_CONFIG_DIR/stock_governor.txt"
  cat "$cpu0/scaling_min_freq" 2>/dev/null > "$STOCK_CONFIG_DIR/scaling_min_freq.txt"
  cat "$cpu0/scaling_max_freq" 2>/dev/null > "$STOCK_CONFIG_DIR/scaling_max_freq.txt"
  log "Backup done: stock=$gov"
}

restore_governor_config() {
  local gov="$1"
  [ -z "$gov" ] && return 1
  local i=0 max=$((NUM_CORES - 1))
  while [ $i -le $max ]; do
    local d="${CPU_BASE}/cpu${i}/cpufreq"
    if [ -d "$d" ]; then
      [ -f "$STOCK_CONFIG_DIR/scaling_min_freq.txt" ] && \
        cat "$STOCK_CONFIG_DIR/scaling_min_freq.txt" > "$d/scaling_min_freq" 2>/dev/null
      [ -f "$STOCK_CONFIG_DIR/scaling_max_freq.txt" ] && \
        cat "$STOCK_CONFIG_DIR/scaling_max_freq.txt" > "$d/scaling_max_freq" 2>/dev/null
      echo "$gov" > "$d/scaling_governor" 2>/dev/null
    fi
    i=$((i + 1))
  done
  log "Governor applied: $gov"
}

# ============================================================
# GOVERNOR DETECTION
# ============================================================
detect_default_governor() {
  if [ -f "$DEFAULT_GOV_FILE" ]; then
    local s=$(cat "$DEFAULT_GOV_FILE" 2>/dev/null | head -1 | tr -d ' \r\n\t')
    [ -n "$s" ] && echo " $AVAILABLE_GOVERNORS " | grep -q " $s " && [ "$s" != "performance" ] && echo "$s" && return
  fi
  if [ -f "$STOCK_CONFIG_DIR/stock_governor.txt" ]; then
    local s=$(cat "$STOCK_CONFIG_DIR/stock_governor.txt" 2>/dev/null | tr -d ' \r\n\t')
    [ -n "$s" ] && [ "$s" != "performance" ] && echo "$s" && return
  fi
  if [ "$CHIPSET" = "mediatek" ]; then
    for g in sugov_ext schedutil walt interactive ondemand; do
      echo " $AVAILABLE_GOVERNORS " | grep -q " $g " && echo "$g" && return
    done
  else
    for g in walt schedutil interactive ondemand; do
      echo " $AVAILABLE_GOVERNORS " | grep -q " $g " && echo "$g" && return
    done
  fi
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
    local p=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d ' \r\n\t')
    [ -n "$p" ] && echo " $AVAILABLE_GOVERNORS " | grep -q " $p " && echo "$p" && return
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
  fg=$(dumpsys window 2>/dev/null | grep -i 'mCurrentFocus' | grep -oE '[a-z][a-z0-9_.]*\.[a-zA-Z0-9_.]+' | head -1)
  [ -z "$fg" ] && fg=$(dumpsys activity activities 2>/dev/null | grep 'mResumedActivity' | grep -oE '[a-z][a-z0-9_.]*\.[a-zA-Z0-9_.]+' | head -1)
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
  local pkg="$1" gov="$2"
  [ -z "$pkg" ] || [ -z "$gov" ] && return 1
  pkg=$(echo "$pkg" | tr -d ' \r\n\t')
  gov=$(echo "$gov" | tr -d ' \r\n\t')
  echo " $AVAILABLE_GOVERNORS " | grep -q " $gov " || { log "ERR: bad gov $gov"; return 1; }
  grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null && { log "ERR: in game list"; return 1; }
  grep -v "^${pkg}=" "$APP_GOVERNORS" > "${APP_GOVERNORS}.tmp" 2>/dev/null
  mv -f "${APP_GOVERNORS}.tmp" "$APP_GOVERNORS"
  echo "${pkg}=${gov}" >> "$APP_GOVERNORS"
  chmod 666 "$APP_GOVERNORS" 2>/dev/null
  sync
  log "PER-APP: $pkg -> $gov"
  generate_app_governors_json
  return 0
}

remove_app_governor() {
  local pkg="$1"
  [ -z "$pkg" ] && return 1
  pkg=$(echo "$pkg" | tr -d ' \r\n\t')
  [ ! -f "$APP_GOVERNORS" ] && touch "$APP_GOVERNORS" && chmod 666 "$APP_GOVERNORS" 2>/dev/null
  grep -v "^${pkg}=" "$APP_GOVERNORS" > "${APP_GOVERNORS}.tmp" 2>/dev/null
  mv -f "${APP_GOVERNORS}.tmp" "$APP_GOVERNORS"
  chmod 666 "$APP_GOVERNORS" 2>/dev/null
  sync
  log "REMOVE PER-APP: $pkg"
  generate_app_governors_json
  local fg=$(get_foreground_app)
  [ "$fg" = "$pkg" ] && restore_governor_config "$DEFAULT_GOVERNOR" && generate_dynamic_json "$fg" "idle"
  return 0
}

generate_app_governors_json() {
  local arr="" cnt=0
  if [ -f "$APP_GOVERNORS" ] && [ -s "$APP_GOVERNORS" ]; then
    while IFS='=' read -r pkg gov; do
      [ -z "$pkg" ] && continue
      pkg=$(echo "$pkg" | tr -d ' \r\n\t')
      gov=$(echo "$gov" | tr -d ' \r\n\t')
      [ -z "$pkg" ] || [ -z "$gov" ] && continue
      [ $cnt -gt 0 ] && arr="$arr,"
      arr="${arr}{\"package\":\"${pkg}\",\"governor\":\"${gov}\"}"
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
  echo "$pkg" | grep -Eq '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$' || { log "ERR: invalid pkg"; return 1; }
  grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null && { log "WARN: duplicate $pkg"; return 1; }
  grep -q "^${pkg}=" "$APP_GOVERNORS" 2>/dev/null && { log "ERR: conflict per-app"; return 1; }
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
  [ "$fg" = "$pkg" ] && restore_governor_config "$DEFAULT_GOVERNOR" && generate_dynamic_json "$fg" "idle"
  return 0
}

set_gaming_governor() {
  local gov="$1"
  [ -z "$gov" ] && return 1
  gov=$(echo "$gov" | tr -d ' \r\n\t')
  echo " $AVAILABLE_GOVERNORS " | grep -q " $gov " || { log "ERR: governor unavailable: $gov"; return 1; }
  echo "$gov" > "$GOVERNOR_PREF"
  chmod 666 "$GOVERNOR_PREF" 2>/dev/null
  sync
  GAMING_GOVERNOR="$gov"
  log "Gaming governor: $gov"
  generate_config_json
  local fg=$(get_foreground_app)
  is_game "$fg" && restore_governor_config "$gov"
  generate_dynamic_json "$fg" "gaming"
  return 0
}

# ============================================================
# JSON GENERATORS
# ============================================================
generate_static_json() {
  local device kernel
  device=$(getprop ro.product.model 2>/dev/null); [ -z "$device" ] && device="Unknown"
  kernel=$(uname -r 2>/dev/null);                 [ -z "$kernel" ] && kernel="Unknown"
  printf '{"cores":%d,"kernel":"%s","device":"%s","default_governor":"%s","chipset":"%s"}\n' \
    "$NUM_CORES" "$kernel" "$device" "$DEFAULT_GOVERNOR" "$CHIPSET" > "$JSON_STATIC"
  chmod 666 "$JSON_STATIC" 2>/dev/null
  log "static.json OK: dev=$device gov=$DEFAULT_GOVERNOR"
}

generate_config_json() {
  local gaming_gov
  gaming_gov=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d ' \r\n\t')
  [ -z "$gaming_gov" ] && gaming_gov="$GAMING_GOVERNOR"

  # Bangun array governor tersedia
  local gov_opts="" cnt=0
  for g in schedutil schedhorizon walt sugov_ext interactive ondemand conservative powersave performance; do
    if echo " $AVAILABLE_GOVERNORS " | grep -q " $g "; then
      [ $cnt -gt 0 ] && gov_opts="$gov_opts,"
      gov_opts="$gov_opts\"$g\""
      cnt=$((cnt + 1))
    fi
  done
  # Fallback: masukkan semua governor jika tidak ada yang cocok
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
  log "config.json OK: idle=$DEFAULT_GOVERNOR gaming=$gaming_gov govs=$cnt"
}

generate_games_json() {
  local arr="" cnt=0
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
  printf '{"status":"success","games":[%s],"count":%d}\n' "$arr" "$cnt" > "$JSON_GAMES"
  chmod 666 "$JSON_GAMES" 2>/dev/null
}

get_temperature() {
  local i=0 t=0
  while [ $i -le 9 ]; do
    local f="/sys/class/thermal/thermal_zone${i}/temp"
    if [ -f "$f" ]; then
      t=$(cat "$f" 2>/dev/null || echo 0)
      [ "$t" -gt 1000 ] && [ "$t" -lt 200000 ] 2>/dev/null && echo "$t" && return
    fi
    i=$((i + 1))
  done
  echo 0
}

generate_dynamic_json() {
  local foreground="${1:-unknown}" state="${2:-idle}"
  local governor temp freqs="" i=0 show=3
  governor=$(cat "${CPU_BASE}/cpu0/cpufreq/scaling_governor" 2>/dev/null || echo unknown)
  temp=$(get_temperature)
  [ $NUM_CORES -lt 4 ] && show=$((NUM_CORES - 1))
  while [ $i -le $show ]; do
    local f=$(cat "${CPU_BASE}/cpu${i}/cpufreq/scaling_cur_freq" 2>/dev/null || echo 0)
    [ $i -gt 0 ] && freqs="$freqs,"
    freqs="$freqs$f"
    i=$((i + 1))
  done
  printf '{"governor":"%s","foreground":"%s","temperature":%s,"frequencies":[%s],"state":"%s","timestamp":%s}\n' \
    "$governor" "$foreground" "$temp" "$freqs" "$state" "$(date +%s)" > "$JSON_DYNAMIC"
  chmod 666 "$JSON_DYNAMIC" 2>/dev/null
}

# ============================================================
# THERMAL
# ============================================================
check_thermal() {
  local temp=$(get_temperature)
  if [ "$temp" -ge "$THERMAL_CRITICAL" ] 2>/dev/null; then
    [ "$THERMAL_TRIGGERED" -eq 0 ] && { log "THERMAL CRITICAL ${temp}mC"; restore_governor_config "$DEFAULT_GOVERNOR"; THERMAL_TRIGGERED=1; }
    return 1
  elif [ "$temp" -ge "$THERMAL_WARNING" ] 2>/dev/null; then
    [ "$THERMAL_TRIGGERED" -eq 0 ] && log "THERMAL WARNING ${temp}mC"
    return 1
  else
    [ "$THERMAL_TRIGGERED" -eq 1 ] && { log "THERMAL OK ${temp}mC"; THERMAL_TRIGGERED=0; }
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
# HTTP SERVER  (busybox httpd)
# ============================================================
start_http_server() {
  killall httpd 2>/dev/null
  sleep 1
  ln -sf "$LOG" "$WEBROOT/log.txt" 2>/dev/null
  chmod 666 "$WEBROOT/log.txt" 2>/dev/null
  if command -v httpd >/dev/null 2>&1; then
    httpd -p 127.0.0.1:$HTTP_PORT -h "$WEBROOT" 2>/dev/null &
    log "HTTP started :$HTTP_PORT"
  else
    log "WARN: httpd not found"
  fi
}

# ============================================================
# API SERVER  (single-nc, satu definisi, portable Busybox)
#
# Cara kerja:
#   1. nc -l $PORT  menerima satu koneksi
#   2. Semua data request masuk ke /tmp file
#   3. Parse, proses, langsung kirim response via echo ke fd nc
#   4. nc menutup koneksi  ->  loop ulang
# ============================================================
handle_api() {
  # $1 = file tmp yang berisi raw HTTP request
  local req_file="$1"
  local GET_LINE QUERY ACTION PKG GOVERNOR BODY BLEN

  GET_LINE=$(head -1 "$req_file" 2>/dev/null | tr -d '\r\n')
  [ -z "$GET_LINE" ] && \
    printf 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' && return

  QUERY=$(echo "$GET_LINE" | grep -oE '\?[^ H]+' | cut -c2-)
  ACTION=""; PKG=""; GOVERNOR=""

  for param in $(echo "$QUERY" | tr '&' '\n'); do
    local k v
    k=$(echo "$param" | cut -d= -f1)
    v=$(echo "$param" | cut -d= -f2- | sed 's/%2[Ee]/./g;s/%20/ /g;s/+/ /g;s/%5[Ff]/_/g;s/%2[Dd]/-/g')
    case "$k" in
      action)   ACTION="$v" ;;
      pkg)      PKG="$v" ;;
      governor) GOVERNOR="$v" ;;
    esac
  done

  case "$ACTION" in
    add)
      if [ -z "$PKG" ]; then BODY='{"status":"error","message":"Missing pkg"}'
      elif add_package "$PKG"; then BODY='{"status":"success","message":"Added"}'
      else BODY='{"status":"error","message":"Duplicate or invalid"}'
      fi ;;
    remove)
      if [ -z "$PKG" ]; then BODY='{"status":"error","message":"Missing pkg"}'
      elif remove_package "$PKG"; then BODY='{"status":"success","message":"Removed"}'
      else BODY='{"status":"error","message":"Failed"}'
      fi ;;
    set_governor)
      if [ -z "$GOVERNOR" ]; then BODY='{"status":"error","message":"Missing governor"}'
      elif set_gaming_governor "$GOVERNOR"; then BODY='{"status":"success","message":"Governor set","governor":"'"$GOVERNOR"'"}'
      else BODY='{"status":"error","message":"Unavailable"}'
      fi ;;
    set_app_governor)
      if [ -z "$PKG" ] || [ -z "$GOVERNOR" ]; then BODY='{"status":"error","message":"Missing params"}'
      elif set_app_governor "$PKG" "$GOVERNOR"; then BODY='{"status":"success","message":"Set"}'
      else BODY='{"status":"error","message":"Invalid or conflict"}'
      fi ;;
    remove_app_governor)
      if [ -z "$PKG" ]; then BODY='{"status":"error","message":"Missing pkg"}'
      elif remove_app_governor "$PKG"; then BODY='{"status":"success","message":"Removed"}'
      else BODY='{"status":"error","message":"Failed"}'
      fi ;;
    get_status)
      local cg ct
      cg=$(cat "${CPU_BASE}/cpu0/cpufreq/scaling_governor" 2>/dev/null || echo unknown)
      ct=$(get_temperature)
      BODY='{"status":"success","governor":"'"$cg"'","default":"'"$DEFAULT_GOVERNOR"'","gaming":"'"$GAMING_GOVERNOR"'","temperature":'"$ct"'}' ;;
    '')
      BODY='{"status":"ok","version":"1.2"}' ;;
    *)
      BODY='{"status":"error","message":"Unknown action"}' ;;
  esac

  log "API $ACTION pkg=$PKG gov=$GOVERNOR"
  BLEN=${#BODY}
  printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n%s' \
    "$BLEN" "$BODY"
}

start_api_server() {
  log "API server started :$API_PORT"
  local TMP_BASE="/data/local/tmp/ap_req"
  while true; do
    local TMP="${TMP_BASE}_$$.tmp"
    # Terima request -> simpan ke file -> proses -> kirim response
    # Semua dalam SATU nc session menggunakan named pipe trick
    local FIFO="/data/local/tmp/ap_fifo_$$"
    rm -f "$FIFO" 2>/dev/null
    if mkfifo "$FIFO" 2>/dev/null; then
      # Baca request ke TMP, generate response ke fifo, kirim via nc
      nc -l $API_PORT < "$FIFO" > "$TMP" 2>/dev/null &
      local NC_PID=$!
      sleep 0.1  # beri waktu nc bind port
      # Tunggu nc selesai (client konek & kirim request)
      wait $NC_PID 2>/dev/null
      # Generate response & masukkan ke fifo (nc sudah tutup, tapi kita parse TMP)
      rm -f "$FIFO"
      if [ -s "$TMP" ]; then
        # Buka koneksi BARU untuk kirim response (Android nc tidak full-duplex via pipe)
        local RESP_TMP="${TMP_BASE}_resp_$$.tmp"
        handle_api "$TMP" > "$RESP_TMP"
        # Kirim response: nc listen lagi, client belum tutup koneksi karena kita belum reply
        # Pakai socat jika ada, fallback ke write ke tcp
        if command -v socat >/dev/null 2>&1; then
          socat -u FILE:"$RESP_TMP" TCP4-LISTEN:$API_PORT,reuseaddr 2>/dev/null &
        else
          cat "$RESP_TMP" | nc -l $API_PORT -w 2 2>/dev/null &
        fi
        rm -f "$RESP_TMP"
      fi
      rm -f "$TMP"
    else
      # Fallback tanpa fifo: nc read then separate nc write
      nc -l $API_PORT -w 3 > "$TMP" 2>/dev/null
      if [ -s "$TMP" ]; then
        handle_api "$TMP" | nc -l $API_PORT -w 2 2>/dev/null &
      fi
      rm -f "$TMP"
    fi
    sleep 0.1
  done
}

# ============================================================
# MONITOR LOOP
# ============================================================
monitor_loop() {
  local cur_state="idle" last_fg="" last_gov=""
  local gcnt=0 icnt=0 acnt=0

  restore_governor_config "$DEFAULT_GOVERNOR"
  log "Monitor: idle=$DEFAULT_GOVERNOR gaming=$GAMING_GOVERNOR"

  while true; do
    local fg=$(get_foreground_app)

    if [ -n "$fg" ] && [ "$fg" != "$last_fg" ]; then
      last_fg="$fg"; gcnt=0; icnt=0; acnt=0
      log "Foreground: $fg"
    fi

    if ! check_thermal; then
      cur_state="thermal_throttle"; last_gov=""
      generate_dynamic_json "$fg" "thermal_throttle"
      sleep 2; continue
    fi

    # Reload gaming governor dari file setiap siklus
    local fg_gov=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d ' \r\n\t')
    [ -n "$fg_gov" ] && echo " $AVAILABLE_GOVERNORS " | grep -q " $fg_gov " && GAMING_GOVERNOR="$fg_gov"

    local t_state="idle" t_gov="$DEFAULT_GOVERNOR" apply=0
    local custom_gov
    custom_gov=$(get_app_governor "$fg" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$custom_gov" ]; then
      t_state="gaming"; t_gov="$custom_gov"
      acnt=$((acnt+1)); gcnt=0; icnt=0
      [ $acnt -ge 2 ] && apply=1
    elif [ -n "$fg" ] && is_game "$fg"; then
      t_state="gaming"; t_gov="$GAMING_GOVERNOR"
      gcnt=$((gcnt+1)); icnt=0; acnt=0
      [ $gcnt -ge 3 ] && apply=1
    else
      t_state="idle"; t_gov="$DEFAULT_GOVERNOR"
      icnt=$((icnt+1)); gcnt=0; acnt=0
      [ $icnt -ge 3 ] && apply=1
    fi

    if [ $apply -eq 1 ] && { [ "$cur_state" != "$t_state" ] || [ "$last_gov" != "$t_gov" ]; }; then
      restore_governor_config "$t_gov"
      cur_state="$t_state"; last_gov="$t_gov"
      log "STATE=$t_state GOV=$t_gov FG=$fg"
    fi

    generate_dynamic_json "$fg" "$cur_state"
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

log "idle=$DEFAULT_GOVERNOR gaming=$GAMING_GOVERNOR"
log "thermal: warn=$((THERMAL_WARNING/1000))C crit=$((THERMAL_CRITICAL/1000))C"

log "=== Generate JSON ==="
generate_static_json
generate_config_json
generate_games_json
generate_app_governors_json
generate_dynamic_json "unknown" "idle"

log "=== Starting Servers ==="
start_http_server
sleep 2
start_api_server &

log "=== MODULE READY v1.2 ==="
log "HTTP :$HTTP_PORT | API :$API_PORT"

monitor_loop
