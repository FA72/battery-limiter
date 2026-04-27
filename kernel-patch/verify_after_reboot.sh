#!/bin/bash
# Post-install verification: confirm the patched module is loaded, then
# exercise an unbind/bind on the SPMI parent and confirm the probe now
# succeeds (no -EEXIST on dev_pm_set_wake_irq). Can be used after reboot
# or after a manual rmmod/modprobe live-reload.
set -euo pipefail

echo "=== module loaded? ==="
lsmod | grep qcom_pmi8998_charger || { echo "module not loaded"; exit 2; }

echo
echo "=== does running module contain the fix symbol? ==="
if sudo grep -q '[tT] smb2_disable_wake_irq' /proc/kallsyms; then
    echo "YES: smb2_disable_wake_irq present in kallsyms -- patched module is active"
else
    echo "NO: fix symbol missing -- still running OLD module. Did reboot or live reload happen?"
    exit 3
fi

echo
echo "=== charger power_supply present? ==="
test -d /sys/class/power_supply/pmi8998-charger
ls /sys/class/power_supply/pmi8998-charger/{status,online,current_max} >/dev/null
echo OK

echo
echo "=== exercise parent SPMI unbind / bind ==="
SPMI_DRV=/sys/bus/spmi/drivers/pmic-spmi
PMIC=0-02
[ -e "$SPMI_DRV/$PMIC" ] || { echo "PMIC node not bound"; exit 4; }
echo "unbinding $PMIC"
echo "$PMIC" | sudo tee "$SPMI_DRV/unbind" >/dev/null
sleep 1
echo "binding $PMIC"
echo "$PMIC" | sudo tee "$SPMI_DRV/bind" >/dev/null

echo
echo "=== wait for charger power_supply to reappear ==="
for i in $(seq 1 30); do
    [ -e /sys/class/power_supply/pmi8998-charger/current_max ] && { echo "back after ${i}s"; break; }
    sleep 1
done

echo
echo "=== recent kernel messages (should NOT contain -EEXIST / Couldn't set wake irq) ==="
sudo dmesg -T | tail -n 60 | grep -E 'pmi8998|wake irq|smb2|charger@1000' || echo "(no matching lines)"

echo
echo "=== state after rebind ==="
cat /sys/class/power_supply/pmi8998-charger/status
cat /sys/class/power_supply/pmi8998-charger/online
cat /sys/class/power_supply/pmi8998-charger/current_max
