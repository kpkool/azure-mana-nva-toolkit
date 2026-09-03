#!/usr/bin/env bash
# distinguish-vf-mana.sh — attribute sampled traffic to an accelerated VF (MANA vs Mellanox)
# using per-VF, driver-specific signals — not just `ethtool -i`.
# Run without SSH via:
#   az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript \
#     --scripts "@scripts/distinguish-vf-mana.sh" --parameters "<target-private-ip>" --query "value[0].message" -o tsv
set -u
TARGET="${1:-}"
REQUESTED_VF="${2:-}"
for TOOL in ip ethtool; do
  command -v "$TOOL" >/dev/null 2>&1 || { echo "Required tool missing: $TOOL"; exit 2; }
done

discover_vfs() {
  while IFS='|' read -r interface master relation; do
    [ -z "${interface:-}" ] && continue
    master_driver=$(ethtool -i "$master" 2>/dev/null | awk -F': ' '/^driver/{print $2}')
    if [ "$relation" = "CHILD" ] || [ "$master_driver" = "hv_netvsc" ]; then
      printf '%s\n' "$interface"
    fi
  done <<EOF
$(ip -o link show | awk -F': ' '
  /<[^>]*(CHILD|SLAVE)[^>]*>/ {
    interface=$2; sub(/@.*/, "", interface)
    master=""; count=split($0, words, /[[:space:]]+/)
    for (i=1; i<=count; i++) if (words[i] == "master" && i < count) { master=words[i+1]; sub(/@.*/, "", master) }
    relation=($0 ~ /<[^>]*CHILD[^>]*>/ ? "CHILD" : "SLAVE")
    print interface "|" master "|" relation
  }')
EOF
}

VFS=$(discover_vfs | awk 'NF && !seen[$0]++')
if [ -n "$REQUESTED_VF" ]; then
  if ! printf '%s\n' "$VFS" | grep -Fxq "$REQUESTED_VF"; then
    echo "Requested interface '$REQUESTED_VF' is not a discovered NetVSC accelerated VF."
    exit 2
  fi
  VFS="$REQUESTED_VF"
fi
echo "VFs=$(printf '%s' "$VFS" | tr '\n' ' ')  target=${TARGET:-none}"
[ -z "$VFS" ] && { echo "No guest VF found; verify AN on the Azure NIC resource. Nothing to distinguish."; exit 0; }

# Signal 0 (authoritative): netvsc's own datapath statement naming the VF
echo "=== Signal 0: netvsc datapath (dmesg 'Data path switched to VF') ==="
dmesg 2>/dev/null | grep -i "Data path switched" | tail -n2 | sed 's/^/  /' || echo "(none; dmesg may need sudo)"

# Signal 1: driver-specific IRQ names in /proc/interrupts
echo "=== Signal 1: global VF interrupt names (corroborative only) ==="
grep -iE 'mana|mlx5' /proc/interrupts | sed 's/^/  /' | head -n 6 || echo "(none)"

declare -A DRIVERS BEFORE
for VF in $VFS; do
  DRIVERS[$VF]=$(ethtool -i "$VF" 2>/dev/null | awk -F': ' '/^driver/{print $2}')
  BEFORE[$VF]=$(cat /sys/class/net/"$VF"/statistics/rx_bytes 2>/dev/null)
  echo "=== VF $VF: driver=${DRIVERS[$VF]:-unknown}, rx_bytes BEFORE=${BEFORE[$VF]:-NA} ==="
  ethtool -S "$VF" 2>/dev/null | grep -vE '^\s*(rx_packets|tx_packets|rx_bytes|tx_bytes):' \
    | awk 'NF' | head -n 8 || echo "(no VF stats)"
done

if [ -n "$TARGET" ]; then
  echo "=== generating traffic (flood ping x5000) ==="
  ping -c 5000 -f -s 1400 "$TARGET" >/dev/null 2>&1; echo "ping exit=$?"
fi

echo "=== verdict ==="
for VF in $VFS; do
  AFTER=$(cat /sys/class/net/"$VF"/statistics/rx_bytes 2>/dev/null)
  BEFORE_VALUE=${BEFORE[$VF]:-}
  DRIVER=${DRIVERS[$VF]:-}
  if [[ "$BEFORE_VALUE" =~ ^[0-9]+$ && "$AFTER" =~ ^[0-9]+$ ]]; then
    DELTA=$((AFTER - BEFORE_VALUE))
    echo "VF '$VF' driver=${DRIVER:-unknown}: rx_bytes $BEFORE_VALUE -> $AFTER (delta=$DELTA)"
    if [ "$DELTA" -gt 0 ]; then
      case "$DRIVER" in
        mana) echo "OBSERVED: this MANA VF carried traffic during the sample." ;;
        mlx*) echo "OBSERVED: this Mellanox/ConnectX VF carried traffic during the sample." ;;
        *)    echo "OBSERVED: this VF carried traffic, but its driver family is unknown." ;;
      esac
    else
      echo "NOT CONFIRMED: no traffic was observed on this VF during the sample."
    fi
  else
    echo "UNKNOWN: counters could not be read for VF '$VF' (driver=${DRIVER:-unknown})."
  fi
done
