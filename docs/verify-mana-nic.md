# How to Verify Whether a VM Is on MANA-Capable Hardware

> Commands and outputs below are taken from the official Microsoft Learn pages. See [references.md](./references.md).
> **Verified:** 2026-09-03.

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

### 1b. Driver check — direct NIC-family discriminator (`mana` vs `mlx5_core`)

The accelerated Virtual Function (VF) may appear as `CHILD` on current kernels or as `SLAVE` on older NetVSC paths. For a `SLAVE`, confirm that its master uses `hv_netvsc` so an ordinary bond member is not misclassified. Names such as `enP*` and `ens*` are observations, not stable identifiers.

```bash
# inspect all relationships; do not select only the first interface
ip -o link show | grep -E '<[^>]*(CHILD|SLAVE)[^>]*>'

# run the multi-NIC-safe discovery and driver checks
bash scripts/detect-mana.sh
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

**Kernel support:** MANA Ethernet drivers first landed upstream in **kernel 5.15**. Kernel **6.2** added upstream support for features including InfiniBand/RDMA and DPDK; earlier or forked 5.15/6.1 kernels require backported support. The current requirement to **run DPDK on MANA** is kernel **6.14+** or backports of the 6.14+ Ethernet and InfiniBand drivers.

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

### 1e. NetVSC-reported datapath

```bash
sudo dmesg | grep -i "Data path switched" | tail -n2
```

```
hv_netvsc ... eth0: Data path switched to VF: ens1
```

The netvsc driver logs **which VF** it selected. Combine that mapping with `ethtool -i <vf>` (`mana` vs `mlx5_core`) and live counter deltas to attribute the tested traffic path. To collect driver-specific IRQs (`mana_q*` vs `mlx5_comp*`) and per-VF byte deltas under load, run [`../scripts/distinguish-vf-mana.sh`](../scripts/distinguish-vf-mana.sh). For a full per-VM verdict in one pass, run [`../scripts/validate-nva-mana.sh`](../scripts/validate-nva-mana.sh) (Linux) / [`../scripts/validate-nva-mana.ps1`](../scripts/validate-nva-mana.ps1) (Windows).

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

Download: <https://aka.ms/manawindowsdrivers> (includes a readme with detailed instructions).

---

## Quick decision guide

| Observation                                       | Meaning                                                   | Action                                                                                    |
| ------------------------------------------------- | --------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| AN disabled on the Azure NIC resource             | Workload unaffected by the AN hardware transition         | No MANA action                                                                            |
| VF driver `mana` + `00ba` + VF counters increment | On MANA, working                                          | General VM: no action. NVA: validate appliance behavior, consider a MANA-optimized series |
| `00ba` present, no accelerated VF exposed         | On MANA hardware, OS lacks MANA support → NetVSC fallback | Update OS/kernel or install driver; if an NVA degrades, consider `LegacyVMNVA`            |
| VF driver `mlx5_core` / no `00ba`                 | Not on MANA (ConnectX)                                    | Review support and pilot before placement changes; tag only if degraded/provider-directed |

> The `LegacyVMNVA` tag is **only** for eligible Accelerated-Networking NVAs (firewalls/routers/SD-WAN) when
> the vendor directs an opt-out or degradation is observed. General workloads do not use this NVA exception;
> verify OS support and a representative workload baseline. Azure NIC configuration is authoritative for AN;
> guest checks report hardware, driver, and datapath evidence.
