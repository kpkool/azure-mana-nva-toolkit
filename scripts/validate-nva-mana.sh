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
add_custom_signal(){ CUSTOM_SIGNALS="${CUSTOM_SIGNALS}${CUSTOM_SIGNALS:+,}\"$1\""; }

IMDS="http://169.254.169.254/metadata/instance"
HDR="Metadata:true"
K=$(uname -r)
MISSING_TOOLS=""
for TOOL in curl ip lspci ethtool; do
  command -v "$TOOL" >/dev/null 2>&1 || MISSING_TOOLS="${MISSING_TOOLS}${MISSING_TOOLS:+,}$TOOL"
done
imds_get(){
  curl -fsS --connect-timeout 2 --max-time 5 --retry 2 --retry-delay 1 \
    -H "$HDR" "$IMDS/$1?api-version=2021-02-01&format=text" 2>/dev/null
}

echo "############ MANA NVA VALIDATOR (Linux) ############"
echo "host: $(hostname)   kernel: $K   date: $(date -u +%FT%TZ)"
line

# ---- 0. Identity + size (from IMDS) ----
VMNAME=$(imds_get compute/name || true)
VMSIZE=$(imds_get compute/vmSize || true)
echo "== Identity =="
row "$INFO" "VM name (IMDS): ${VMNAME:-unknown}"
row "$INFO" "VM size (IMDS): ${VMSIZE:-unknown}"
line

# ---- 1. Tag check (LegacyVMNVA) via IMDS ----
echo "== 1. LegacyVMNVA tag =="
if TAGS=$(imds_get compute/tags); then TAGS_READ=1; else TAGS=""; TAGS_READ=0; fi
if [ "$TAGS_READ" -eq 0 ]; then
  TAG_STATE="unknown"
  row "$WARN" "LegacyVMNVA tag state UNKNOWN (IMDS request failed)"
elif printf '%s' "$TAGS" | grep -qi "LegacyVMNVA"; then
  TAG_STATE="present"
  row "$PASS" "LegacyVMNVA tag present"
else
  TAG_STATE="absent"
  row "$WARN" "LegacyVMNVA tag NOT present (exception not applied to this VM)"
fi
line

# ---- 2. Accelerated Networking (detect EVERY accelerated VF; multi-NIC aware) ----
echo "== 2. Accelerated Networking =="
# Current MANA kernels mark the VF as CHILD; older NetVSC relationships use SLAVE.
# A SLAVE is accepted only when its master uses hv_netvsc, which excludes ordinary bond members.
if command -v ip >/dev/null 2>&1; then
  VF_RELATIONS=""
  while IFS='|' read -r VF MASTER RELATION; do
    [ -z "${VF:-}" ] && continue
    MASTER_DRIVER=""
    if [ -n "${MASTER:-}" ] && command -v ethtool >/dev/null 2>&1; then
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
  MASTERS=$(printf '%s\n' "$VF_RELATIONS" | awk -F'|' 'NF && $2 != "" && !seen[$2]++ {print $2}')
  AN_GUEST_STATE="no"
else
  VFS=""; MASTERS=""
  AN_GUEST_STATE="unknown"
fi
VFS_LINE=$(printf '%s' "$VFS" | tr '\n' ' ')   # collapse newline-separated list to one line
VF_COUNT=0; for _vf in $VFS; do VF_COUNT=$((VF_COUNT+1)); done
echo "accelerated VFs found: $VF_COUNT -> ${VFS_LINE:-none}"
if [ "$AN_GUEST_STATE" = "unknown" ]; then
  row "$WARN" "Accelerated VF state UNKNOWN because 'ip' is unavailable"
elif [ "$VF_COUNT" -gt 0 ]; then
  AN_GUEST_STATE="yes"
  row "$PASS" "Accelerated Networking active on $VF_COUNT NIC(s): $VFS_LINE"
else
  row "$WARN" "No guest VF detected -> verify Accelerated Networking on the Azure NIC resource"
fi
line

# ---- 3. MANA hardware present (PCI 00ba) ----
echo "== 3. MANA hardware (PCI Device 00ba) =="
if ! command -v lspci >/dev/null 2>&1; then
  ON_MANA_HW=-1
  HW_STATE="UNKNOWN"
  row "$WARN" "MANA hardware state UNKNOWN because 'lspci' is unavailable"
elif ! PCI_OUTPUT=$(lspci 2>/dev/null); then
  ON_MANA_HW=-1
  HW_STATE="UNKNOWN"
  row "$WARN" "MANA hardware state UNKNOWN because 'lspci' failed"
else
  printf '%s\n' "$PCI_OUTPUT" | grep -i ethernet || echo "(no ethernet line from lspci)"
  if printf '%s\n' "$PCI_OUTPUT" | grep -qi "00ba"; then
    ON_MANA_HW=1; HW_STATE="MANA"; row "$PASS" "MANA NIC present: Microsoft Corporation Device 00ba"
  else
    ON_MANA_HW=0; HW_STATE="NON_MANA"; row "$INFO" "MANA PCI device not observed; inspect the VF driver before naming another NIC family"
  fi
fi
line

# ---- 4. MANA driver loaded (per-NIC across ALL VFs) ----
echo "== 4. MANA driver =="
DRV_FILE=$( (grep "/mana.*\.ko" /lib/modules/"$K"/modules.builtin || find /lib/modules/"$K"/kernel -name 'mana*.ko*') 2>/dev/null | head -n1)
echo "mana.ko: ${DRV_FILE:-not found}"
if command -v modinfo >/dev/null 2>&1 && modinfo mana >/dev/null 2>&1; then
  MANA_DRIVER_AVAILABLE=1
elif [ -n "$DRV_FILE" ]; then
  MANA_DRIVER_AVAILABLE=1
else
  MANA_DRIVER_AVAILABLE=0
fi
MANA_VFS=0; NONMANA_VFS=0; DRIVER_CHECK_UNKNOWN=0
for VF in $VFS; do
  if command -v ethtool >/dev/null 2>&1; then
    VFDRV=$(ethtool -i "$VF" 2>/dev/null | awk -F': ' '/^driver/{print $2}')
  else
    VFDRV=""
    DRIVER_CHECK_UNKNOWN=1
  fi
  case "${VFDRV:-}" in
    mana)                  row "$PASS" "VF $VF driver = mana -> MANA driver loaded and bound"; MANA_VFS=$((MANA_VFS+1)) ;;
    mlx5_core|mlx4_*|mlx*) row "$INFO" "VF $VF driver = ${VFDRV} -> Mellanox/ConnectX (not MANA)"; NONMANA_VFS=$((NONMANA_VFS+1)) ;;
    "")                    row "$WARN" "VF $VF driver state UNKNOWN"; DRIVER_CHECK_UNKNOWN=1 ;;
    *)                     row "$WARN" "VF $VF driver = ${VFDRV} -> unexpected"; NONMANA_VFS=$((NONMANA_VFS+1)); DRIVER_CHECK_UNKNOWN=1 ;;
  esac
  # Per-NIC fallback detection: MANA hardware present but this VF not bound to mana
  if [ "${ON_MANA_HW:-0}" = "1" ] && [ "${VFDRV:-}" != "mana" ]; then
    row "$FAIL" "VF $VF: on MANA hardware but not bound to 'mana' -> NetVSC fallback risk (update kernel/driver)"
  fi
done
[ "$MANA_VFS" -eq 0 ] && [ "$NONMANA_VFS" -eq 0 ] && row "$WARN" "No VF-bound driver observed; Azure NIC state is authoritative for AN"
# Authoritative: the netvsc driver's own datapath statement (dmesg)
DP=$(dmesg 2>/dev/null | grep -i "Data path switched" | tail -n1)
echo "netvsc datapath (dmesg): ${DP:-<none; may need sudo or ring rotated>}"
DP_CONFIRMED=0
if printf '%s' "$DP" | grep -qi "switched to VF"; then
  DP_CONFIRMED=1
  row "$PASS" "netvsc reports datapath ON a VF (accelerated path active)"
fi
line

# ---- 5. VF functioning (traffic counters increment; per synthetic NIC) ----
echo "== 5. VF functioning (counters) =="
# vf_ counters live on each synthetic NetVSC master discovered with its VF above.
ANY_COUNTER=0; ACTIVE_COUNTER=0
for M in $MASTERS; do
  C1=$(ethtool -S "$M" 2>/dev/null | awk '/vf_rx_packets/{print $2; exit}')
  [ -z "${C1:-}" ] && continue
  ANY_COUNTER=1
  sleep 1
  C2=$(ethtool -S "$M" 2>/dev/null | awk '/vf_rx_packets/{print $2; exit}')
  echo "  [$M] vf_rx_packets: ${C1:-NA} -> ${C2:-NA}"
  if [ "${C2:-0}" -gt "${C1:-0}" ] 2>/dev/null; then
    ACTIVE_COUNTER=1
    row "$PASS" "VF counters incremented on $M (accelerated datapath in use)"
  else
    row "$WARN" "VF counters did not increment on $M; datapath is not confirmed"
  fi
done
[ "$ANY_COUNTER" = "0" ] && row "$INFO" "No vf_ stats observed; guest counters do not establish AN control-plane state"
if [ "${ON_MANA_HW:-0}" = "1" ]; then
  if [ "$DP_CONFIRMED" -eq 1 ] || [ "$ACTIVE_COUNTER" -eq 1 ]; then DATAPATH_STATE="CONFIRMED"; else DATAPATH_STATE="NOT_CONFIRMED"; fi
else
  DATAPATH_STATE="NOT_APPLICABLE"
fi
line

# ---- 6. Link sanity (extra tests) ----
echo "== 6. Link sanity =="
if command -v ip >/dev/null 2>&1; then ip -br link | sed 's/^/  /'; else echo "  (ip unavailable)"; fi
for M in $MASTERS; do
  row "$INFO" "$M state: $(cat /sys/class/net/"$M"/operstate 2>/dev/null || echo unknown), MTU $(cat /sys/class/net/"$M"/mtu 2>/dev/null || echo ?)"
done
line

# ---- 7. Non-sensitive customization risk signals ----
echo "== 7. Custom NIC configuration risk signals =="
CUSTOM_SIGNALS=""
for VF in $VFS; do
  if command -v nmcli >/dev/null 2>&1 && nmcli -g GENERAL.MANAGED device show "$VF" 2>/dev/null | grep -qi '^yes$'; then
    add_custom_signal "VF_MANAGED_BY_NETWORKMANAGER"
    break
  fi
done
if grep -RqsE 'set-name:|interface-name|^DEVICE=|^HWADDR=|^MACADDR=|^Name=|^MACAddress=|^Driver=' \
  /etc/netplan /etc/NetworkManager/system-connections /etc/systemd/network /etc/sysconfig/network-scripts 2>/dev/null; then
  add_custom_signal "PERSISTENT_INTERFACE_BINDING"
fi
if grep -RqsE 'SUBSYSTEM=="net"|NAME=|ATTR\{address\}' /etc/udev/rules.d 2>/dev/null; then
  add_custom_signal "CUSTOM_UDEV_NET_RULE"
fi
if { command -v lsmod >/dev/null 2>&1 && lsmod | grep -Eq '^(vfio_pci|uio_pci_generic|igb_uio)\b'; } || \
   { command -v pgrep >/dev/null 2>&1 && pgrep -f 'dpdk|testpmd|ovs-vswitchd|vpp' >/dev/null 2>&1; }; then
  add_custom_signal "DPDK_OR_USERSPACE_DATAPLANE"
fi
if command -v ip >/dev/null 2>&1 && { ip -d link show type bond 2>/dev/null | grep -q . || ip -d link show type bridge 2>/dev/null | grep -q . || ip -d link show type vrf 2>/dev/null | grep -q .; }; then
  add_custom_signal "BOND_BRIDGE_OR_VRF"
fi
if command -v ip >/dev/null 2>&1 && ip netns list 2>/dev/null | grep -q .; then
  add_custom_signal "NETWORK_NAMESPACE"
fi
if command -v ip >/dev/null 2>&1 && ip rule show 2>/dev/null | grep -Ev '^(0:|32766:|32767:)' | grep -q .; then
  add_custom_signal "POLICY_ROUTING"
fi
if [ -n "$CUSTOM_SIGNALS" ]; then
  CUSTOM_RISK="REVIEW_REQUIRED"
  row "$WARN" "Customization signals detected (codes only): $CUSTOM_SIGNALS"
else
  CUSTOM_RISK="NONE_DETECTED"
  row "$INFO" "No reviewed customization signals detected; this is not proof that none exist"
fi
line

# ---- SUMMARY VERDICT (roll-up across ALL NICs; the worst NIC drives the verdict) ----
echo "== SUMMARY =="
echo "(Reports hardware/driver/AN facts only. NVA-vs-general classification comes from your vendor/CMDB; LegacyVMNVA is only for AN-based NVAs, not general VMs.)"
echo "A guest PASS does not approve migration; image/vendor review and a representative workload pilot remain separate gates."
echo "roll-up: MANA hardware=$HW_STATE, accelerated VFs=$VF_COUNT (mana=$MANA_VFS, non-mana=$NONMANA_VFS)"
if [ -n "$MISSING_TOOLS" ] || [ "$HW_STATE" = "UNKNOWN" ] || [ "$AN_GUEST_STATE" = "unknown" ] || [ "$DRIVER_CHECK_UNKNOWN" -eq 1 ]; then
  GUEST_STATUS="UNKNOWN"; GUEST_REASON="GUEST_CHECK_INCOMPLETE"
  echo "VERDICT: UNKNOWN - required guest evidence could not be collected. Missing tools: ${MISSING_TOOLS:-none}."
elif [ "$VF_COUNT" -eq 0 ] && [ "$ON_MANA_HW" -eq 1 ]; then
  GUEST_STATUS="NOT_READY"; GUEST_REASON="MANA_VF_NOT_EXPOSED"
  echo "VERDICT: ON MANA hardware but no accelerated VF is exposed -> review AN control-plane state and MANA driver binding."
elif [ "$VF_COUNT" -eq 0 ]; then
  GUEST_STATUS="UNKNOWN"; GUEST_REASON="GUEST_VF_NOT_DETECTED"
  echo "VERDICT: UNKNOWN - no guest VF was detected. Verify Accelerated Networking on the Azure NIC resource; guest visibility is not authoritative."
elif [ "${ON_MANA_HW:-0}" = "1" ] && [ "$NONMANA_VFS" -gt 0 ]; then
  GUEST_STATUS="NOT_READY"; GUEST_REASON="MANA_VF_DRIVER_MISMATCH"
  echo "VERDICT: ON MANA hardware but $NONMANA_VFS of $VF_COUNT VF(s) NOT bound to 'mana' -> NetVSC fallback on those NIC(s). Update OS/kernel or install MANA driver; if an NVA degrades keep LegacyVMNVA."
elif [ "${ON_MANA_HW:-0}" = "1" ] && [ "$MANA_VFS" -eq "$VF_COUNT" ]; then
  if [ "$DATAPATH_STATE" = "CONFIRMED" ]; then
    GUEST_STATUS="PASS"; GUEST_REASON="MANA_DRIVER_BOUND"
    echo "VERDICT: ON MANA, all $VF_COUNT VF(s) use the MANA driver and accelerated traffic was observed. Custom images and NVAs still require image/vendor review and a workload pilot."
  else
    GUEST_STATUS="UNKNOWN"; GUEST_REASON="MANA_DATAPATH_NOT_CONFIRMED"
    echo "VERDICT: UNKNOWN - all MANA VF drivers are bound, but accelerated traffic was not confirmed. Generate representative traffic and retest."
  fi
elif [ "$MANA_DRIVER_AVAILABLE" -eq 0 ]; then
  GUEST_STATUS="NOT_READY"; GUEST_REASON="MANA_DRIVER_NOT_AVAILABLE"
  echo "VERDICT: NOT on MANA and the MANA kernel driver was not found -> update the image before a MANA pilot."
else
  GUEST_STATUS="PASS"; GUEST_REASON="NON_MANA_CURRENT_DRIVER_AVAILABLE"
  echo "VERDICT: NOT on MANA (Mellanox/ConnectX) across $VF_COUNT VF(s). Review supported configuration before placement changes. Use LegacyVMNVA only for an AN-enabled NVA with observed degradation or provider direction."
fi
echo "####################################################"
printf 'MANA_RESULT_JSON={"schemaVersion":"1.1","os":"Linux","guestEvidenceStatus":"%s","reasonCode":"%s","guestEvidenceScope":"VM","hardwareState":"%s","guestAnState":"%s","vfCount":%s,"manaVfCount":%s,"nonManaVfCount":%s,"manaDriverAvailable":%s,"datapathState":"%s","datapathScope":"VM_AGGREGATE","tagState":"%s","customizationRisk":"%s","customizationSignals":[%s]}\n' \
  "$GUEST_STATUS" "$GUEST_REASON" "$HW_STATE" "$AN_GUEST_STATE" "$VF_COUNT" "$MANA_VFS" "$NONMANA_VFS" \
  "$([ "$MANA_DRIVER_AVAILABLE" -eq 1 ] && echo true || echo false)" "$DATAPATH_STATE" "$TAG_STATE" "$CUSTOM_RISK" "$CUSTOM_SIGNALS"
