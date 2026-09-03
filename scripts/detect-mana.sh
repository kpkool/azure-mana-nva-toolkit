#!/usr/bin/env bash
# MANA NIC detection.
# Run in-guest, or remotely without SSH:
#   az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript --scripts @detect-mana.sh --query "value[0].message" -o tsv
set -u
K=$(uname -r)
echo "=== kernel ==="
echo "$K"
echo "=== lspci ethernet ==="
PCI_OUTPUT=""
HW=unknown
if command -v lspci >/dev/null 2>&1; then
  if PCI_OUTPUT=$(lspci 2>/dev/null); then
    printf '%s\n' "$PCI_OUTPUT" | grep -i ethernet || echo "no ethernet controller line"
    if printf '%s\n' "$PCI_OUTPUT" | grep -qi "00ba"; then HW=yes; else HW=no; fi
  else
    echo "UNKNOWN: lspci failed"
  fi
else
  echo "UNKNOWN: lspci is unavailable"
fi
echo "=== MANA verdict (lspci 00ba) ==="
case "$HW" in
  yes) echo "MANA hardware present: Microsoft Device 00ba" ;;
  no) echo "MANA hardware not observed by lspci; inspect positive PCI/driver evidence before naming another NIC family" ;;
  *) echo "MANA hardware state UNKNOWN because lspci did not complete" ;;
esac
echo "=== mana driver present ==="
(grep "/mana.*\.ko" /lib/modules/"$K"/modules.builtin || find /lib/modules/"$K"/kernel -name 'mana*.ko*') 2>/dev/null || echo "mana.ko not found"
echo "=== ip link (brief) ==="
ip -br link
echo "=== accelerated VFs (per-NIC; CHILD or legacy NetVSC SLAVE, not just the first) ==="
# Current MANA kernels mark the VF as CHILD; older NetVSC relationships use SLAVE.
# Accept SLAVE only when its master uses hv_netvsc so ordinary bond members are excluded.
VF_RELATIONS=""
while IFS='|' read -r VF MASTER RELATION; do
  [ -z "${VF:-}" ] && continue
  MASTER_DRIVER=""
  if [ -n "${MASTER:-}" ]; then
    MASTER_DRIVER=$(ethtool -i "$MASTER" 2>/dev/null | awk -F': ' '/^driver/{print $2}')
  fi
  if [ "$RELATION" = "CHILD" ] || [ "$MASTER_DRIVER" = "hv_netvsc" ]; then
    VF_RELATIONS="${VF_RELATIONS}${VF_RELATIONS:+
}${VF}|${MASTER}"
  fi
done <<EOF
$(ip -o link show | awk -F': ' '
  /<[^>]*(CHILD|SLAVE)[^>]*>/ {
    iface=$2; sub(/@.*/, "", iface)
    master=""; count=split($0, words, /[[:space:]]+/)
    for (i=1; i<=count; i++) if (words[i] == "master" && i < count) { master=words[i+1]; sub(/@.*/, "", master) }
    relation=($0 ~ /<[^>]*CHILD[^>]*>/ ? "CHILD" : "SLAVE")
    print iface "|" master "|" relation
  }')
EOF
VFS=$(printf '%s\n' "$VF_RELATIONS" | awk -F'|' 'NF && !seen[$1]++ {print $1}')
[ -z "$VFS" ] && echo "no guest VF found (check Accelerated Networking on each Azure NIC resource)"
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
echo "MANA hardware (lspci 00ba): $HW; accelerated VFs: $VF_COUNT (mana=$MANA_VFS, non-mana=$NONMANA_VFS)"
if [ "$HW" = yes ] && [ "$NONMANA_VFS" -gt 0 ]; then
  echo "  WARNING: on MANA hardware but $NONMANA_VFS VF(s) not bound to 'mana' -> NetVSC fallback risk on those NIC(s)"
fi
echo "=== VF counters (per synthetic NIC) ==="
# vf_ counters live on the synthetic master (eth0/eth1...), not on the VF; show every synthetic NIC
for MASTER in $(ip -o link show | awk -F': ' '{iface=$2; sub(/@.*/, "", iface); print iface}'); do
  [ "$(ethtool -i "$MASTER" 2>/dev/null | awk -F': ' '/^driver/{print $2}')" = "hv_netvsc" ] || continue
  STATS=$(ethtool -S "$MASTER" 2>/dev/null | grep -E '^\s*vf_')
  if [ -n "$STATS" ]; then echo "  [$MASTER]"; printf '%s\n' "$STATS" | sed 's/^/    /'; fi
done
