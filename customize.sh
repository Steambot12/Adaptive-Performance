#!/system/bin/sh

MODPATH=${0%/*}

ui_print " "
ui_print " ┼─┼─┼─┼─┼─┼─┼─┼─┼ "
ui_print " │A│d│a│p│t│i│v│e│ "
ui_print " ┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼"
ui_print " │P│e│r│f│o│r│m│a│n│c│e│"
ui_print " ┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼"
ui_print " │M│o│d│u│l│e│ v1.1"
ui_print " "
ui_print "Created by: Steambot12"
ui_print " "
ui_print "- Installing module..."
ui_print " "

# Detect stock governor
ui_print "- Detecting stock kernel governor..."
STOCK_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "")
if [ -n "$STOCK_GOV" ]; then
    echo "$STOCK_GOV" > "$MODPATH/default_governor.txt"
    chmod 644 "$MODPATH/default_governor.txt"
    ui_print " ✓ Stock governor: $STOCK_GOV"
else
    ui_print " ⚠ Could not detect governor, will use auto-detect"
fi
ui_print " "

# Set base permissions
ui_print "- Setting permissions..."
set_perm_recursive $MODPATH 0 0 0755 0644
set_perm $MODPATH/service.sh 0 0 0755

# Permissions untuk CLI commands
ui_print "- Setting CLI tools permissions..."

# Game List Management
set_perm $MODPATH/system/bin/adaptperf-add 0 0 0755
set_perm $MODPATH/system/bin/adaptperf-remove 0 0 0755
set_perm $MODPATH/system/bin/adaptperf-list 0 0 0755

# Governor Management
set_perm $MODPATH/system/bin/adaptperf-setgov 0 0 0755

# Per-App Governor Management (NEW)
set_perm $MODPATH/system/bin/adaptperf-setappgov 0 0 0755
set_perm $MODPATH/system/bin/adaptperf-delappgov 0 0 0755
set_perm $MODPATH/system/bin/adaptperf-listappgov 0 0 0755

# Status & Monitoring
set_perm $MODPATH/system/bin/adaptperf-status 0 0 0755

# Permissions untuk webroot
ui_print "- Setting webroot permissions..."
set_perm_recursive $MODPATH/webroot 0 0 0755 0644

ui_print " "
ui_print "✓ Module installed successfully!"
ui_print " "
ui_print "════════════════════════════════"
ui_print "Features:"
ui_print "• Auto-detect game apps"
ui_print "• Per-app custom governor support"
ui_print "• Adaptive CPU governor switching"
ui_print "• Power efficient idle mode"
ui_print "• Stock kernel thermal control"
ui_print "• Universal device support"
ui_print "• Web dashboard monitoring"
ui_print " "
ui_print "Dashboard access:"
ui_print "• URL: http://127.0.0.1:9876"
ui_print "• Command: adaptperf-status"
ui_print " "
ui_print "════════════════════════════════"
ui_print "CLI Commands:"
ui_print " "
ui_print "📦 Game List:"
ui_print "• adaptperf-add <pkg>"
ui_print "• adaptperf-remove <pkg>"
ui_print "• adaptperf-list"
ui_print " "
ui_print "⚙️  Governor:"
ui_print "• adaptperf-setgov <governor>"
ui_print " "
ui_print "🎯 Per-App Governor:"
ui_print "• adaptperf-setappgov <pkg> <gov>"
ui_print "• adaptperf-delappgov <pkg>"
ui_print "• adaptperf-listappgov"
ui_print " "
ui_print "📊 Status:"
ui_print "• adaptperf-status"
ui_print " "
ui_print "════════════════════════════════"
ui_print "Module will start after reboot."
ui_print " "
