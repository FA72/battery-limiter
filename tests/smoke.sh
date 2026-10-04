#!/bin/bash
# Offline checks: fake power_supply files and mocked commands only.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=$(mktemp -d)
cleanup() {
    rm -f "$SCRATCH/mock.sh" "$SCRATCH/output" "$SCRATCH/capacity" \
        "$SCRATCH/temp" "$SCRATCH/status" "$SCRATCH/current_now" "$SCRATCH/current_max"
    rmdir "$SCRATCH"
}
trap cleanup EXIT

for script in "$ROOT/battery-limiter.sh" "$ROOT"/kernel-patch/*.sh; do
    bash -n "$script"
done

# Intercept the verification helper's hardware-facing commands. Any attempted
# sudo write fails, so the default mode must reach completion without one.
cat > "$SCRATCH/mock.sh" <<'MOCK'
uname() { echo mock-kernel; }
modinfo() { echo /lib/modules/mock-kernel/updates/dkms/qcom_pmi8998_charger.ko; }
lsmod() { echo 'qcom_pmi8998_charger 20480 0'; }
sudo() {
    if [ "${1:-}" = grep ] && [ "${3:-}" = '[tT] smb2_disable_wake_irq' ]; then
        return 0
    fi
    echo "Unexpected privileged command: $*" >&2
    exit 90
}
test() {
    if [ "${1:-}" = -d ] && [ "${2:-}" = /sys/class/power_supply/pmi8998-charger ]; then
        return 0
    fi
    builtin test "$@"
}
ls() { return 0; }
cat() { echo 'MOCK_READ_ONLY_STATE'; }
MOCK

BASH_ENV="$SCRATCH/mock.sh" bash "$ROOT/kernel-patch/verify_after_reboot.sh" > "$SCRATCH/output"
grep -q 'MOCK_READ_ONLY_STATE' "$SCRATCH/output"
grep -q 'no rebind performed' "$SCRATCH/output"

# Invalid options must fail before doing any system inspection.
if BASH_ENV="$SCRATCH/mock.sh" bash "$ROOT/kernel-patch/verify_after_reboot.sh" --invalid > "$SCRATCH/output" 2>&1; then
    echo 'FAIL: unknown verification option was accepted' >&2
    exit 1
fi
grep -q '^Usage:' "$SCRATCH/output"

# Run the real limiter against ordinary files. The fake sleep updates charger
# status according to a required input limit and exits before the second tick.
cat > "$SCRATCH/mock.sh" <<'MOCK'
MOCK_SLEEP_CALLS=0
sleep() {
    MOCK_SLEEP_CALLS=$((MOCK_SLEEP_CALLS + 1))
    if [ "$MOCK_SLEEP_CALLS" -gt 30 ]; then
        echo 'FAIL: recovery did not terminate in the mock fixture' >&2
        exit 91
    fi
    if [ "$1" = 300 ]; then
        exit 0
    fi
    local limit
    limit=$(cat "$SYS_CMAX")
    if [ "$limit" -ge "$MOCK_REQUIRED_CURRENT" ]; then
        echo Charging > "$SYS_BQST"
    else
        echo Discharging > "$SYS_BQST"
    fi
}
MOCK

run_limiter_case() {
    local name="$1" capacity="$2" temperature="$3" status="$4" expected="$5"
    echo "$capacity" > "$SCRATCH/capacity"
    echo "$temperature" > "$SCRATCH/temp"
    echo "$status" > "$SCRATCH/status"
    echo 50000 > "$SCRATCH/current_now"
    echo 600000 > "$SCRATCH/current_max"
    BASH_ENV="$SCRATCH/mock.sh" MOCK_REQUIRED_CURRENT=700000 \
        SYS_CAP="$SCRATCH/capacity" SYS_TEMP="$SCRATCH/temp" \
        SYS_BQST="$SCRATCH/status" SYS_CUR="$SCRATCH/current_now" \
        SYS_CMAX="$SCRATCH/current_max" CAP_LOW=40 CAP_HIGH=80 \
        TEMP_LOCK_ENTER=450 TEMP_LOCK_EXIT=400 TICK_INTERVAL=300 \
        RETRY_INTERVAL=10 TUNING_SETTLE=30 CURRENT_OFF=0 \
        CURRENT_START=600000 CURRENT_STEP=100000 CURRENT_CEIL=1000000 \
        CURRENT_DRIVER=4800000 RECOVERY_PRIME=1000000 \
        bash "$ROOT/battery-limiter.sh" > "$SCRATCH/output"
    if [ "$(cat "$SCRATCH/current_max")" != "$expected" ]; then
        echo "FAIL: $name ended at unexpected current limit" >&2
        cat "$SCRATCH/output" >&2
        exit 1
    fi
    echo "PASS: $name"
}

run_limiter_case 'low SoC recovers and raises insufficient 0.6 A to 0.7 A' 38 350 Discharging 700000
grep -q 'charge_tuning: Charging holds at 700000uA' "$SCRATCH/output"
run_limiter_case 'high SoC pauses charging' 82 350 Charging 0
run_limiter_case 'temperature lock has priority over low SoC' 38 450 Charging 0
if grep -q 'ENTER charge_recovery\|ENTER charge_tuning' "$SCRATCH/output"; then
    echo 'FAIL: temperature lock started a charge workflow' >&2
    exit 1
fi
run_limiter_case 'in range preserves current limit' 60 350 Discharging 600000
run_limiter_case 'exact lower boundary stays in range' 40 350 Discharging 600000
run_limiter_case 'exact upper boundary stays in range' 80 350 Charging 600000

echo 'PASS: Bash syntax, charge-state fixtures and read-only kernel verification'
