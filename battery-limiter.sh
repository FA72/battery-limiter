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
RECOVERY_OFF_DWELL="${RECOVERY_OFF_DWELL:-3}"  # off-time before a wake attempt
RECOVERY_PRIME="${RECOVERY_PRIME:-$CURRENT_CEIL}"
RECOVERY_PRIME_SETTLE="${RECOVERY_PRIME_SETTLE:-15}"
RECOVERY_BOOST="${RECOVERY_BOOST:-$CURRENT_DRIVER}"
RECOVERY_BOOST_SETTLE="${RECOVERY_BOOST_SETTLE:-12}"
# Escalation when the ladder cannot wake the charger IC.
# Cycle 1 is plain (just the ladder); starting at cycle ESCALATE_REBIND_AT we
# escalate to a charger-driver rebind. Rebinding is safe and reliable on
# kernels with the DKMS charger fix installed; see kernel-patch/README.md for
# the public install notes for sdm845 / PMI8998.
REBIND_OFF_DWELL="${REBIND_OFF_DWELL:-3}"          # pause between unbind and bind
REBIND_SETTLE="${REBIND_SETTLE:-15}"               # max wait for current_max to reappear
ESCALATE_REBIND_AT="${ESCALATE_REBIND_AT:-2}"      # cycle at which to start driver rebind kicks

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

# Resolve the charger's underlying device + driver paths so we can unbind/rebind
# when the IC gets stuck. Populates CHARGER_PS_DIR, CHARGER_DEVICE_PATH,
# CHARGER_DRIVER_PATH, CHARGER_DEVICE_NAME from SYS_CMAX on every call so the
# lookup survives a rebind (where the underlying symlinks are recreated).
#
# It also resolves the PARENT bus device (e.g. the SPMI PMIC that owns the
# charger platform device). On some kernels (notably qcom_pmi8998_charger on
# sdm845) the platform driver's .remove() leaks the wake IRQ, so platform-level
# rebind is stuck with -EEXIST forever. Rebinding the parent bus device
# destroys and recreates the platform child cleanly and bypasses that bug.
resolve_charger_driver_paths() {
    [ -n "${SYS_CMAX:-}" ] || return 1
    CHARGER_PS_DIR=$(dirname "$SYS_CMAX")
    local dev_link="$CHARGER_PS_DIR/device"
    local drv_link="$CHARGER_PS_DIR/device/driver"
    [ -L "$dev_link" ] || return 1
    [ -L "$drv_link" ] || return 1
    CHARGER_DEVICE_PATH=$(readlink -f "$dev_link") || return 1
    CHARGER_DRIVER_PATH=$(readlink -f "$drv_link") || return 1
    CHARGER_DEVICE_NAME=$(basename "$CHARGER_DEVICE_PATH")

    # Resolve the parent bus device (one level up in /sys/devices hierarchy).
    # If that parent is itself bound to a driver, expose it as a fallback
    # rebind target.
    CHARGER_PARENT_DEVICE_PATH=""
    CHARGER_PARENT_DRIVER_PATH=""
    CHARGER_PARENT_DEVICE_NAME=""
    local parent
    parent=$(dirname "$CHARGER_DEVICE_PATH")
    if [ -L "$parent/driver" ]; then
        CHARGER_PARENT_DEVICE_PATH="$parent"
        CHARGER_PARENT_DRIVER_PATH=$(readlink -f "$parent/driver") || CHARGER_PARENT_DRIVER_PATH=""
        CHARGER_PARENT_DEVICE_NAME=$(basename "$parent")
    fi
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
# Driver-level wake primitive
#
# Used when the charger IC has latched into "Not charging" and no longer
# reacts to current_max writes. Safe to call with the cable plugged in and
# without rebooting, as long as the driver's wake-IRQ handling is correct
# on unbind (see kernel-patch/README.md for the sdm845 / PMI8998 fix).
# ===================================================================

kick_via_driver_rebind() {
    if ! resolve_charger_driver_paths; then
        log_warn "kick_rebind: unable to resolve charger driver path from SYS_CMAX=${SYS_CMAX}"
        return 1
    fi

    # Strategy: the platform driver may refuse to re-bind (on some kernels it
    # leaks resources in .remove() and returns -EEXIST forever). So we prefer
    # a parent-bus rebind when available: unbind the PARENT (e.g. the SPMI
    # PMIC) which destroys the platform child cleanly, then re-bind the
    # parent which re-creates the child and lets it probe from scratch.
    # We fall back to platform-level rebind only if no parent is usable.
    local did_any=1
    local err

    if [ -n "$CHARGER_PARENT_DRIVER_PATH" ] \
       && [ -e "$CHARGER_PARENT_DRIVER_PATH/unbind" ] \
       && [ -e "$CHARGER_PARENT_DRIVER_PATH/bind" ]; then
        log_warn "kick_rebind: parent unbind device=${CHARGER_PARENT_DEVICE_NAME} driver=${CHARGER_PARENT_DRIVER_PATH}"
        if echo "$CHARGER_PARENT_DEVICE_NAME" > "$CHARGER_PARENT_DRIVER_PATH/unbind" 2>/tmp/rebind_err; then
            sleep "$REBIND_OFF_DWELL"
            log_info "kick_rebind: parent bind device=${CHARGER_PARENT_DEVICE_NAME}"
            if echo "$CHARGER_PARENT_DEVICE_NAME" > "$CHARGER_PARENT_DRIVER_PATH/bind" 2>/tmp/rebind_err; then
                did_any=0
            else
                err=$(cat /tmp/rebind_err 2>/dev/null)
                log_error "kick_rebind: parent bind failed err=${err}"
            fi
        else
            err=$(cat /tmp/rebind_err 2>/dev/null)
            log_warn "kick_rebind: parent unbind failed err=${err} -- falling back to platform rebind"
        fi
    fi

    if [ "$did_any" -ne 0 ]; then
        # Fall back to platform-level rebind.
        local unbind="$CHARGER_DRIVER_PATH/unbind"
        local bind="$CHARGER_DRIVER_PATH/bind"
        local name="$CHARGER_DEVICE_NAME"

        if [ ! -e "$unbind" ] || [ ! -e "$bind" ]; then
            log_warn "kick_rebind: platform bind/unbind nodes missing (driver=${CHARGER_DRIVER_PATH})"
        else
            log_warn "kick_rebind: platform unbind device=${name} driver=${CHARGER_DRIVER_PATH}"
            if echo "$name" > "$unbind" 2>/tmp/rebind_err; then
                sleep "$REBIND_OFF_DWELL"
                log_info "kick_rebind: platform bind device=${name}"
                if echo "$name" > "$bind" 2>/tmp/rebind_err; then
                    did_any=0
                else
                    err=$(cat /tmp/rebind_err 2>/dev/null)
                    log_error "kick_rebind: platform bind failed err=${err} (driver may leak resources on remove)"
                fi
            else
                err=$(cat /tmp/rebind_err 2>/dev/null)
                log_error "kick_rebind: platform unbind failed err=${err}"
            fi
        fi
    fi

    # Wait for current_max to reappear. After a successful rebind the sysfs
    # path is usually identical, but give the driver a chance to re-publish.
    local waited=0
    while [ ! -e "$SYS_CMAX" ] && [ "$waited" -lt "$REBIND_SETTLE" ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [ -e "$SYS_CMAX" ]; then
        log_info "kick_rebind: current_max back after ${waited}s at ${SYS_CMAX}"
    else
        log_warn "kick_rebind: current_max missing after ${REBIND_SETTLE}s -- re-detecting"
        SYS_CMAX=""
        CHARGER_CURRENT_MAX_PATH=""
        resolve_current_max_path || log_error "kick_rebind: re-detect failed"
    fi

    # Gauge node sometimes re-enumerates alongside the charger; refresh too.
    resolve_battery_gauge_paths || true
    return "$did_any"
}

# Escalation dispatcher. Called once per ladder cycle BEFORE the prime/boost
# and ladder attempts. Cycle 1 is plain; starting at ESCALATE_REBIND_AT we
# add a driver rebind so we don't nuke the driver on transient hiccups.
charge_recovery_escalate() {
    local cycle="$1"

    if [ "$cycle" -ge "$ESCALATE_REBIND_AT" ]; then
        log_warn "escalate: cycle ${cycle} >= ${ESCALATE_REBIND_AT} -- driver rebind"
        kick_via_driver_rebind || true
        return 0
    fi

    return 0
}

charge_recovery_probe() {
    local cycle="$1" target="$2" settle="$3" stage="$4"

    sleep "$settle"

    local bqst
    bqst=$(read_bqst) || return 2
    if [ "$bqst" = "Charging" ]; then
        log_info "charge_recovery: Charging detected after cycle ${cycle} at ${target}uA stage=${stage}"
        return 0
    fi

    local cur
    cur=$(read_cur 2>/dev/null) || cur="?"
    log_warn "charge_recovery: bq=${bqst} cur=${cur}uA after cycle ${cycle} target=${target}uA stage=${stage}"
    return 1
}

# ===================================================================
# charge_recovery
# Infinite loop: for each cycle, try a focused wake sequence first
#   0 -> prime current (default 1A) -> 0 -> driver boost
# and only then fall back to a portable ladder over lower limits.
# ===================================================================
do_charge_recovery() {
    local prev_state="$STATE"
    STATE="charge_recovery"
    log_info "ENTER charge_recovery"

    local cycle=0
    while true; do
        cycle=$((cycle + 1))

        charge_recovery_escalate "$cycle"

        write_cmax "$CURRENT_OFF" "charge_recovery cycle ${cycle} prime off-dwell"
        sleep "$RECOVERY_OFF_DWELL"
        write_cmax "$RECOVERY_PRIME" "charge_recovery cycle ${cycle} prime ${RECOVERY_PRIME}uA"
        if charge_recovery_probe "$cycle" "$RECOVERY_PRIME" "$RECOVERY_PRIME_SETTLE" "prime"; then
            STATE="$prev_state"
            return 0
        fi

        if [ "$RECOVERY_BOOST" -ne "$RECOVERY_PRIME" ]; then
            write_cmax "$CURRENT_OFF" "charge_recovery cycle ${cycle} boost off-dwell"
            sleep "$RECOVERY_OFF_DWELL"
            write_cmax "$RECOVERY_BOOST" "charge_recovery cycle ${cycle} boost ${RECOVERY_BOOST}uA"
            if charge_recovery_probe "$cycle" "$RECOVERY_BOOST" "$RECOVERY_BOOST_SETTLE" "boost"; then
                STATE="$prev_state"
                return 0
            fi
        fi

        local target="$CURRENT_START"
        while true; do
            if [ "$target" -eq "$RECOVERY_PRIME" ] || [ "$target" -eq "$RECOVERY_BOOST" ]; then
                if [ "$target" -lt "$CURRENT_CEIL" ]; then
                    target=$((target + CURRENT_STEP))
                    continue
                fi
                if [ "$target" -ne "$CURRENT_DRIVER" ]; then
                    target="$CURRENT_DRIVER"
                    continue
                fi
                break
            fi

            write_cmax "$CURRENT_OFF" "charge_recovery cycle ${cycle} toggle-off before ${target}uA"
            sleep "$RECOVERY_OFF_DWELL"
            write_cmax "$target" "charge_recovery cycle ${cycle} toggle-on ${target}uA"

            if charge_recovery_probe "$cycle" "$target" "$RETRY_INTERVAL" "fallback"; then
                STATE="$prev_state"
                return 0
            fi

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
log_info "config: RECOVERY_OFF_DWELL=${RECOVERY_OFF_DWELL}s RECOVERY_PRIME=${RECOVERY_PRIME} RECOVERY_PRIME_SETTLE=${RECOVERY_PRIME_SETTLE}s RECOVERY_BOOST=${RECOVERY_BOOST} RECOVERY_BOOST_SETTLE=${RECOVERY_BOOST_SETTLE}s"
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
