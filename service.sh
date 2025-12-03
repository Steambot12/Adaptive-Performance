#!/system/bin/sh
# Adaptive Performance v1.1

MODDIR=${0%/*}

HTTP_PORT=9876
API_PORT=9877
LOG=/data/local/tmp/adaptive_perf.log

GAME_PACKAGES="$MODDIR/game_packages.txt"
GOVERNOR_PREF="$MODDIR/governor_pref.txt"
DEFAULT_GOV_FILE="$MODDIR/default_governor.txt"
STOCK_CONFIG_DIR="$MODDIR/stock_configs"

JSON_DYNAMIC="$MODDIR/webroot/dynamic.json"
JSON_STATIC="$MODDIR/webroot/static.json"
JSON_GAMES="$MODDIR/webroot/games.json"
JSON_CONFIG="$MODDIR/webroot/config.json"

WEBROOT="$MODDIR/webroot"
CPU_BASE="/sys/devices/system/cpu"

log() {
  echo "[$(date '+%H:%M:%S')] $1" >> $LOG 2>&1
}

# Tunggu boot selesai
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 1
done

log "================================================"
log "Adaptive Performance v1.1"
log "================================================"

mkdir -p $WEBROOT 2>/dev/null
chmod 777 $WEBROOT 2>/dev/null
mkdir -p $STOCK_CONFIG_DIR 2>/dev/null
chmod 755 $STOCK_CONFIG_DIR 2>/dev/null

# Init game list
if [ ! -f "$GAME_PACKAGES" ]; then
  cat > "$GAME_PACKAGES" << 'EOF'
com.garena.game.df
com.proxima.dfm
com.mobile.legends
EOF
fi
chmod 666 "$GAME_PACKAGES" 2>/dev/null

# CPU core count
get_num_cores() {
  ls -d ${CPU_BASE}/cpu[0-9]* 2>/dev/null | wc -l
}
NUM_CORES=$(get_num_cores)

# Chipset detect
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

# ==================== BACKUP INITIAL CONFIG ====================
backup_initial_config() {
  log "📦 Backing up initial kernel config..."

  local cpu0="${CPU_BASE}/cpu0/cpufreq"

  # Backup current governor
  local current_gov=$(cat $cpu0/scaling_governor 2>/dev/null)
  echo "$current_gov" > "$STOCK_CONFIG_DIR/stock_governor.txt"
  log "Stock governor: $current_gov"

  # Backup freq limits (CRITICAL - never override!)
  cat $cpu0/scaling_min_freq 2>/dev/null > "$STOCK_CONFIG_DIR/scaling_min_freq.txt"
  cat $cpu0/scaling_max_freq 2>/dev/null > "$STOCK_CONFIG_DIR/scaling_max_freq.txt"
  cat $cpu0/cpuinfo_min_freq 2>/dev/null > "$STOCK_CONFIG_DIR/cpuinfo_min_freq.txt"
  cat $cpu0/cpuinfo_max_freq 2>/dev/null > "$STOCK_CONFIG_DIR/cpuinfo_max_freq.txt"

  log "Min freq: $(cat $STOCK_CONFIG_DIR/scaling_min_freq.txt 2>/dev/null)"
  log "Max freq: $(cat $STOCK_CONFIG_DIR/scaling_max_freq.txt 2>/dev/null)"

  # Backup current active governor tunables
  backup_governor_tunables "$current_gov"

  log "✅ Initial config backed up"
}

# ==================== BACKUP GOVERNOR TUNABLES (DYNAMIC) ====================
backup_governor_tunables() {
  local gov="$1"
  local cpu0="${CPU_BASE}/cpu0/cpufreq"
  local tunable_dir="$cpu0/${gov}"

  
  if [ -f "$STOCK_CONFIG_DIR/$gov/.backup_done" ]; then
    return 0
  fi

 
  if [ ! -d "$tunable_dir" ]; then
    log "⏭️  Skip backup $gov (not active)"
    return 1
  fi

  log "📦 Backing up tunables: $gov"
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

  log "✅ Backed up $count tunables for $gov"
  return 0
}

# ==================== RESTORE GOVERNOR CONFIG ====================
restore_governor_config() {
  local target_gov="$1"
  local cpu0="${CPU_BASE}/cpu0/cpufreq"

  log "🔧 Switching to: $target_gov"

 
  if [ -f "$STOCK_CONFIG_DIR/scaling_min_freq.txt" ]; then
    local stock_min=$(cat "$STOCK_CONFIG_DIR/scaling_min_freq.txt")
    echo "$stock_min" > $cpu0/scaling_min_freq 2>/dev/null
  fi

  if [ -f "$STOCK_CONFIG_DIR/scaling_max_freq.txt" ]; then
    local stock_max=$(cat "$STOCK_CONFIG_DIR/scaling_max_freq.txt")
    echo "$stock_max" > $cpu0/scaling_max_freq 2>/dev/null
  fi


  echo "$target_gov" > $cpu0/scaling_governor 2>/dev/null


  backup_governor_tunables "$target_gov"


  local tunable_backup="$STOCK_CONFIG_DIR/$target_gov"
  if [ -d "$tunable_backup" ] && [ -f "$tunable_backup/.backup_done" ]; then
    local tunable_dir="$cpu0/${target_gov}"

    if [ -d "$tunable_dir" ]; then
      for tunable_file in $(ls $tunable_backup 2>/dev/null); do
        # Skip marker file
        [ "$tunable_file" = ".backup_done" ] && continue

        local target="$tunable_dir/$tunable_file"
        local source="$tunable_backup/$tunable_file"

        if [ -f "$target" ] && [ -w "$target" ] && [ -f "$source" ]; then
          cat "$source" > "$target" 2>/dev/null
        fi
      done
      log "✅ Tunables restored for $target_gov"
    fi
  else
    log "ℹ️  No backup for $target_gov (using kernel default)"
  fi


  local max_cpu=$((NUM_CORES - 1))
  for cpu in $(seq 1 $max_cpu); do
    local cpu_dir="${CPU_BASE}/cpu${cpu}/cpufreq"
    if [ -d "$cpu_dir" ]; then
      echo "$target_gov" > "$cpu_dir/scaling_governor" 2>/dev/null

     
      if [ -f "$STOCK_CONFIG_DIR/scaling_min_freq.txt" ]; then
        cat "$STOCK_CONFIG_DIR/scaling_min_freq.txt" > "$cpu_dir/scaling_min_freq" 2>/dev/null
      fi
      if [ -f "$STOCK_CONFIG_DIR/scaling_max_freq.txt" ]; then
        cat "$STOCK_CONFIG_DIR/scaling_max_freq.txt" > "$cpu_dir/scaling_max_freq" 2>/dev/null
      fi
    fi
  done
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


backup_initial_config

DEFAULT_GOVERNOR=$(detect_default_governor)
log "Idle governor: $DEFAULT_GOVERNOR"

GAMING_GOVERNOR=$(load_gaming_governor)
log "Gaming governor: $GAMING_GOVERNOR"

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
  log "➕ ADD: $pkg"
  [ -z "$pkg" ] && return 1
  pkg=$(echo "$pkg" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' 2>/dev/null)
  echo "$pkg" | grep -Eq '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$' 2>/dev/null || return 1
  grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null && generate_games_json && return 0
  echo "$pkg" >> "$GAME_PACKAGES"
  chmod 666 "$GAME_PACKAGES" 2>/dev/null
  sync
  log "✅ ADDED: $pkg"
  generate_games_json
  return 0
}

remove_package() {
  local pkg="$1"
  log "🗑️ REMOVE: $pkg"
  [ -z "$pkg" ] && return 1
  pkg=$(echo "$pkg" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' 2>/dev/null)
  if ! grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null; then
    log "⚠️ Not found: $pkg"
    generate_games_json
    return 0
  fi
  grep -Fxv "$pkg" "$GAME_PACKAGES" > "${GAME_PACKAGES}.tmp" 2>/dev/null
  mv -f "${GAME_PACKAGES}.tmp" "$GAME_PACKAGES"
  chmod 666 "$GAME_PACKAGES" 2>/dev/null
  sync
  log "✅ REMOVED: $pkg"
  generate_games_json
  return 0
}

set_gaming_governor() {
  local gov="$1"
  log "⚙️ SET GAMING GOVERNOR: $gov"
  [ -z "$gov" ] && return 1
  gov=$(echo "$gov" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' 2>/dev/null)
  echo "$AVAILABLE_GOVERNORS" | grep -q "$gov" || return 1
  echo "$gov" > "$GOVERNOR_PREF"
  chmod 666 "$GOVERNOR_PREF" 2>/dev/null
  sync
  GAMING_GOVERNOR="$gov"
  log "✅ Gaming governor set: $gov"
  generate_config_json
  return 0
}

start_api_server() {
  log "API server: port $API_PORT"
  while true; do
    REQUEST=$(echo "" | nc -l -p $API_PORT 2>/dev/null | head -10)
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

    RESPONSE=""
    case "$ACTION" in
      "add")
        [ -z "$PKG" ] && RESPONSE='{"status":"error","message":"Missing pkg"}' || {
          add_package "$PKG" && RESPONSE='{"status":"success","message":"Added","package":"'$PKG'"}' || RESPONSE='{"status":"error","message":"Failed"}'
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
      *)
        RESPONSE='{"status":"error","message":"Invalid action"}'
        ;;
    esac

    printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n%s" \
      "${#RESPONSE}" "$RESPONSE" | nc -l -p $API_PORT -w 1 >/dev/null 2>&1 &
    sleep 0.3
  done
}

get_foreground_app() {
  FG=$(dumpsys window 2>/dev/null | grep -i "mCurrentFocus" | grep -oE '[a-z][a-z0-9_.]*\.[a-zA-Z0-9_.]+' | head -1)
  [ -z "$FG" ] && FG=$(dumpsys activity activities 2>/dev/null | grep "mResumedActivity" | grep -oE '[a-z][a-z0-9_.]*\.[a-zA-Z0-9_.]+' | head -1)
  echo "$FG"
}

is_game() {
  local app="$1"
  [ -z "$app" ] && return 1
  [ ! -f "$GAME_PACKAGES" ] && return 1
  while IFS= read -r package || [ -n "$package" ]; do
    case "$package" in "#"*|"") continue ;; esac
    package=$(echo "$package" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' 2>/dev/null)
    [ "$app" = "$package" ] && return 0
  done < "$GAME_PACKAGES"
  return 1
}


apply_performance() {
  GAMING_GOVERNOR=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d '\r\n\t' || echo "$GAMING_GOVERNOR")
  restore_governor_config "$GAMING_GOVERNOR"
  log "🎮 GAMING MODE: $GAMING_GOVERNOR"
}

apply_powersave() {
  restore_governor_config "$DEFAULT_GOVERNOR"
  log "💤 IDLE MODE: $DEFAULT_GOVERNOR"
}

get_temperature() {
  local temp=0
  for i in 0 1 2; do
    if [ -f "/sys/class/thermal/thermal_zone$i/temp" ]; then
      local t=$(cat /sys/class/thermal/thermal_zone$i/temp 2>/dev/null || echo "0")
      if [ "$t" -gt 0 ] && [ "$t" -lt 150000 ]; then
        temp=$t
        break
      fi
    fi
  done
  echo $temp
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
  local game_counter=0
  local idle_counter=0

  apply_powersave

  while true; do
    foreground=$(get_foreground_app)
    [ "$foreground" != "$last_foreground" ] && [ -n "$foreground" ] && {
      last_foreground="$foreground"
      log "📱 App: $foreground"
    }

    is_game_running=0
    [ -n "$foreground" ] && is_game "$foreground" && is_game_running=1

    if [ $is_game_running -eq 1 ]; then
      game_counter=$((game_counter + 1))
      idle_counter=0
      if [ $game_counter -ge 3 ] && [ "$current_state" != "gaming" ]; then
        apply_performance
        current_state="gaming"
      fi
    else
      idle_counter=$((idle_counter + 1))
      game_counter=0
      if [ $idle_counter -ge 3 ] && [ "$current_state" = "gaming" ]; then
        apply_powersave
        current_state="idle"
      fi
    fi

    generate_dynamic_json "$foreground" "$current_state"
    sleep 1
  done
}

log "Generating JSONs..."
generate_static_json &
generate_config_json &
generate_games_json &
generate_dynamic_json "unknown" "idle" &
wait

log "Starting servers..."
start_http_server
start_api_server &
log "✅ MODULE READY (DYNAMIC BACKUP)!"
log "📊 Dashboard: http://127.0.0.1:$HTTP_PORT"
log "💤 Idle: $DEFAULT_GOVERNOR | 🎮 Gaming: $GAMING_GOVERNOR"
log "🔄 Tunables will be backed up when governor is first activated"
monitor_loop
