#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DETECT_SCRIPT="$REPO_ROOT/scripts/detect-mana.sh"

lspci() {
  echo "0000:00:00.0 Ethernet controller: Microsoft Corporation Device 00ba"
}

ip() {
  if [ "$1" = "-br" ]; then
    printf '%s\n' \
      "eth0 UP synthetic" \
      "eth1 UP synthetic" \
      "mana0 UP child" \
      "cx0 UP slave" \
      "bond0 UP slave"
  elif [ "$1" = "-o" ]; then
    printf '%s\n' \
      "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP" \
      "3: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP" \
      "4: mana0@eth0: <BROADCAST,MULTICAST,CHILD,UP,LOWER_UP> mtu 1500 master eth0 state UP" \
      "5: cx0@eth1: <BROADCAST,MULTICAST,SLAVE,UP,LOWER_UP> mtu 1500 master eth1 state UP" \
      "6: bond0@bondmaster: <BROADCAST,MULTICAST,SLAVE,UP,LOWER_UP> mtu 1500 master bondmaster state UP"
  fi
}

ethtool() {
  if [ "$1" = "-i" ]; then
    case "$2" in
      eth0|eth1) echo "driver: hv_netvsc" ;;
      mana0) echo "driver: mana" ;;
      cx0) echo "driver: mlx5_core" ;;
      bondmaster) echo "driver: bonding" ;;
      bond0) echo "driver: ixgbe" ;;
    esac
  elif [ "$1" = "-S" ]; then
    echo "vf_rx_packets: 1"
  fi
}

export -f lspci ip ethtool

output=$(bash "$DETECT_SCRIPT" 2>&1)
printf '%s\n' "$output"

grep -q "accelerated VFs: 2 (mana=1, non-mana=1)" <<<"$output"
grep -q "VF mana0 driver='mana'" <<<"$output"
grep -q "VF cx0 driver='mlx5_core'" <<<"$output"
if grep -q "VF bond0" <<<"$output"; then
  echo "ordinary bond member was misclassified as a NetVSC VF" >&2
  exit 1
fi

echo "detect-mana VF discovery: PASS"
