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
echo "=== accelerated VFs (per-NIC; ALL SLAVE interfaces, not just the first) ==="
# Each accelerated NIC exposes a bonded SLAVE VF (enP* on ConnectX, ens* on MANA). Multi-NIC NVAs
# (firewalls/routers) have several -- check EVERY one, never head -n1, or a data-plane NIC is missed.
VFS=$(ip -o link show | awk -F': ' '/SLAVE/{print $2}' | awk '{print $1}')
[ -z "$VFS" ] && echo "no accelerated VF found (Accelerated Networking disabled on all NICs)"
MANA_VFS=0; NONMANA_VFS=0; VF_COUNT=0
for VF in $VFS; do
  VF_COUNT=$((VF_COUNT+1))
  VFDRV=$(ethtool -i "$VF" 2>/dev/null | awk -F': ' '/^driver/{print $2}')
  case "$VFDRV" in
    mana)                  echo "  VF $VF driver='mana' -> ON MANA"; MANA_VFS=$((MANA_VFS+1)) ;;
    mlx5_core|mlx4_*|mlx*) echo "  VF $VF driver='$VFDRV' -> NOT MANA (Mellanox/ConnectX)"; NONMANA_VFS=$((NONMANA_VFS+1)) ;;
    *)                     echo "  VF $VF driver='${VFDRV:-unknown}' -> unknown"; NONMANA_VFS=$((NONMANA_VFS+1)) ;;
  esac
done
echo "=== summary (roll-up across ALL NICs) ==="
if lspci 2>/dev/null | grep -qi "00ba"; then HW=yes; else HW=no; fi
echo "MANA hardware (lspci 00ba): $HW; accelerated VFs: $VF_COUNT (mana=$MANA_VFS, non-mana=$NONMANA_VFS)"
if [ "$HW" = yes ] && [ "$NONMANA_VFS" -gt 0 ]; then
  echo "  WARNING: on MANA hardware but $NONMANA_VFS VF(s) not bound to 'mana' -> NetVSC fallback risk on those NIC(s)"
fi
echo "=== VF counters (per synthetic NIC) ==="
# vf_ counters live on the synthetic master (eth0/eth1...), not on the VF; show every synthetic NIC
for MASTER in $(ip -o link show | awk -F': ' '/BROADCAST/ && !/SLAVE/{print $2}' | awk '{print $1}'); do
  STATS=$(ethtool -S "$MASTER" 2>/dev/null | grep -E '^\s*vf_')
  if [ -n "$STATS" ]; then echo "  [$MASTER]"; printf '%s\n' "$STATS" | sed 's/^/    /'; fi
done
