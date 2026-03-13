#!/bin/bash
# cacheout-watchdog.sh — Rate-of-change system pressure monitor for Cacheout
# Part of the Cacheout macOS app — NOT the MCP server
#
# Detects rapid disk/swap deterioration and triggers emergency cleanup
# via `Cacheout --cli smart-clean`. Writes alert sentinel for optional
# agent pickup via cacheout-mcp.
#
# Install: launchctl load ~/Library/LaunchAgents/com.cacheout.watchdog.plist
# Logs:    ~/.cacheout/watchdog.log
# Alerts:  ~/.cacheout/alert.json (read by cacheout-mcp Tier 2)

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
CACHEOUT_DIR="$HOME/.cacheout"
HISTORY_FILE="$CACHEOUT_DIR/watchdog-history.json"
ALERT_FILE="$CACHEOUT_DIR/alert.json"
LOG_FILE="$CACHEOUT_DIR/watchdog.log"

# Binary discovery: built product, app bundle, or PATH
find_cacheout_binary() {
    local candidates=(
        "$HOME/Documents/GitHub/cacheout/.build/debug/Cacheout"
        "$HOME/Documents/GitHub/cacheout/.build/release/Cacheout"
        "/Applications/Cacheout.app/Contents/MacOS/Cacheout"
        "$HOME/Applications/Cacheout.app/Contents/MacOS/Cacheout"
    )
    for bin in "${candidates[@]}"; do
        [[ -x "$bin" ]] && echo "$bin" && return
    done
    command -v Cacheout 2>/dev/null || echo ""
}

CACHEOUT_BIN=$(find_cacheout_binary)

# ─── Thresholds ──────────────────────────────────────────────────────────────

# Rate-of-change (over 5-minute rolling window)
DISK_DROP_RATE_GB=5        # Alert if disk drops > 5 GB in 5 min
SWAP_RISE_RATE_GB=3        # Alert if swap grows > 3 GB in 5 min

# Hard floors (absolute — emergency regardless of rate)
DISK_FLOOR_GB=5            # Below this = immediate cleanup
SWAP_CEILING_GB=40         # Above this = dangerously overcommitted

# Cleanup
SAFE_CLEAN_TARGET_GB=15    # Target GB to free in emergency
MAX_SAMPLES=10             # Rolling window: 10 × 30s = 5 min
STALE_ALERT_SEC=600        # Clear alerts older than 10 min

# ─── Helpers ─────────────────────────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

ensure_dirs() {
    mkdir -p "$CACHEOUT_DIR"
    # Rotate log at 1 MB
    if [[ -f "$LOG_FILE" ]] && (( $(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0) > 1048576 )); then
        mv "$LOG_FILE" "$LOG_FILE.old"
    fi
}

bytes_to_gb() {
    awk "BEGIN {printf \"%.2f\", $1 / 1073741824}"
}

# ─── System Sampling ─────────────────────────────────────────────────────────
get_disk_free_bytes() {
    df -k / | awk 'NR==2 {print $4 * 1024}'
}

get_swap_used_bytes() {
    /usr/sbin/sysctl vm.swapusage 2>/dev/null | awk '{
        for (i=1; i<=NF; i++) {
            if ($i == "used") {
                val = $(i+2)
                # Parse numeric value and unit suffix (K/M/G/T)
                unit = substr(val, length(val))
                gsub(/[KMGT]/, "", val)
                if (unit == "K") mult = 1024
                else if (unit == "M") mult = 1048576
                else if (unit == "G") mult = 1073741824
                else if (unit == "T") mult = 1099511627776
                else mult = 1048576  # default to M for bare numbers
                printf "%.0f", val * mult
                exit
            }
        }
    }'
}

get_compressor_ratio() {
    # compressor_compressed_bytes = logical/original data submitted to compressor
    # compressor_bytes_used       = physical storage used by compressor
    # ratio = logical / physical; >1 means compression is effective
    local logical_bytes physical_bytes
    logical_bytes=$(/usr/sbin/sysctl -n vm.compressor_compressed_bytes 2>/dev/null || echo 0)
    physical_bytes=$(/usr/sbin/sysctl -n vm.compressor_bytes_used 2>/dev/null || echo 0)
    if (( physical_bytes > 0 )); then
        awk "BEGIN {printf \"%.2f\", $logical_bytes / $physical_bytes}"
    else
        echo "0.00"
    fi
}

bytes_to_mb() {
    awk "BEGIN {printf \"%.2f\", $1 / 1048576}"
}

get_memory_pressure() {
    if [[ -x /usr/bin/memory_pressure ]]; then
        local out
        out=$(/usr/bin/memory_pressure 2>/dev/null | head -1 || echo "")
        case "$out" in
            *normal*)  echo "normal" ;;
            *warn*)    echo "warn" ;;
            *critical*) echo "critical" ;;
            *)         echo "unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

# ─── History (JSON via python3) ───────────────────────────────────────────────
append_and_read_history() {
    local ts="$1" disk_bytes="$2" swap_bytes="$3" pressure="$4"
    python3 << PYEOF
import json, os

path = "$HISTORY_FILE"
max_samples = $MAX_SAMPLES

try:
    with open(path) as f:
        history = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    history = []

history.append({
    "ts": $ts,
    "disk_bytes": $disk_bytes,
    "swap_bytes": $swap_bytes,
    "pressure": "$pressure"
})

history = history[-max_samples:]

with open(path, "w") as f:
    json.dump(history, f)

print(json.dumps(history))
PYEOF
}

# ─── Velocity Detection ─────────────────────────────────────────────────────
check_velocity() {
    local current_disk="$1" current_swap="$2" history_json="$3"
    python3 << PYEOF
import json, time

history = json.loads('''$history_json''')
current_disk = $current_disk
current_swap = $current_swap
now = time.time()

if len(history) < 3:
    print("BUILDING_BASELINE")
    exit()

oldest = history[0]
time_delta_sec = now - oldest["ts"]
if time_delta_sec < 60:
    print("TOO_SOON")
    exit()

time_delta_min = time_delta_sec / 60.0

# Positive = deteriorating
disk_delta_gb = (oldest["disk_bytes"] - current_disk) / 1073741824
swap_delta_gb = (current_swap - oldest["swap_bytes"]) / 1073741824

# Normalize to 5-minute rate
rate_factor = 5.0 / time_delta_min
disk_rate = disk_delta_gb * rate_factor
swap_rate = swap_delta_gb * rate_factor

triggers = []
if disk_rate > $DISK_DROP_RATE_GB:
    triggers.append(f"disk_velocity:{disk_rate:.1f}gb_per_5m")
if swap_rate > $SWAP_RISE_RATE_GB:
    triggers.append(f"swap_velocity:{swap_rate:.1f}gb_per_5m")

if triggers:
    print(f"ALERT|{','.join(triggers)}|disk_rate={disk_rate:.2f}|swap_rate={swap_rate:.2f}")
else:
    print(f"OK|disk_rate={disk_rate:.2f}|swap_rate={swap_rate:.2f}")
PYEOF
}

# ─── Emergency Cleanup (Tier 1) ─────────────────────────────────────────────
run_emergency_cleanup() {
    local reason="$1"
    log "EMERGENCY CLEANUP: $reason"

    # Prefer Cacheout CLI binary
    if [[ -n "$CACHEOUT_BIN" ]] && [[ -x "$CACHEOUT_BIN" ]]; then
        log "Cleaning via: $CACHEOUT_BIN --cli smart-clean --target $SAFE_CLEAN_TARGET_GB"
        local result
        result=$("$CACHEOUT_BIN" --cli smart-clean --target "$SAFE_CLEAN_TARGET_GB" 2>&1) || true
        log "Result: $result"
        echo "$result"
        return
    fi

    # Fallback: direct safe cleanup (no binary available)
    log "No Cacheout binary found — manual safe cleanup"
    local freed_kb=0

    # Xcode DerivedData (always safe, often huge)
    if [[ -d "$HOME/Library/Developer/Xcode/DerivedData" ]]; then
        local sz
        sz=$(du -sk "$HOME/Library/Developer/Xcode/DerivedData" 2>/dev/null | awk '{print $1}')
        rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/* 2>/dev/null || true
        freed_kb=$((freed_kb + ${sz:-0}))
        log "  Cleared DerivedData: ${sz:-0}KB"
    fi

    # Homebrew cache
    if command -v brew &>/dev/null; then
        brew cleanup --prune=0 2>/dev/null || true
        log "  Ran brew cleanup"
    fi

    # npm cache
    if command -v npm &>/dev/null; then
        npm cache clean --force 2>/dev/null || true
        log "  Cleaned npm cache"
    fi

    log "Manual cleanup freed ~${freed_kb}KB"
    echo "{\"freed_kb\": $freed_kb, \"method\": \"manual_fallback\"}"
}

# ─── Alert Sentinel ─────────────────────────────────────────────────────────
write_alert() {
    local level="$1" triggers="$2" disk_gb="$3" swap_gb="$4" pressure="$5"
    local cleanup_result="${6:-null}"
    local compressor_ratio="$7" swap_used_mb="$8"
    local target=$( [[ "$level" == "emergency" ]] && echo "20.0" || echo "15.0" )

    CLEANUP_JSON="$cleanup_result" python3 << PYEOF
import json, os, time

_raw = os.environ.get("CLEANUP_JSON", "")
try:
    cleanup = json.loads(_raw) if _raw and _raw != "null" else None
except (json.JSONDecodeError, TypeError):
    cleanup = None

alert = {
    "triggered_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "level": "$level",
    "triggers": "$triggers".split(","),
    "disk_free_gb": float("$disk_gb"),
    "swap_used_gb": float("$swap_gb"),
    "memory_pressure": "$pressure",
    "compressor_ratio": float("$compressor_ratio"),
    "swap_used_mb": float("$swap_used_mb"),
    "recommended_action": "smart_clean",
    "recommended_target_gb": $target,
    "cleanup_performed": "$level" == "emergency",
    "cleanup_result": cleanup
}

with open("$ALERT_FILE", "w") as f:
    json.dump(alert, f, indent=2)
PYEOF

    log "Alert sentinel written: level=$level triggers=$triggers"
}

clear_stale_alert() {
    [[ ! -f "$ALERT_FILE" ]] && return
    local age
    age=$(python3 -c "
import json, datetime
try:
    with open('$ALERT_FILE') as f:
        a = json.load(f)
    t = datetime.datetime.fromisoformat(a['triggered_at'].replace('Z','+00:00'))
    print(int((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds()))
except:
    print(0)
" 2>/dev/null)
    if (( ${age:-0} > STALE_ALERT_SEC )); then
        rm -f "$ALERT_FILE"
        log "Cleared stale alert (${age}s old)"
    fi
}

# ─── Main ──────────────────────────────────────────────────────────────────────
main() {
    ensure_dirs

    local now disk_bytes swap_bytes pressure disk_gb swap_gb compressor_ratio swap_used_mb
    now=$(date +%s)
    disk_bytes=$(get_disk_free_bytes)
    swap_bytes=$(get_swap_used_bytes)
    pressure=$(get_memory_pressure)
    disk_gb=$(bytes_to_gb "$disk_bytes")
    swap_gb=$(bytes_to_gb "$swap_bytes")
    compressor_ratio=$(get_compressor_ratio)
    swap_used_mb=$(bytes_to_mb "$swap_bytes")

    # ── Hard Floor Check (Tier 1) ──
    local floor_hit=false
    local floor_triggers=""

    if (( $(echo "$disk_gb < $DISK_FLOOR_GB" | bc -l) )); then
        floor_hit=true
        floor_triggers="disk_floor:${disk_gb}gb"
    fi

    if (( $(echo "$swap_gb > $SWAP_CEILING_GB" | bc -l) )); then
        floor_hit=true
        floor_triggers="${floor_triggers:+$floor_triggers,}swap_ceiling:${swap_gb}gb"
    fi

    if [[ "$pressure" == "critical" ]]; then
        floor_hit=true
        floor_triggers="${floor_triggers:+$floor_triggers,}memory_critical"
    fi

    if [[ "$floor_hit" == true ]]; then
        log "HARD FLOOR HIT: $floor_triggers | disk=${disk_gb}GB swap=${swap_gb}GB pressure=$pressure"
        local cleanup_result
        cleanup_result=$(run_emergency_cleanup "$floor_triggers")
        write_alert "emergency" "$floor_triggers" "$disk_gb" "$swap_gb" "$pressure" "$cleanup_result" "$compressor_ratio" "$swap_used_mb"

        # Re-sample post-cleanup
        disk_bytes=$(get_disk_free_bytes)
        swap_bytes=$(get_swap_used_bytes)
    fi

    # ── Record sample + check velocity ──
    local history_json
    history_json=$(append_and_read_history "$now" "$disk_bytes" "$swap_bytes" "$pressure")

    if [[ "$floor_hit" == false ]]; then
        local velocity
        velocity=$(check_velocity "$disk_bytes" "$swap_bytes" "$history_json")

        case "$velocity" in
            ALERT*)
                local triggers
                triggers=$(echo "$velocity" | cut -d'|' -f2)
                log "VELOCITY ALERT: $triggers | disk=${disk_gb}GB swap=${swap_gb}GB"
                write_alert "warning" "$triggers" "$disk_gb" "$swap_gb" "$pressure" "null" "$compressor_ratio" "$swap_used_mb"
                ;;
            OK*)
                clear_stale_alert
                ;;
        esac
    fi
}

main "$@"
