#!/system/bin/sh
# Adaptive Performance v1.1 - FINAL COMPLETE FIX

MODDIR=${0%/*}

HTTP_PORT=9876
API_PORT=9877
LOG=/data/local/tmp/adaptive_perf.log

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

log() {
  echo "[$(date '+%H:%M:%S')] $1" >> $LOG 2>&1
}

while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 1
done

log "================================================"
log "Adaptive Performance v1.1 - FINAL"
log "================================================"

mkdir -p $WEBROOT 2>/dev/null
chmod 777 $WEBROOT 2>/dev/null
mkdir -p $STOCK_CONFIG_DIR 2>/dev/null
chmod 755 $STOCK_CONFIG_DIR 2>/dev/null

if [ ! -f "$GAME_PACKAGES" ]; then
  cat > "$GAME_PACKAGES" << 'EOF'
com.garena.game.df
com.proxima.dfm
com.mobile.legends
EOF
fi
chmod 666 "$GAME_PACKAGES" 2>/dev/null

# ENSURE app_governors.txt EXISTS AND PERSISTS
if [ ! -f "$APP_GOVERNORS" ]; then
  touch "$APP_GOVERNORS"
fi
chmod 666 "$APP_GOVERNORS" 2>/dev/null

# Log current per-app governors on startup
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
  local cpu0="${CPU_BASE}/cpu0/cpufreq"
  
  log "🔧 Switching to: $target_gov"
  
  # Restore frequencies
  if [ -f "$STOCK_CONFIG_DIR/scaling_min_freq.txt" ]; then
    local stock_min=$(cat "$STOCK_CONFIG_DIR/scaling_min_freq.txt")
    echo "$stock_min" > $cpu0/scaling_min_freq 2>/dev/null
    log "  ├─ Min freq: $stock_min"
  fi
  if [ -f "$STOCK_CONFIG_DIR/scaling_max_freq.txt" ]; then
    local stock_max=$(cat "$STOCK_CONFIG_DIR/scaling_max_freq.txt")
    echo "$stock_max" > $cpu0/scaling_max_freq 2>/dev/null
    log "  ├─ Max freq: $stock_max"
  fi
  
  # Set governor
  echo "$target_gov" > $cpu0/scaling_governor 2>/dev/null
  log "  ├─ Governor: $target_gov"
  
  # Backup tunables if not done yet
  backup_governor_tunables "$target_gov"
  
  # Restore tunables
  local tunable_backup="$STOCK_CONFIG_DIR/$target_gov"
  if [ -d "$tunable_backup" ] && [ -f "$tunable_backup/.backup_done" ]; then
    local tunable_dir="$cpu0/${target_gov}"
    if [ -d "$tunable_dir" ]; then
      log "  ├─ Restoring tunables:"
      local restored=0
      for tunable_file in $(ls $tunable_backup 2>/dev/null); do
        [ "$tunable_file" = ".backup_done" ] && continue
        local target="$tunable_dir/$tunable_file"
        local source="$tunable_backup/$tunable_file"
        if [ -f "$target" ] && [ -w "$target" ] && [ -f "$source" ]; then
          local value=$(cat "$source" 2>/dev/null)
          cat "$source" > "$target" 2>/dev/null
          log "  │  • $tunable_file = $value"
          restored=$((restored + 1))
        fi
      done
      log "  └─ Restored $restored tunables"
    fi
  else
    log "  └─ No tunables to restore"
  fi
  
  # Apply to all cores
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

    # VALIDATION: Check conflict with game list (BEFORE setting!)
    if [ -f "$GAME_PACKAGES" ] && grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null; then
        log "❌ Conflict: Package exists in game list"
        return 1
    fi

    # Remove old entry if exists
    if [ -f "$APP_GOVERNORS" ] && grep -q "^${pkg}=" "$APP_GOVERNORS" 2>/dev/null; then
        grep -v "^${pkg}=" "$APP_GOVERNORS" > "${APP_GOVERNORS}.tmp" 2>/dev/null
        mv -f "${APP_GOVERNORS}.tmp" "$APP_GOVERNORS"
    fi
    
    # Add new entry
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
    log "╔═══════════════════════════════════════════════════╗"
    log "║  🗑️  REMOVE PER-APP GOVERNOR - ALWAYS PROCESS    ║"
    log "╚═══════════════════════════════════════════════════╝"
    log "📦 Target: $pkg"
    
    [ -z "$pkg" ] && {
        log "❌ Empty package"
        return 1
    }
    
    pkg=$(echo "$pkg" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # Ensure file exists
    if [ ! -f "$APP_GOVERNORS" ]; then
        touch "$APP_GOVERNORS"
        chmod 666 "$APP_GOVERNORS" 2>/dev/null
        log "📄 Created empty app_governors.txt"
    fi
    
    # Try to remove from file
    local was_in_file=0
    if grep -q "^${pkg}=" "$APP_GOVERNORS" 2>/dev/null; then
        was_in_file=1
        log "📄 Found in file:"
        grep "^${pkg}=" "$APP_GOVERNORS" >> $LOG 2>&1
        
        grep -v "^${pkg}=" "$APP_GOVERNORS" > "${APP_GOVERNORS}.tmp" 2>/dev/null
        mv -f "${APP_GOVERNORS}.tmp" "$APP_GOVERNORS"
        chmod 666 "$APP_GOVERNORS" 2>/dev/null
        sync
        sleep 0.2
        sync
        
        log "✅ Removed from file"
    else
        log "⚠️  Not in file (localStorage only or already removed)"
    fi
    
    # Always update JSON
    generate_app_governors_json
    
    # ============================================
    # CRITICAL: ALWAYS check if app is active
    # and reset governor if needed
    # ============================================
    local current_fg=$(get_foreground_app)
    log "🔍 Checking foreground: $current_fg"
    
    if [ "$current_fg" = "$pkg" ]; then
        log "╔═══════════════════════════════════════════════════╗"
        log "║  🚨 ACTIVE APP REMOVED - FORCE RESET NOW!        ║"
        log "╚═══════════════════════════════════════════════════╝"
        
        # ALWAYS reset to default, regardless of file state
        restore_governor_config "$DEFAULT_GOVERNOR"
        
        log "╔═══════════════════════════════════════════════════╗"
        log "║  ✅ RESET EXECUTED                                ║"
        log "║  💤 Mode: IDLE                                    ║"
        log "║  ⚙️  Governor: $DEFAULT_GOVERNOR                  ║"
        if [ $was_in_file -eq 1 ]; then
            log "║  📄 Source: Backend file                          ║"
        else
            log "║  📄 Source: Frontend cache                        ║"
        fi
        log "╚═══════════════════════════════════════════════════╝"
    else
        if [ $was_in_file -eq 1 ]; then
            log "✅ Removed (app not active)"
        else
            log "✅ Processed (was UI-only entry)"
        fi
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

  # Format validation
  echo "$pkg" | grep -Eq '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$' 2>/dev/null || return 1

  # VALIDATION #1: Check duplicate (BEFORE adding!)
  if grep -Fxq "$pkg" "$GAME_PACKAGES" 2>/dev/null; then
    log "⚠️ Duplicate: Package already in game list"
    generate_games_json
    return 1
  fi

  # VALIDATION #2: Check conflict with per-app (BEFORE adding!)
  if [ -f "$APP_GOVERNORS" ] && grep -q "^${pkg}=" "$APP_GOVERNORS" 2>/dev/null; then
    log "❌ Conflict: Package in per-app governor list"
    return 1
  fi

  # OK to add - validation passed
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

start_api_server() {
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
    printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n%s" \
      "${#RESPONSE}" "$RESPONSE" | nc -l -p $API_PORT -w 1 >/dev/null 2>&1 &
    sleep 0.3
  done
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
  # CRITICAL FIX: Always reload gaming governor from file
  local new_gaming_gov=$(cat "$GOVERNOR_PREF" 2>/dev/null | head -1 | tr -d '\r\n\t')
  if [ -n "$new_gaming_gov" ] && echo "$AVAILABLE_GOVERNORS" | grep -q "$new_gaming_gov"; then
    GAMING_GOVERNOR="$new_gaming_gov"
    log "🔄 Reloaded gaming governor from file: $GAMING_GOVERNOR"
  fi
  restore_governor_config "$GAMING_GOVERNOR"
  log "🎮 MODE: GAMING"
}

apply_powersave() {
  restore_governor_config "$DEFAULT_GOVERNOR"
  log "💤 MODE: IDLE"
}

apply_app_governor() {
  local app_gov="$1"
  restore_governor_config "$app_gov"
  log "🎯 MODE: PER-APP"
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

    # Check per-app governor FIRST (highest priority)
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
      
      if [ $app_counter -ge 2 ]; then
        should_apply_governor=1
      fi
      
    else
      # Priority 2: Game list
      is_game_running=0
      [ -n "$foreground" ] && is_game "$foreground" && is_game_running=1

      if [ $is_game_running -eq 1 ]; then
        target_state="gaming"
        target_governor="$GAMING_GOVERNOR"
        game_counter=$((game_counter + 1))
        idle_counter=0
        app_counter=0
        
        if [ $game_counter -ge 3 ]; then
          should_apply_governor=1
        fi
      else
        # Priority 3: Idle (default)
        target_state="idle"
        target_governor="$DEFAULT_GOVERNOR"
        idle_counter=$((idle_counter + 1))
        game_counter=0
        app_counter=0
        
        if [ $idle_counter -ge 3 ]; then
          should_apply_governor=1
        fi
      fi
    fi

    # Apply governor when threshold met
    if [ $should_apply_governor -eq 1 ]; then
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
log "================================================"

monitor_loop
