# How to Verify Whether a VM Is on MANA-Capable Hardware

> Commands and outputs below are taken from the official Microsoft Learn pages. See [references.md](./references.md).
> **Verified:** 2026-08-20.

MANA requires **both** host hardware support **and** VM software (driver) support. Run all applicable checks: **Portal (AN enabled) → Hardware (PCI device) → Driver → Traffic**.

> **Start at scale:** to find which VMs to check (vendor, size, NIC count, Accelerated Networking), run the inventory query first — see [inventory-arg.md](./inventory-arg.md).
> For a reproducible, hands-on walkthrough that deploys VMs and captures this evidence, see [evidence-lab.md](./evidence-lab.md). The scripts in [`../scripts/`](../scripts/) automate these checks.

---

## 0. Portal check — is Accelerated Networking enabled? (Linux & Windows)

If Accelerated Networking is **not** enabled, no MANA action is required.

1. In the Azure portal, open the VM → **Networking**.
2. Under **Network Interface**, select your NIC.
3. On the **NIC Overview** pane → **Essentials**, note **Accelerated Networking** = **Enabled** / **Disabled**.

---

## 1. Linux

### 1a. Hardware check — is the MANA NIC present as a PCI device?

```bash
lspci
```

MANA is present when you see the Microsoft Ethernet controller `Device 00ba`, e.g.:

```
7870:00:00.0 Ethernet controller: Microsoft Corporation Device 00ba
```

If you see a different Ethernet controller (e.g., `Mellanox … ConnectX-5`), you are **not** on MANA.

### 1b. Driver check — the definitive discriminator (`mana` vs `mlx5_core`)

The accelerated Virtual Function (VF) is the bonded **SLAVE** interface (named `enP*` on ConnectX, `ens*` on MANA). Check its driver:

```bash
# find the VF (bonded SLAVE) interface, then read its driver
VF=$(ip -o link show | awk -F': ' '/SLAVE/{print $2}' | awk '{print $1}' | head -n1)
ethtool -i "$VF" | grep '^driver'
```

- `driver: mana` → **ON MANA**
- `driver: mlx5_core` (or `mlx4_*`) → **NOT MANA** (Mellanox/ConnectX)

The primary interface (`eth0`) is always `hv_netvsc` in both cases — only the VF driver differs.

### 1c. Kernel check — is the MANA Ethernet driver available?

```bash
grep /mana*.ko /lib/modules/$(uname -r)/modules.builtin || find /lib/modules/$(uname -r)/kernel -name mana*.ko*
```

Expected (built-in or module present):

```
kernel/drivers/net/ethernet/microsoft/mana/mana.ko
```

**Kernel support:** MANA Ethernet drivers first landed upstream in **kernel 5.15+**. Kernel **6.2** adds InfiniBand/RDMA and DPDK. Kernels 5.15 / 6.1 need backported support. **DPDK on MANA requires kernel 6.14+** (or backported drivers).

### 1d. Traffic check — is traffic flowing through the accelerated VF?

Each vNIC with Accelerated Networking produces **two** interfaces (primary `ethN` + VF):

```bash
ip -br link
ethtool -S eth0 | grep -E "^\s*vf_"
```

```
     vf_rx_packets: 226418
     vf_rx_bytes: 99557501
     vf_tx_packets: 300422
     vf_tx_bytes: 76231291
     vf_tx_dropped: 0
```

If VF values are `0` or don't increment, you are **not** using the virtual function. (Note: `vf_*` counters exist on both MANA and ConnectX — they prove the accelerated data path, not MANA specifically. Confirm MANA via the driver/PCI checks above.)

### 1e. Authoritative datapath (netvsc's own statement)

```bash
sudo dmesg | grep -i "Data path switched" | tail -n2
```

```
hv_netvsc ... eth0: Data path switched to VF: ens1
```

The netvsc driver logs **which VF** the datapath is on. Combined with `ethtool -i <vf>` (`mana` vs `mlx5_core`), this is the definitive attribution of _which_ NIC carries traffic. To prove it live under load — and see driver-specific IRQs (`mana_q*` vs `mlx5_comp*`) and per-VF byte deltas — run [`../scripts/distinguish-vf-mana.sh`](../scripts/distinguish-vf-mana.sh). For a full per-VM verdict in one pass, run [`../scripts/validate-nva-mana.sh`](../scripts/validate-nva-mana.sh) (Linux) / [`../scripts/validate-nva-mana.ps1`](../scripts/validate-nva-mana.ps1) (Windows).

---

## 2. Windows

### 2a. Driver check — is the MANA adapter present?

```powershell
Get-NetAdapter
```

MANA is present when you see **Microsoft Azure Network Adapter**:

```
Name         InterfaceDescription                 ifIndex Status MacAddress         LinkSpeed
----         --------------------                 ------- ------ ----------         ---------
Ethernet     Microsoft Hyper-V Network Adapter        13 Up     00-0D-3A-AA-00-AA  200 Gbps
Ethernet 3   Microsoft Azure Network Adapter #2        8 Up     00-0D-3A-AA-00-AA  200 Gbps
```

### 2b. Hardware check — is the MANA PCI device present (even without driver)?

```powershell
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '^PCI\\VEN_1414&DEV_00BA&' }
```

```
Status Class         FriendlyName                                   InstanceId
------ -----         ------------                                   ----------
OK     MultiFunction Microsoft Azure Network Adapter Virtual Bus    PCI\VEN_1414...
```

**Interpretation:**

- Output present in **both** `Get-NetAdapter` and `Get-PnpDevice` → MANA working.
- Present in `Get-PnpDevice` but **not** `Get-NetAdapter` → hardware is MANA, but the **OS is missing MANA driver support**.
- **Blank/missing** in `Get-PnpDevice` → VM landed on hardware with a different network adapter (e.g., Mellanox `VEN_15B3`).

### 2c. Device Manager (GUI alternative)

Open **Device Manager → Network adapters → Microsoft Azure Network Adapter** → properties show the device is working properly.

### 2d. Traffic check — is traffic flowing through MANA?

```powershell
Get-NetAdapter | Where-Object InterfaceDescription -Like "*Microsoft Azure Network Adapter*" | Get-NetAdapterStatistics
```

If the MANA values are `0` or don't increment, you are **not** using the virtual function.

### 2e. Install Windows MANA drivers (if hardware present but driver missing)

Download: https://aka.ms/manawindowsdrivers (includes a readme with detailed instructions).

---

## Quick decision guide

| Observation                                       | Meaning                                                   | Action                                                                                    |
| ------------------------------------------------- | --------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| AN disabled                                       | Workload unaffected by MANA change                        | No action                                                                                 |
| VF driver `mana` + `00ba` + VF counters increment | On MANA, working                                          | General VM: no action. NVA: validate appliance behavior, consider a MANA-optimized series |
| `00ba` present, no accelerated VF exposed         | On MANA hardware, OS lacks MANA support → NetVSC fallback | Update OS/kernel or install driver; if an NVA degrades, consider `LegacyVMNVA`            |
| VF driver `mlx5_core` / no `00ba`                 | Not on MANA (ConnectX)                                    | General VM: no action. NVA: apply `LegacyVMNVA` before earliest placement date            |

> The `LegacyVMNVA` tag is **only** for Accelerated-Networking NVAs (firewalls/routers/SD-WAN) not yet confirmed MANA-compatible. General workloads (app/web/db) need **no action** — MANA transition is transparent. These in-guest checks report hardware/driver/AN facts; NVA classification comes from the ARG vendor/publisher or your CMDB.
