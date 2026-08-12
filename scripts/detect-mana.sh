#!/usr/bin/env bash
# MANA NIC detection.
# Run in-guest, or remotely without SSH:
#   az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript --scripts @detect-mana.sh --query "value[0].message" -o tsv
set -u
K=$(uname -r)
echo "=== kernel ==="
echo "$K"
echo "=== lspci ethernet ==="
lspci | grep -i ethernet || echo "no ethernet controller line"
echo "=== MANA verdict (lspci 00ba) ==="
if lspci | grep -qi "00ba"; then echo "ON MANA: Microsoft Device 00ba present"; else echo "NOT on MANA (no 00ba)"; fi
echo "=== mana driver present ==="
(grep "/mana.*\.ko" /lib/modules/"$K"/modules.builtin || find /lib/modules/"$K"/kernel -name 'mana*.ko*') 2>/dev/null || echo "mana.ko not found"
echo "=== ip link (brief) ==="
ip -br link
echo "=== bound NIC driver (definitive: mana vs mlx5) ==="
PRIMARY=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
PRIMARY="${PRIMARY:-eth0}"
echo "primary interface: $PRIMARY"
# The accelerated VF is the bonded SLAVE interface (enP* on ConnectX, ens* on MANA)
VF=$(ip -o link show | awk -F': ' '/SLAVE/{print $2}' | awk '{print $1}' | head -n1)
echo "VF interface: ${VF:-none}"
for I in "$PRIMARY" "$VF"; do
  [ -z "$I" ] && continue
  DRV=$(ethtool -i "$I" 2>/dev/null | awk -F': ' '/^driver/{print $2}')
  echo "  $I driver = ${DRV:-unknown}"
done
if [ -n "${VF:-}" ]; then
  VFDRV=$(ethtool -i "$VF" 2>/dev/null | awk -F': ' '/^driver/{print $2}')
  case "$VFDRV" in
    mana) echo "  => VF driver 'mana' -> ON MANA" ;;
    mlx5_core|mlx4_*|mlx*) echo "  => VF driver '$VFDRV' -> NOT MANA (Mellanox/ConnectX)" ;;
    *) echo "  => VF driver '$VFDRV' -> unknown" ;;
  esac
fi
echo "=== VF counters (primary NIC) ==="
ethtool -S "$PRIMARY" 2>/dev/null | grep -E '^\s*vf_' || echo "no vf_ stats on $PRIMARY"
