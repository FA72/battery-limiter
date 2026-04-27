#!/bin/bash
# Uninstall the qcom-pmi8998-wakeirq-fix DKMS module (revert to distro module).
# Must run as root.
set -euo pipefail

PKG_NAME="qcom-pmi8998-wakeirq-fix"
KVER="$(uname -r)"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

# Remove every registered version of the package (1.0, 1.1, ...).
for old in $(dkms status 2>/dev/null \
              | awk -F'[,/ :]+' -v p="$PKG_NAME" '$1==p {print $2}' \
              | sort -u); do
    echo "dkms remove $PKG_NAME/$old"
    dkms remove "$PKG_NAME/$old" --all || true
    rm -rf "/usr/src/${PKG_NAME}-${old}"
done

depmod -a "$KVER"
update-initramfs -u -k "$KVER"

if [ -x /etc/kernel/postinst.d/zz-qcom-bootimg ]; then
    /etc/kernel/postinst.d/zz-qcom-bootimg "$KVER"
fi

echo "DONE. Reboot to return to the unpatched (distro) module."
