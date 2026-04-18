#!/bin/bash
# battery-limiter.sh v11 -- battery charge limiter (40%-80%)
#
# State machine:
#   monitor          -- 5-min ticks, read-only observation
#   charge_recovery  -- infinite loop: toggle 0 and step 500mA..1A..driver until Charging
#   charge_tuning    -- find minimum current_max that sustains Charging
#   pause_recovery   -- infinite loop: write 0 every 10s until Discharging
#
# temp_lock flag blocks all charging scenarios until temp < 40.0C.
#
# Sensing: one battery gauge node (capacity, temp, status, current_now).
# Control: one charger current_max node.
# All constants and sysfs paths may be overridden via environment.
set -uo pipefail

# --- Constants ---
CAP_LOW="${CAP_LOW:-40}"
CAP_HIGH="${CAP_HIGH:-80}"
TEMP_LOCK_ENTER="${TEMP_LOCK_ENTER:-450}"      # 45.0C in tenths
TEMP_LOCK_EXIT="${TEMP_LOCK_EXIT:-400}"        # 40.0C in tenths
TICK_INTERVAL="${TICK_INTERVAL:-300}"          # 5 minutes
RETRY_INTERVAL="${RETRY_INTERVAL:-10}"         # recovery loop step
TUNING_SETTLE="${TUNING_SETTLE:-30}"           # wait after setting limited current
CURRENT_OFF="${CURRENT_OFF:-0}"
CURRENT_START="${CURRENT_START:-500000}"       # 500 mA
CURRENT_STEP="${CURRENT_STEP:-100000}"         # 100 mA
CURRENT_CEIL="${CURRENT_CEIL:-1000000}"        # 1 A
CURRENT_DRIVER="${CURRENT_DRIVER:-4800000}"    # full driver control

# --- Sysfs paths ---
BATTERY_GAUGE_BASE_PATH="${BATTERY_GAUGE_BASE_PATH:-}"
SYS_CAP="${SYS_CAP:-}"
SYS_TEMP="${SYS_TEMP:-}"
SYS_BQST="${SYS_BQST:-}"
SYS_CUR="${SYS_CUR:-}"
SYS_CMAX="${SYS_CMAX:-${CHARGER_CURRENT_MAX_PATH:-}}"

# --- State ---
STATE="monitor"
TEMP_LOCK=0

# ===================================================================
# Logging
# ===================================================================
# Format: TIMESTAMP LEVEL [STATE] CONTEXT: message key=value ...

log_info()  { echo "$(date '+%Y-%m-%d %H:%M:%S') INFO  [${STATE}] $1"; }
log_warn()  { echo "$(date '+%Y-%m-%d %H:%M:%S') WARN  [${STATE}] $1"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR [${STATE}] $1"; }

detect_battery_gauge_base_path() {
    local candidate

    if [ -n "${BATTERY_GAUGE_BASE_PATH:-}" ]; then
        echo "$BATTERY_GAUGE_BASE_PATH"
        return 0
    fi

    for candidate in /sys/class/power_supply/*; do
        if [ -e "$candidate/capacity" ] && [ -e "$candidate/temp" ] && [ -e "$candidate/status" ] && [ -e "$candidate/current_now" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

resolve_battery_gauge_paths() {
    local base_path="${BATTERY_GAUGE_BASE_PATH:-}"

    if [ -n "${SYS_CAP:-}" ] && [ -n "${SYS_TEMP:-}" ] && [ -n "${SYS_BQST:-}" ] && [ -n "${SYS_CUR:-}" ]; then
        return 0
    fi

    if [ -z "$base_path" ]; then
        base_path=$(detect_battery_gauge_base_path) || return 1
    fi

    BATTERY_GAUGE_BASE_PATH="$base_path"
    SYS_CAP="${SYS_CAP:-$base_path/capacity}"
    SYS_TEMP="${SYS_TEMP:-$base_path/temp}"
    SYS_BQST="${SYS_BQST:-$base_path/status}"
    SYS_CUR="${SYS_CUR:-$base_path/current_now}"
    export BATTERY_GAUGE_BASE_PATH SYS_CAP SYS_TEMP SYS_BQST SYS_CUR
    return 0
}

detect_current_max_path() {
    local candidate

    if [ -n "${SYS_CMAX:-}" ]; then
        echo "$SYS_CMAX"
        return 0
    fi

    if [ -n "${CHARGER_CURRENT_MAX_PATH:-}" ]; then
        echo "$CHARGER_CURRENT_MAX_PATH"
        return 0
    fi

    for candidate in /sys/class/power_supply/*/current_max; do
        if [ -e "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

resolve_current_max_path() {
    local detected

    detected=$(detect_current_max_path) || return 1
    SYS_CMAX="$detected"
    CHARGER_CURRENT_MAX_PATH="$detected"
    export SYS_CMAX CHARGER_CURRENT_MAX_PATH
    return 0
}

# ===================================================================
# Sysfs read helpers
# ===================================================================
read_cap() {
    local v
    if v=$(cat "$SYS_CAP" 2>/dev/null); then
        echo "$v"
    else
        log_error "sysfs_read: failed to read capacity"
        return 1
    fi
}

read_temp() {
    local v
    if v=$(cat "$SYS_TEMP" 2>/dev/null); then
        echo "$v"
    else
        log_error "sysfs_read: failed to read temp"
        return 1
    fi
}

read_bqst() {
    local v
    if v=$(cat "$SYS_BQST" 2>/dev/null); then
        echo "$v"
    else
        log_error "sysfs_read: failed to read bq status"
        return 1
    fi
}

read_cur() {
    local v
    if v=$(cat "$SYS_CUR" 2>/dev/null); then
        echo "$v"
    else
        log_error "sysfs_read: failed to read current_now"
        return 1
    fi
}

# ===================================================================
# Sysfs write helper
# ===================================================================
write_cmax() {
    local val="$1" reason="$2"
    if echo "$val" > "$SYS_CMAX" 2>/tmp/cmax_err; then
        log_info "write_cmax: wrote current_max=${val} reason=\"${reason}\""
    else
        log_error "write_cmax: failed to write current_max=${val} reason=\"${reason}\" err=$(cat /tmp/cmax_err 2>/dev/null)"
    fi
}

# ===================================================================
# Format helpers
# ===================================================================
fmt_temp() { echo "$((${1}/10)).$((${1}%10))C"; }

log_tick() {
    local cap="$1" temp="$2" bqst="$3" cur="$4"
    log_info "tick: cap=${cap}% temp=$(fmt_temp "$temp") bq=${bqst} cur=${cur}uA temp_lock=${TEMP_LOCK}"
}

# ===================================================================
# charge_recovery
# Infinite loop: for each cycle, try a toggle-wake ladder
#   0 -> 500mA -> 0 -> 600mA -> ... -> 1A -> 0 -> driver-control
# until bq=Charging.  This avoids assuming the driver wakes only from
# a repeated large current_max write.
# ===================================================================
do_charge_recovery() {
    local prev_state="$STATE"
    STATE="charge_recovery"
    log_info "ENTER charge_recovery"

    local cycle=0
    while true; do
        cycle=$((cycle + 1))

        local target="$CURRENT_START"
        while true; do
            write_cmax "$CURRENT_OFF" "charge_recovery cycle ${cycle} toggle-off before ${target}uA"
            sleep 2
            write_cmax "$target" "charge_recovery cycle ${cycle} toggle-on ${target}uA"
            sleep "$RETRY_INTERVAL"

            local bqst
            bqst=$(read_bqst) || break
            if [ "$bqst" = "Charging" ]; then
                log_info "charge_recovery: Charging detected after cycle ${cycle} at ${target}uA"
                STATE="$prev_state"
                return 0
            fi

            local cur
            cur=$(read_cur 2>/dev/null) || cur="?"
            log_warn "charge_recovery: bq=${bqst} cur=${cur}uA after cycle ${cycle} target=${target}uA -- continuing ladder"

            if [ "$target" -lt "$CURRENT_CEIL" ]; then
                target=$((target + CURRENT_STEP))
                continue
            fi
            if [ "$target" -ne "$CURRENT_DRIVER" ]; then
                target="$CURRENT_DRIVER"
                continue
            fi
            break
        done

        log_warn "charge_recovery: cycle ${cycle} exhausted without Charging -- restarting ladder"
    done
}

# ===================================================================
# charge_tuning
# Start at 500mA, if Charging lost raise by 100mA up to 1A.
# If 1A fails, write CURRENT_DRIVER and return.
# ===================================================================
do_charge_tuning() {
    local prev_state="$STATE"
    STATE="charge_tuning"
    log_info "ENTER charge_tuning"

    local limit="$CURRENT_START"

    write_cmax "$limit" "charge_tuning start at ${limit}uA"
    sleep "$TUNING_SETTLE"

    local bqst
    bqst=$(read_bqst) || { STATE="$prev_state"; return 1; }

    if [ "$bqst" = "Charging" ]; then
        log_info "charge_tuning: Charging holds at ${limit}uA -- success"
        STATE="$prev_state"
        return 0
    fi

    log_warn "charge_tuning: Charging lost at ${limit}uA (bq=${bqst}) -- escalating"

    while [ "$limit" -lt "$CURRENT_CEIL" ]; do
        limit=$((limit + CURRENT_STEP))
        write_cmax "$limit" "charge_tuning escalate to ${limit}uA"
        sleep "$RETRY_INTERVAL"

        bqst=$(read_bqst) || continue
        if [ "$bqst" = "Charging" ]; then
            log_info "charge_tuning: Charging holds at ${limit}uA -- success"
            STATE="$prev_state"
            return 0
        fi
        log_warn "charge_tuning: Charging lost at ${limit}uA (bq=${bqst}) -- raising"
    done

    # Ceiling reached and still no Charging -- give driver full control
    write_cmax "$CURRENT_DRIVER" "charge_tuning: ceiling ${CURRENT_CEIL}uA failed, giving driver full control"
    log_warn "charge_tuning: unable to sustain Charging up to ${CURRENT_CEIL}uA -- driver has control"
    STATE="$prev_state"
    return 1
}

# ===================================================================
# pause_recovery
# Infinite loop: write 0 every 10s until bq=Discharging.
# ===================================================================
do_pause_recovery() {
    local prev_state="$STATE"
    STATE="pause_recovery"
    local reason="$1"
    log_info "ENTER pause_recovery reason=\"${reason}\""

    local attempt=0
    while true; do
        attempt=$((attempt + 1))
        write_cmax "$CURRENT_OFF" "pause_recovery attempt ${attempt}"
        sleep "$RETRY_INTERVAL"

        local bqst
        bqst=$(read_bqst) || continue
        if [ "$bqst" = "Discharging" ]; then
            log_info "pause_recovery: Discharging confirmed after ${attempt} attempt(s)"
            STATE="$prev_state"
            return 0
        fi
        local cur
        cur=$(read_cur 2>/dev/null) || cur="?"
        log_warn "pause_recovery: bq=${bqst} cur=${cur}uA after attempt ${attempt} -- retrying"
    done
}

# ===================================================================
# Wait for required sysfs nodes
# ===================================================================
wait_for_required_nodes() {
    while true; do
        local missing=""
        local node
        local gauge_ready=0
        local current_max_ready=0

        if resolve_battery_gauge_paths; then
            gauge_ready=1
        else
            missing="${missing} <auto-detect battery gauge>"
        fi

        if resolve_current_max_path; then
            current_max_ready=1
        else
            missing="${missing} <auto-detect current_max>"
        fi

        for node in "$SYS_CAP" "$SYS_TEMP" "$SYS_BQST" "$SYS_CUR" "$SYS_CMAX"; do
            if [ "$gauge_ready" -ne 1 ] && { [ "$node" = "$SYS_CAP" ] || [ "$node" = "$SYS_TEMP" ] || [ "$node" = "$SYS_BQST" ] || [ "$node" = "$SYS_CUR" ]; }; then
                continue
            fi
            if [ "$node" = "$SYS_CMAX" ] && [ "$current_max_ready" -ne 1 ]; then
                continue
            fi
            if [ ! -e "$node" ]; then
                missing="${missing} ${node}"
            fi
        done

        if [ -z "$missing" ]; then
            return 0
        fi

        STATE="init"
        log_warn "waiting for sysfs nodes:${missing}"
        sleep "$RETRY_INTERVAL"
    done
}

wait_for_required_nodes

STATE="monitor"
log_info "=== battery-limiter v11 starting ==="
log_info "config: CAP_LOW=${CAP_LOW}% CAP_HIGH=${CAP_HIGH}% TEMP_LOCK_ENTER=$(fmt_temp $TEMP_LOCK_ENTER) TEMP_LOCK_EXIT=$(fmt_temp $TEMP_LOCK_EXIT)"
log_info "config: TICK=${TICK_INTERVAL}s RETRY=${RETRY_INTERVAL}s TUNING_SETTLE=${TUNING_SETTLE}s"
log_info "config: CURRENT_START=${CURRENT_START} CURRENT_STEP=${CURRENT_STEP} CURRENT_CEIL=${CURRENT_CEIL} CURRENT_DRIVER=${CURRENT_DRIVER}"
log_info "config: BATTERY_GAUGE_BASE_PATH=${BATTERY_GAUGE_BASE_PATH}"
log_info "config: SYS_CAP=${SYS_CAP} SYS_TEMP=${SYS_TEMP} SYS_BQST=${SYS_BQST} SYS_CUR=${SYS_CUR}"
log_info "config: SYS_CMAX=${SYS_CMAX}"

# ===================================================================
# Main tick loop
# First tick runs immediately at startup.
# ===================================================================
FIRST_TICK=1

while true; do
    if [ "$FIRST_TICK" = "1" ]; then
        FIRST_TICK=0
    else
        sleep "$TICK_INTERVAL"
    fi

    # --- §5.1: Read and log current state ---
    CAP=$(read_cap)    || continue
    TEMP=$(read_temp)  || continue
    BQST=$(read_bqst)  || continue
    CUR=$(read_cur)    || CUR="?"

    log_tick "$CAP" "$TEMP" "$BQST" "$CUR"

    # --- §5.2: Temperature protection has priority ---
    if [ "$TEMP" -ge "$TEMP_LOCK_ENTER" ]; then
        if [ "$TEMP_LOCK" = "0" ]; then
            TEMP_LOCK=1
            log_warn "temp_lock: ACTIVATED at $(fmt_temp "$TEMP") >= $(fmt_temp $TEMP_LOCK_ENTER)"
        fi
        # Always run pause_recovery when entering/in temp_lock and overheating
        if [ "$BQST" != "Discharging" ]; then
            do_pause_recovery "temp_lock (temp=$(fmt_temp "$TEMP"))"
        else
            log_info "temp_lock: already Discharging at $(fmt_temp "$TEMP") -- no action"
        fi
        continue
    fi

    if [ "$TEMP_LOCK" = "1" ]; then
        # temp < TEMP_LOCK_ENTER but check if below exit threshold
        if [ "$TEMP" -lt "$TEMP_LOCK_EXIT" ]; then
            TEMP_LOCK=0
            log_info "temp_lock: DEACTIVATED at $(fmt_temp "$TEMP") < $(fmt_temp $TEMP_LOCK_EXIT) -- deferring to next tick"
            continue
        else
            # Still in temp_lock zone (>= 40.0C but < 45.0C)
            log_info "temp_lock: still active at $(fmt_temp "$TEMP") (exit requires < $(fmt_temp $TEMP_LOCK_EXIT))"
            if [ "$BQST" != "Discharging" ]; then
                do_pause_recovery "temp_lock hold (temp=$(fmt_temp "$TEMP"))"
            fi
            continue
        fi
    fi

    # --- §5.3: Capacity-based decisions (no temp_lock) ---
    if [ "$CAP" -lt "$CAP_LOW" ]; then
        # --- §6: Low battery workflow ---
        log_info "low_battery: cap=${CAP}% < ${CAP_LOW}% -- entering charge workflow"

        if [ "$BQST" != "Charging" ]; then
            do_charge_recovery
        else
            log_info "low_battery: already Charging -- skipping charge_recovery"
        fi
        do_charge_tuning
        continue
    fi

    if [ "$CAP" -gt "$CAP_HIGH" ]; then
        # --- §7: High battery workflow ---
        log_info "high_battery: cap=${CAP}% > ${CAP_HIGH}% -- entering pause workflow"

        if [ "$BQST" = "Discharging" ]; then
            log_info "high_battery: already Discharging -- no action"
        else
            do_pause_recovery "high_battery (cap=${CAP}%)"
        fi
        continue
    fi

    # --- §9: In range 40%-80%, no temp_lock ---
    log_info "in_range: cap=${CAP}% in [${CAP_LOW}%..${CAP_HIGH}%] -- no action"
done
