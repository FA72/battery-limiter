#!/bin/bash
# Install the qcom-pmi8998-wakeirq-fix patch as a DKMS module on the target
# device. Idempotent: safe to re-run. Must run as root.
#
# Layout expected on device after `scp -r kernel-patch <host>:kpatch`:
#   ~/kpatch/dkms/dkms.conf
#   ~/kpatch/dkms/qcom_pmi8998_charger.c
#   ~/kpatch/dkms/Makefile
#
# What it does:
#   1. Installs dkms + kernel headers + build-essential if missing.
#   2. Copies the source tree to /usr/src/qcom-pmi8998-wakeirq-fix-1.1/.
#   3. dkms add / build / install for the current kernel (and AUTOINSTALL=yes
#      makes future kernel upgrades rebuild automatically).
#   4. Re-generates the initrd and invokes the Mobian boot.img hook so the
#      patched module lands inside the active Android boot partition.
#
# After this script finishes, either reboot or live-reload the module,
# then run `bash ~/kpatch/verify_after_reboot.sh` to confirm the fix is live.

set -euo pipefail

PKG_NAME="qcom-pmi8998-wakeirq-fix"
PKG_VERSION="1.1"
SRC_DIR_REL="dkms"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/$SRC_DIR_REL"
DKMS_SRC="/usr/src/${PKG_NAME}-${PKG_VERSION}"

KVER="$(uname -r)"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (sudo $0)" >&2
    exit 1
fi

for f in dkms.conf Makefile qcom_pmi8998_charger.c; do
    [ -f "$SRC_DIR/$f" ] || { echo "ERROR: missing $SRC_DIR/$f" >&2; exit 2; }
done

echo "== 1. install build deps =="
NEED=""
dpkg -s dkms             >/dev/null 2>&1 || NEED="$NEED dkms"
dpkg -s build-essential  >/dev/null 2>&1 || NEED="$NEED build-essential"
dpkg -s "linux-headers-${KVER}" >/dev/null 2>&1 || NEED="$NEED linux-headers-${KVER}"
if [ -n "$NEED" ]; then
    echo "installing:$NEED"
    apt-get update
    apt-get install -y --no-install-recommends $NEED
fi

echo
echo "== 1b. snapshot currently-active qcom_pmi8998_charger.ko =="
# Archive whatever module is resolved right now so we always have a
# known-good rollback target, regardless of DKMS state or prior
# installs. Snapshot is keyed by timestamp so repeated runs do not
# clobber each other.
BACKUP_DIR="/var/backups/kpatch"
mkdir -p "$BACKUP_DIR"
CURRENT_KO="$(modinfo -n qcom_pmi8998_charger 2>/dev/null || true)"
if [ -n "$CURRENT_KO" ] && [ -f "$CURRENT_KO" ]; then
    STAMP="$(date +%Y%m%d-%H%M%S)"
    cp -v "$CURRENT_KO" \
       "$BACKUP_DIR/qcom_pmi8998_charger.ko.${KVER}.${STAMP}"
    # Also keep a stable .orig pointer to the *very first* pre-patch
    # distro module we ever saw, for easy rollback.
    if [ ! -f "$BACKUP_DIR/qcom_pmi8998_charger.ko.orig" ] && \
       ! modinfo "$CURRENT_KO" | grep -q '^srcversion:'; then
        :
    fi
    if [ ! -f "$BACKUP_DIR/qcom_pmi8998_charger.ko.orig" ]; then
        case "$CURRENT_KO" in
            */updates/*)
                echo "note: current module is already a DKMS/updates build;" \
                     "not overwriting .orig"
                ;;
            *)
                cp -v "$CURRENT_KO" "$BACKUP_DIR/qcom_pmi8998_charger.ko.orig"
                ;;
        esac
    fi
else
    echo "WARN: no active qcom_pmi8998_charger module found to snapshot"
fi

echo
echo "== 2. stage source into $DKMS_SRC =="
rm -rf "$DKMS_SRC"
mkdir -p "$DKMS_SRC"
cp -v "$SRC_DIR/dkms.conf"               "$DKMS_SRC/"
cp -v "$SRC_DIR/Makefile"                "$DKMS_SRC/"
cp -v "$SRC_DIR/qcom_pmi8998_charger.c"  "$DKMS_SRC/"

echo
echo "== 3. purge any earlier version of $PKG_NAME, then dkms add =="
# Iterate over every registered version of this package and unregister
# it so the new PKG_VERSION is the only one left. Handles the 1.0 -> 1.1
# upgrade transparently.
for old in $(dkms status 2>/dev/null \
              | awk -F'[,/ :]+' -v p="$PKG_NAME" '$1==p {print $2}' \
              | sort -u); do
    echo "dkms remove $PKG_NAME/$old"
    dkms remove "$PKG_NAME/$old" --all || true
    rm -rf "/usr/src/${PKG_NAME}-${old}"
done
dkms add "$DKMS_SRC"

echo
echo "== 4. dkms build + install for $KVER =="
dkms build "$PKG_NAME/$PKG_VERSION" -k "$KVER"
dkms install "$PKG_NAME/$PKG_VERSION" -k "$KVER" --force

echo
echo "== 5. verify depmod picks up the updates/ module =="
depmod -a "$KVER"
INSTALLED="$(modinfo -n qcom_pmi8998_charger 2>/dev/null || true)"
if [ -z "$INSTALLED" ]; then
    echo "ERROR: modinfo cannot find qcom_pmi8998_charger after install" >&2
    exit 3
fi
case "$INSTALLED" in
    */updates/*) echo "OK: depmod resolves to $INSTALLED" ;;
    *)           echo "WARN: depmod resolves to $INSTALLED -- updates/ path not winning" ;;
esac
if modinfo "$INSTALLED" | grep -q '^vermagic:.*'"$KVER"; then
    echo "OK: vermagic matches running kernel"
else
    echo "ERROR: vermagic mismatch" >&2
    modinfo "$INSTALLED" | grep '^vermagic:'
    exit 4
fi

echo
echo "== 6. regenerate initramfs =="
update-initramfs -u -k "$KVER"

echo
echo "== 7. flash Android boot partition via Mobian hook =="
if [ -x /etc/kernel/postinst.d/zz-qcom-bootimg ]; then
    /etc/kernel/postinst.d/zz-qcom-bootimg "$KVER"
else
    echo "WARN: /etc/kernel/postinst.d/zz-qcom-bootimg not found -- skipping boot.img flash"
    echo "      If this device boots from an Android boot partition, the patched"
    echo "      module will NOT be active after reboot."
fi

echo
echo "== DONE. Reboot and run verify_after_reboot.sh to confirm =="
