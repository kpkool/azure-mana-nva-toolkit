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

# ---- 2. Accelerated Networking (detect the accelerated VF) ----
echo "== 2. Accelerated Networking =="
VF=$(ip -o link show | awk -F': ' '/SLAVE/{print $2}' | awk '{print $1}' | head -n1)
PRIMARY=$(ip -o -4 route show to default | awk '{print $5}' | head -n1); PRIMARY="${PRIMARY:-eth0}"
echo "primary interface: $PRIMARY   VF (accelerated slave): ${VF:-none}"
if [ -n "${VF:-}" ]; then
  row "$PASS" "Accelerated Networking active (VF '$VF' bonded to '$PRIMARY')"
else
  row "$WARN" "No accelerated VF detected -> AN likely Disabled (no MANA action required)"
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

# ---- 4. MANA driver loaded ----
echo "== 4. MANA driver =="
DRV_FILE=$( (grep "/mana.*\.ko" /lib/modules/"$K"/modules.builtin || find /lib/modules/"$K"/kernel -name 'mana*.ko*') 2>/dev/null | head -n1)
echo "mana.ko: ${DRV_FILE:-not found}"
VFDRV=""
if [ -n "${VF:-}" ]; then VFDRV=$(ethtool -i "$VF" 2>/dev/null | awk -F': ' '/^driver/{print $2}'); fi
echo "VF '$VF' bound driver: ${VFDRV:-none}"
case "${VFDRV:-}" in
  mana)                 row "$PASS" "VF driver = mana -> MANA driver loaded and bound" ;;
  mlx5_core|mlx4_*|mlx*) row "$INFO" "VF driver = ${VFDRV} -> Mellanox/ConnectX (not MANA)" ;;
  "")                   row "$INFO" "No VF bound driver (AN disabled or no VF)" ;;
  *)                    row "$WARN" "VF driver = ${VFDRV} -> unexpected" ;;
esac
# Fallback / degradation detection: MANA hardware present but driver not bound
if [ "${ON_MANA_HW:-0}" = "1" ] && [ "${VFDRV:-}" != "mana" ]; then
  row "$FAIL" "On MANA hardware but MANA driver NOT bound -> NetVSC fallback risk (update kernel/driver)"
fi
# Authoritative: the netvsc driver's own datapath statement (dmesg)
DP=$(dmesg 2>/dev/null | grep -i "Data path switched" | tail -n1)
echo "netvsc datapath (dmesg): ${DP:-<none; may need sudo or ring rotated>}"
if printf '%s' "$DP" | grep -qi "switched to VF"; then
  row "$PASS" "netvsc reports datapath ON the VF (accelerated path active)"
fi
line

# ---- 5. VF functioning (traffic counters increment) ----
echo "== 5. VF functioning (counters) =="
C1=$(ethtool -S "$PRIMARY" 2>/dev/null | awk '/vf_rx_packets/{print $2; exit}')
sleep 2
C2=$(ethtool -S "$PRIMARY" 2>/dev/null | awk '/vf_rx_packets/{print $2; exit}')
echo "vf_rx_packets: ${C1:-NA} -> ${C2:-NA}"
if [ -n "${C1:-}" ] && [ -n "${C2:-}" ]; then
  if [ "$C2" -ge "$C1" ] 2>/dev/null && [ "$C2" -gt 0 ]; then
    row "$PASS" "VF counters present and non-zero (accelerated datapath in use)"
  else
    row "$WARN" "VF counters not incrementing/zero (little traffic, or VF not in use)"
  fi
else
  row "$INFO" "No vf_ stats on $PRIMARY (expected when AN disabled)"
fi
line

# ---- 6. Link sanity (extra tests) ----
echo "== 6. Link sanity =="
ip -br link | sed 's/^/  /'
row "$INFO" "primary '$PRIMARY' state: $(cat /sys/class/net/"$PRIMARY"/operstate 2>/dev/null || echo unknown), MTU $(cat /sys/class/net/"$PRIMARY"/mtu 2>/dev/null || echo ?)"
line

# ---- SUMMARY VERDICT ----
echo "== SUMMARY =="
echo "(Reports hardware/driver/AN facts only. NVA-vs-general classification comes from your vendor/CMDB; LegacyVMNVA is only for AN-based NVAs, not general VMs.)"
if [ "${ON_MANA_HW:-0}" = "1" ] && [ "${VFDRV:-}" = "mana" ]; then
  echo "VERDICT: ON MANA, driver working. No action for general workloads. If this is an NVA, validate appliance behavior and consider migrating to a MANA-optimized series."
elif [ "${ON_MANA_HW:-0}" = "1" ] && [ "${VFDRV:-}" != "mana" ]; then
  echo "VERDICT: ON MANA hardware but driver MISSING -> NetVSC fallback. Update OS/kernel or install MANA driver; if NVA degrades keep LegacyVMNVA."
elif [ -z "${VF:-}" ]; then
  echo "VERDICT: Accelerated Networking DISABLED -> no MANA action required."
else
  echo "VERDICT: NOT on MANA (Mellanox/ConnectX). No action for general workloads. Apply LegacyVMNVA ONLY if this is an Accelerated-Networking NVA (firewall/router/SD-WAN) not yet confirmed MANA-compatible, before the earliest placement date."
fi
echo "####################################################"
