#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VALIDATOR="$REPO_ROOT/scripts/validate-nva-mana.sh"

curl() {
  case "$*" in
    *compute/name*) echo "vm-fixture" ;;
    *compute/vmSize*) echo "Standard_D4s_v5" ;;
    *compute/tags*) echo "environment:test" ;;
  esac
}

ip() {
  if [ "$1" = "-o" ]; then
    printf '%s\n' \
      "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP" \
      "3: mystery0@eth0: <BROADCAST,MULTICAST,CHILD,UP,LOWER_UP> mtu 1500 master eth0 state UP"
  elif [ "$1" = "-br" ]; then
    printf '%s\n' "eth0 UP synthetic" "mystery0 UP synthetic"
  elif [ "$1" = "rule" ]; then
    printf '%s\n' "0: from all lookup local" "32766: from all lookup main" "32767: from all lookup default"
  fi
}

lspci() {
  if [ "${LSPCI_FAIL:-0}" = "1" ]; then
    return 23
  fi
  echo "0000:00:00.0 Ethernet controller: Example Vendor Device 1234"
}

ethtool() {
  if [ "$1" = "-i" ]; then
    case "$2" in
      eth0) echo "driver: hv_netvsc" ;;
      mystery0) echo "driver: mysteryvf" ;;
    esac
  elif [ "$1" = "-S" ]; then
    echo "vf_rx_packets: 1"
  fi
}

modinfo() { return 0; }
dmesg() { return 0; }
sleep() { return 0; }

export -f curl ip lspci ethtool modinfo dmesg sleep

output=$(bash "$VALIDATOR" 2>&1)
printf '%s\n' "$output"

grep -q '"guestEvidenceStatus":"UNKNOWN"' <<<"$output"
grep -q '"reasonCode":"GUEST_CHECK_INCOMPLETE"' <<<"$output"
grep -q "VF mystery0 driver = mysteryvf -> unexpected" <<<"$output"
if grep -q "Mellanox/ConnectX" <<<"$output"; then
  echo "unexpected VF driver was incorrectly identified as Mellanox/ConnectX" >&2
  exit 1
fi

LSPCI_FAIL=1
export LSPCI_FAIL
lspci_failure_output=$(bash "$VALIDATOR" 2>&1)
printf '%s\n' "$lspci_failure_output"

grep -q "MANA hardware state UNKNOWN because 'lspci' failed" <<<"$lspci_failure_output"
grep -q '"hardwareState":"UNKNOWN"' <<<"$lspci_failure_output"
if grep -q '"hardwareState":"NON_MANA"' <<<"$lspci_failure_output"; then
  echo "failed lspci probe was incorrectly treated as non-MANA evidence" >&2
  exit 1
fi

echo "validate-nva-mana fail-closed classifications: PASS"
