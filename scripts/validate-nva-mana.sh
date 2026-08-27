#!/usr/bin/env bash
# validate-nva-mana.sh — per-VM MANA readiness validator (Linux)
# Checks, at the VM level: (1) LegacyVMNVA tag, (2) Accelerated Networking,
# (3) MANA hardware present, (4) MANA driver loaded (+ authoritative netvsc datapath),
# (5) VF functioning, plus link sanity. Prints PASS/WARN/FAIL/INFO + a VERDICT.
# Run without SSH via:
#   az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript \
#     --scripts "@scripts/validate-nva-mana.sh" --query "value[0].message" -o tsv
set -u
PASS="PASS"; FAIL="FAIL"; INFO="INFO"; WARN="WARN"
line(){ printf '%s\n' "------------------------------------------------------------"; }
row(){ printf '[%-4s] %s\n' "$1" "$2"; }

IMDS="http://169.254.169.254/metadata/instance"
HDR="Metadata:true"
K=$(uname -r)

echo "############ MANA NVA VALIDATOR (Linux) ############"
echo "host: $(hostname)   kernel: $K   date: $(date -u +%FT%TZ)"
line

# ---- 0. Identity + size (from IMDS) ----
VMNAME=$(curl -s -H "$HDR" "$IMDS/compute/name?api-version=2021-02-01&format=text" 2>/dev/null)
VMSIZE=$(curl -s -H "$HDR" "$IMDS/compute/vmSize?api-version=2021-02-01&format=text" 2>/dev/null)
echo "== Identity =="
row "$INFO" "VM name (IMDS): ${VMNAME:-unknown}"
row "$INFO" "VM size (IMDS): ${VMSIZE:-unknown}"
line

# ---- 1. Tag check (LegacyVMNVA) via IMDS ----
echo "== 1. LegacyVMNVA tag =="
TAGS=$(curl -s -H "$HDR" "$IMDS/compute/tags?api-version=2021-02-01&format=text" 2>/dev/null)
echo "raw tags: ${TAGS:-<none>}"
if printf '%s' "$TAGS" | grep -qi "LegacyVMNVA"; then
  TAGVAL=$(printf '%s' "$TAGS" | tr ';' '\n' | grep -i "LegacyVMNVA" | cut -d: -f2)
  row "$PASS" "LegacyVMNVA tag present (value: ${TAGVAL:-?})"
else
  row "$WARN" "LegacyVMNVA tag NOT present (exception not applied to this VM)"
fi
line

# ---- 2. Accelerated Networking (detect EVERY accelerated VF; multi-NIC aware) ----
echo "== 2. Accelerated Networking =="
# Each AN-enabled NIC exposes a bonded SLAVE VF. Multi-NIC NVAs have several -- enumerate ALL of them
# (never head -n1), or a data-plane NIC's VF is silently skipped and the verdict is a false 'all clear'.
VFS=$(ip -o link show | awk -F': ' '/SLAVE/{print $2}' | awk '{print $1}')
VFS_LINE=$(printf '%s' "$VFS" | tr '\n' ' ')   # collapse newline-separated list to one line
VF_COUNT=0; for _vf in $VFS; do VF_COUNT=$((VF_COUNT+1)); done
echo "accelerated VFs found: $VF_COUNT -> ${VFS_LINE:-none}"
if [ "$VF_COUNT" -gt 0 ]; then
  row "$PASS" "Accelerated Networking active on $VF_COUNT NIC(s): $VFS_LINE"
else
  row "$WARN" "No accelerated VF detected -> AN likely Disabled on all NICs (no MANA action required)"
fi
line

# ---- 3. MANA hardware present (PCI 00ba) ----
echo "== 3. MANA hardware (PCI Device 00ba) =="
lspci 2>/dev/null | grep -i ethernet || echo "(no ethernet line from lspci)"
if lspci 2>/dev/null | grep -qi "00ba"; then
  ON_MANA_HW=1; row "$PASS" "MANA NIC present: Microsoft Corporation Device 00ba"
else
  ON_MANA_HW=0; row "$INFO" "No MANA PCI device -> VM is on Mellanox/ConnectX hardware (not MANA)"
fi
line

# ---- 4. MANA driver loaded (per-NIC across ALL VFs) ----
echo "== 4. MANA driver =="
DRV_FILE=$( (grep "/mana.*\.ko" /lib/modules/"$K"/modules.builtin || find /lib/modules/"$K"/kernel -name 'mana*.ko*') 2>/dev/null | head -n1)
echo "mana.ko: ${DRV_FILE:-not found}"
MANA_VFS=0; NONMANA_VFS=0
for VF in $VFS; do
  VFDRV=$(ethtool -i "$VF" 2>/dev/null | awk -F': ' '/^driver/{print $2}')
  case "${VFDRV:-}" in
    mana)                  row "$PASS" "VF $VF driver = mana -> MANA driver loaded and bound"; MANA_VFS=$((MANA_VFS+1)) ;;
    mlx5_core|mlx4_*|mlx*) row "$INFO" "VF $VF driver = ${VFDRV} -> Mellanox/ConnectX (not MANA)"; NONMANA_VFS=$((NONMANA_VFS+1)) ;;
    "")                    row "$WARN" "VF $VF has no bound driver"; NONMANA_VFS=$((NONMANA_VFS+1)) ;;
    *)                     row "$WARN" "VF $VF driver = ${VFDRV} -> unexpected"; NONMANA_VFS=$((NONMANA_VFS+1)) ;;
  esac
  # Per-NIC fallback detection: MANA hardware present but this VF not bound to mana
  if [ "${ON_MANA_HW:-0}" = "1" ] && [ "${VFDRV:-}" != "mana" ]; then
    row "$FAIL" "VF $VF: on MANA hardware but not bound to 'mana' -> NetVSC fallback risk (update kernel/driver)"
  fi
done
[ "$MANA_VFS" -eq 0 ] && [ "$NONMANA_VFS" -eq 0 ] && row "$INFO" "No VF bound driver (AN disabled or no VF)"
# Authoritative: the netvsc driver's own datapath statement (dmesg)
DP=$(dmesg 2>/dev/null | grep -i "Data path switched" | tail -n1)
echo "netvsc datapath (dmesg): ${DP:-<none; may need sudo or ring rotated>}"
if printf '%s' "$DP" | grep -qi "switched to VF"; then
  row "$PASS" "netvsc reports datapath ON a VF (accelerated path active)"
fi
line

# ---- 5. VF functioning (traffic counters increment; per synthetic NIC) ----
echo "== 5. VF functioning (counters) =="
# vf_ counters live on the synthetic master (eth0/eth1...). Check every synthetic NIC that exposes them.
MASTERS=$(ip -o link show | awk -F': ' '/BROADCAST/ && !/SLAVE/{print $2}' | awk '{print $1}')
ANY_COUNTER=0
for M in $MASTERS; do
  C1=$(ethtool -S "$M" 2>/dev/null | awk '/vf_rx_packets/{print $2; exit}')
  [ -z "${C1:-}" ] && continue
  ANY_COUNTER=1
  sleep 1
  C2=$(ethtool -S "$M" 2>/dev/null | awk '/vf_rx_packets/{print $2; exit}')
  echo "  [$M] vf_rx_packets: ${C1:-NA} -> ${C2:-NA}"
  if [ "${C2:-0}" -gt 0 ] 2>/dev/null; then
    row "$PASS" "VF counters present on $M (accelerated datapath in use)"
  else
    row "$WARN" "VF counters flat/zero on $M (little traffic, or VF not in use)"
  fi
done
[ "$ANY_COUNTER" = "0" ] && row "$INFO" "No vf_ stats on any synthetic NIC (expected when AN disabled)"
line

# ---- 6. Link sanity (extra tests) ----
echo "== 6. Link sanity =="
ip -br link | sed 's/^/  /'
for M in $MASTERS; do
  row "$INFO" "$M state: $(cat /sys/class/net/"$M"/operstate 2>/dev/null || echo unknown), MTU $(cat /sys/class/net/"$M"/mtu 2>/dev/null || echo ?)"
done
line

# ---- SUMMARY VERDICT (roll-up across ALL NICs; the worst NIC drives the verdict) ----
echo "== SUMMARY =="
echo "(Reports hardware/driver/AN facts only. NVA-vs-general classification comes from your vendor/CMDB; LegacyVMNVA is only for AN-based NVAs, not general VMs.)"
echo "roll-up: MANA hardware=$([ "${ON_MANA_HW:-0}" = 1 ] && echo yes || echo no), accelerated VFs=$VF_COUNT (mana=$MANA_VFS, non-mana=$NONMANA_VFS)"
if [ "$VF_COUNT" -eq 0 ]; then
  echo "VERDICT: Accelerated Networking DISABLED on all NICs -> no MANA action required."
elif [ "${ON_MANA_HW:-0}" = "1" ] && [ "$NONMANA_VFS" -gt 0 ]; then
  echo "VERDICT: ON MANA hardware but $NONMANA_VFS of $VF_COUNT VF(s) NOT bound to 'mana' -> NetVSC fallback on those NIC(s). Update OS/kernel or install MANA driver; if an NVA degrades keep LegacyVMNVA."
elif [ "${ON_MANA_HW:-0}" = "1" ] && [ "$MANA_VFS" -eq "$VF_COUNT" ]; then
  echo "VERDICT: ON MANA, all $VF_COUNT VF(s) driver working. No action for general workloads. If this is an NVA, validate appliance behavior and consider migrating to a MANA-optimized series."
else
  echo "VERDICT: NOT on MANA (Mellanox/ConnectX) across $VF_COUNT VF(s). No action for general workloads. Apply LegacyVMNVA ONLY if this is an Accelerated-Networking NVA (firewall/router/SD-WAN) not yet confirmed MANA-compatible, before the earliest placement date."
fi
echo "####################################################"
