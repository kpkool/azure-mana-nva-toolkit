#!/usr/bin/env bash
# Traffic + VF counter capture.
# Usage (remote, no SSH):
#   az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript --scripts @traffic-capture.sh --parameters "<target-private-ip>"
set -u
TARGET="${1:-}"
PRIMARY=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
PRIMARY="${PRIMARY:-eth0}"
echo "primary interface: $PRIMARY   target: ${TARGET:-<none>}"
echo "=== VF counters BEFORE ==="
ethtool -S "$PRIMARY" 2>/dev/null | grep -E '^\s*vf_(rx|tx)_(packets|bytes)'
if [ -n "$TARGET" ]; then
  echo "=== generating traffic (flood ping x5000) ==="
  ping -c 5000 -f -s 1400 "$TARGET" >/dev/null 2>&1
  echo "ping exit=$?"
fi
echo "=== VF counters AFTER ==="
ethtool -S "$PRIMARY" 2>/dev/null | grep -E '^\s*vf_(rx|tx)_(packets|bytes)'
