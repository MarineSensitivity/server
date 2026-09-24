#!/usr/bin/env bash
# host/swap.sh — give msens1 a swapfile so a memory spike degrades instead of wedging the host.
#
# WHY: 2026-09-24, a Shiny app worker in the rstudio container reached 7.8 GB resident on this
# 16 GB, no-swap host. The kernel reclaimed page cache for an hour (CPU flat at 32 %, every
# service and sshd unreachable) before the OOM killer fired; only an EC2 reboot ended it. The
# container now carries a cgroup ceiling (docker-compose.yml, rstudio: mem_limit) so the worker
# is killed inside it; this swapfile is the second layer, for everything outside that ceiling.
#
# Idempotent: re-running leaves an existing swapfile alone. Run as root on the host:
#   sudo host/swap.sh            # 4 GiB on / (20 GB root volume, ~13 GB free on 2026-09-24)
#   SWAP_GB=8 sudo -E host/swap.sh
set -euo pipefail
SWAP_FILE=/swapfile
SWAP_GB="${SWAP_GB:-4}"
SWAPPINESS=10   # prefer reclaiming page cache; swap only under real pressure
if swapon --show=NAME --noheadings | grep -qx "$SWAP_FILE"; then
  echo "[swap] $SWAP_FILE already active: $(swapon --show=SIZE,USED --noheadings | head -1)"
else
  if [ ! -f "$SWAP_FILE" ]; then
    echo "[swap] creating ${SWAP_GB} GiB at $SWAP_FILE"
    fallocate -l "${SWAP_GB}G" "$SWAP_FILE" || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((SWAP_GB*1024)) status=none
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null
  fi
  swapon "$SWAP_FILE"
  echo "[swap] activated: $(swapon --show=SIZE --noheadings | head -1)"
fi
grep -qE "^$SWAP_FILE\s" /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
echo "vm.swappiness = $SWAPPINESS" > /etc/sysctl.d/60-msens-swap.conf
sysctl -q -w vm.swappiness="$SWAPPINESS"
echo "[swap] vm.swappiness=$(cat /proc/sys/vm/swappiness); fstab: $(grep -c "^$SWAP_FILE" /etc/fstab) entry"
free -m | sed -n '1,3p'
