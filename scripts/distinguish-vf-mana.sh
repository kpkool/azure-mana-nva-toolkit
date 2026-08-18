#!/usr/bin/env bash
# distinguish-vf-mana.sh — prove WHICH accelerated VF carried traffic (MANA vs Mellanox)
# using per-VF, driver-specific signals — not just `ethtool -i`.
# Run without SSH via:
#   az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript \
#     --scripts "@scripts/distinguish-vf-mana.sh" --parameters "<target-private-ip>" --query "value[0].message" -o tsv
set -u
TARGET="${1:-}"
PRIMARY=$(ip -o -4 route show to default | awk '{print $5}' | head -n1); PRIMARY="${PRIMARY:-eth0}"
VF=$(ip -o link show | awk -F': ' '/SLAVE/{print $2}' | awk '{print $1}' | head -n1)
echo "primary=$PRIMARY   VF=${VF:-none}   target=${TARGET:-none}"
[ -z "${VF:-}" ] && { echo "No accelerated VF (AN disabled) — nothing to distinguish."; exit 0; }

DRV=$(ethtool -i "$VF" 2>/dev/null | awk -F': ' '/^driver/{print $2}')
echo "VF bound driver = ${DRV:-unknown}"

# Signal 0 (authoritative): netvsc's own datapath statement naming the VF
echo "=== Signal 0: netvsc datapath (dmesg 'Data path switched to VF') ==="
dmesg 2>/dev/null | grep -i "Data path switched" | tail -n2 | sed 's/^/  /' || echo "(none; dmesg may need sudo)"

# Signal 1: per-VF driver-specific counter NAMES (schema differs by driver)
echo "=== Signal 1: VF-specific counter name schema (first 8 non-generic) ==="
ethtool -S "$VF" 2>/dev/null | grep -vE '^\s*(rx_packets|tx_packets|rx_bytes|tx_bytes):' \
  | awk 'NF' | head -n 8 || echo "(no VF stats)"

# Signal 2: driver-specific IRQ names in /proc/interrupts
echo "=== Signal 2: VF interrupt names (mana_* vs mlx5_comp*/mlx5_async) ==="
grep -iE 'mana|mlx5' /proc/interrupts | sed 's/^/  /' | head -n 6 || echo "(none)"

# Snapshot a VF-owned byte counter (proves THIS VF moved the bytes, from sysfs)
B1=$(cat /sys/class/net/"$VF"/statistics/rx_bytes 2>/dev/null)
echo "=== VF $VF sysfs rx_bytes BEFORE: ${B1:-NA} ==="

if [ -n "$TARGET" ]; then
  echo "=== generating traffic (flood ping x5000) ==="
  ping -c 5000 -f -s 1400 "$TARGET" >/dev/null 2>&1; echo "ping exit=$?"
fi

B2=$(cat /sys/class/net/"$VF"/statistics/rx_bytes 2>/dev/null)
echo "=== VF $VF sysfs rx_bytes AFTER:  ${B2:-NA} ==="
if [ -n "${B1:-}" ] && [ -n "${B2:-}" ]; then
  echo "delta rx_bytes on VF '$VF' = $((B2 - B1))  (this specific VF carried the traffic)"
fi

echo "=== verdict ==="
case "${DRV:-}" in
  mana)  echo "Traffic carried by MANA VF ('$VF', driver mana) — confirmed by MANA counter schema + mana_* IRQs + VF byte delta." ;;
  mlx*)  echo "Traffic carried by Mellanox/ConnectX VF ('$VF', driver $DRV) — mlx5 counter schema + mlx5 IRQs." ;;
  *)     echo "Unknown VF driver '$DRV'." ;;
esac
