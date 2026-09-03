# Evidence Lab — Verify MANA NIC Status & Traffic (MVP, az CLI only)

> **Purpose:** Produce reproducible, customer-ready evidence that shows (a) a VM **on MANA** with the MANA VF active and traffic flowing through it, and (b) a VM **not on MANA** (ConnectX) and/or temporarily kept off MANA via an applied and enabled `LegacyVMNVA` opt-out. Capture NIC identity, driver, datapath, and traffic-counter evidence.
>
> **Accuracy note:** Detection commands are cross-checked with [verify-mana-nic.md](./verify-mana-nic.md) and the official pages in [references.md](./references.md). Captured Linux and control-plane results are identified below; Windows MANA AFTER evidence remains pending. Your placement outcome will vary.

---

## Read first — what is and isn't controllable

- **Azure controls hardware placement.** You **cannot** force a VM onto MANA hardware with a flag. A VM on an eligible series with a MANA-capable OS and Accelerated Networking (AN) _may_ land on MANA, and can be re-placed after a **stop-deallocate-and-start**.
- **Series determines the documented hardware model.** Eligible existing series may use Mellanox or MANA. Microsoft documents Intel v6 or later as running on MANA-capable hardware. In this lab only, `D4s_v5` stayed on ConnectX and `D4ds_v6` used MANA; this sample does not establish placement probability for other sizes, regions, or zones.
- For an applicable AN-enabled NVA, the documented temporary placement-avoidance mechanism is an **applied and enabled `LegacyVMNVA` tag** (see [implementation-legacyvmnva.md](./implementation-legacyvmnva.md)). It is honored only until May 31, 2027.
- This lab is **detection-and-evidence first**: deploy → detect actual placement → capture whatever state you observe.

---

## Prerequisites

- An Azure subscription, a VNet, and a subnet (you provide these).
- Permissions to create VMs/NICs (and, for the opt-out, assign Azure Policy + run remediation).
- Azure CLI signed in: `az login` and `az account set --subscription <subscription-id>`.

> **OS choice:** use an image whose distribution kernel supports MANA. MANA Ethernet drivers first appeared upstream in **Linux kernel 5.15**; kernel 6.2 added upstream support for features including InfiniBand/RDMA and DPDK. The current requirement to **run DPDK on MANA** is kernel **6.14+** or backports of the 6.14+ Ethernet and InfiniBand drivers. Confirm the distribution-specific minimum against the [supported OS list](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-overview#supported-operating-systems) and the [MANA DPDK requirements](https://learn.microsoft.com/en-us/azure/virtual-network/setup-dpdk-mana#dpdk-requirements-for-mana).

---

## Step 0 — Variables

```bash
RG="rg-mana-evidence"
LOC="<region>"                        # e.g., westus (public cloud)
SUBNET_ID="/subscriptions/<subscription-id>/resourceGroups/<network-rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>"
IMAGE="Canonical:ubuntu-24_04-lts:server:latest"   # gen2; verify MANA/kernel support
ADMIN="azureuser"

VM_MANA="vm-mana-v6"                  # documented MANA-based Intel v6 target
VM_CX="vm-mana-a"                     # eligible existing-series contrast; detect actual placement
VM_OPTOUT="vm-legacy-b"               # opt-out control (LegacyVMNVA)
```

`az group create -n "$RG" -l "$LOC"` if you need a dedicated RG.

---

## Step 1 — Deploy the VMs (AN enabled, no public IP)

Using `--public-ip-address ""` + `az vm run-command` avoids opening inbound SSH.

```bash
# MANA candidate — v6 size
az vm create -g "$RG" -n "$VM_MANA" --image "$IMAGE" --size Standard_D4ds_v6 \
  --subnet "$SUBNET_ID" --admin-username "$ADMIN" --generate-ssh-keys \
  --accelerated-networking true --public-ip-address "" --nsg ""

# Contrast — v5 size
az vm create -g "$RG" -n "$VM_CX" --image "$IMAGE" --size Standard_D4s_v5 \
  --subnet "$SUBNET_ID" --admin-username "$ADMIN" --generate-ssh-keys \
  --accelerated-networking true --public-ip-address "" --nsg ""

# Opt-out control — v5 size
az vm create -g "$RG" -n "$VM_OPTOUT" --image "$IMAGE" --size Standard_D4s_v5 \
  --subnet "$SUBNET_ID" --admin-username "$ADMIN" --generate-ssh-keys \
  --accelerated-networking true --public-ip-address "" --nsg ""
```

---

## Step 2 — Detect NIC placement (run on each VM)

```bash
az vm run-command invoke -g "$RG" -n "$VM_MANA" --command-id RunShellScript \
  --scripts @scripts/detect-mana.sh --query "value[0].message" -o tsv
```

Interpretation (see [verify-mana-nic.md](./verify-mana-nic.md)):

- `lspci` `Device 00ba` + VF driver **`mana`** → **ON MANA**.
- `lspci` `Mellanox … ConnectX-5` + VF driver **`mlx5_core`** → **NOT MANA**.

---

## Step 3 — Generate traffic and capture VF counters

```bash
az vm run-command invoke -g "$RG" -n "$VM_MANA" --command-id RunShellScript \
  --scripts @scripts/traffic-capture.sh --parameters "<target-private-ip>" \
  --query "value[0].message" -o tsv
```

VF byte/packet counters should increase during the test, indicating that traffic used the accelerated VF. The counters do not identify MANA by themselves; pair them with driver and PCI evidence.

---

## Step 4 — Apply the `LegacyVMNVA` opt-out (control VM)

Follow [implementation-legacyvmnva.md](./implementation-legacyvmnva.md): assign policy → remediate → **reapply**. For a non-Marketplace test image, apply the tag directly then reapply:

```bash
az vm update -g "$RG" -n "$VM_OPTOUT" --set tags.LegacyVMNVA=true
az vm reapply -g "$RG" -n "$VM_OPTOUT"
az vm show -g "$RG" -n "$VM_OPTOUT" --query "tags" -o json
```

---

## Step 5 — Reallocate and re-detect an eligible existing-series VM

Documented behavior: existing VMs may land on MANA hardware after a stop-deallocate-and-start. This operation does not guarantee MANA placement.

```bash
az vm deallocate -g "$RG" -n "$VM_MANA"
az vm start -g "$RG" -n "$VM_MANA"
# then re-run Step 2 detection
```

---

## Step 6 — Cleanup

```bash
az group delete -n "$RG" --yes --no-wait
```

---

## MANA-enabled vs NOT — validation comparison

The direct NIC-family discriminator is the **bound VF driver**:

| Signal                | Command           | ✅ MANA                             | ❌ NOT MANA (ConnectX)           |
| --------------------- | ----------------- | ----------------------------------- | -------------------------------- |
| PCI device (Linux)    | `lspci`           | `Microsoft Corporation Device 00ba` | `Mellanox … ConnectX-5 VF`       |
| **VF driver (Linux)** | `ethtool -i <vf>` | **`mana`**                          | **`mlx5_core`**                  |
| VF interface name     | `ip -br link`     | typically **`ens1`**                | typically `enP*`                 |
| VF relation           | `ip -o link show` | `CHILD` or legacy NetVSC `SLAVE`    | `CHILD` or legacy NetVSC `SLAVE` |
| Primary iface driver  | `ethtool -i eth0` | `hv_netvsc`                         | `hv_netvsc` (same)               |
| VF traffic counters   | `ethtool -S eth0` | `vf_*` increment                    | `vf_*` increment (same names)    |
| Windows adapter       | `Get-NetAdapter`  | `Microsoft Azure Network Adapter`   | `Mellanox …`                     |
| Windows PCI           | `Get-PnpDevice`   | `PCI\VEN_1414&DEV_00BA&`            | `VEN_15B3` (Mellanox)            |

**Third state:** a VM on MANA hardware whose OS lacks MANA support shows `00ba`, but the MANA driver exposes
no network interface; the VF might still be visible. Traffic falls back to NetVSC. Microsoft expects broadly
comparable ConnectX-class performance, but high concurrent-connection workloads can degrade. `LegacyVMNVA`
applies only to eligible AN-enabled NVAs when the vendor directs an opt-out or degradation is observed.

---

## Reference results (from a real run)

Anonymized captured and expected-output examples are in [sample-outputs.md](./sample-outputs.md). Two Linux evidence points specific to this lab:

- **Traffic evidence (MANA VM):** flood ping moved VF counters by ~5,000 packets each way (`vf_rx_packets` / `vf_tx_packets`). The bound `mana` driver and MANA PCI device attributed that accelerated VF to MANA.
- **Allocation observation:** after `deallocate → start`, this lab observed a different guest VF PCI address and reset counters. Those signals show guest device re-enumeration and fresh runtime state; they do not identify the physical host or prove a host change. Driver and device-family checks still showed ConnectX on `D4s_v5` and MANA on `D4ds_v6`.

---

## Findings & gotchas

| #   | Issue                                                   | Guidance                                                                                                                      |
| --- | ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Existing-series placement cannot be forced**          | Eligible existing series may use Mellanox or MANA. Reallocate and detect; never claim the command "enables MANA."             |
| 2   | **Use documented series behavior, not inferred odds**   | Intel v6 or later is MANA-based. The observed `D4s_v5`/`D4ds_v6` contrast is one lab result, not a probability model.         |
| 3   | **VF names are not stable identifiers**                 | Discover every `CHILD`, plus legacy `SLAVE` only when its master uses `hv_netvsc`; never hardcode `ens1` or `enP*`.           |
| 4   | **`ethtool -i <vf>` directly identifies the driver**    | `mana` = MANA, `mlx5_core` = ConnectX. `lspci 00ba` corroborates.                                                             |
| 5   | **VF counter names are identical on ConnectX and MANA** | Increasing `vf_*` counters show use of the accelerated data path, not MANA specifically; confirm with driver/PCI.             |
| 6   | **Policy targets specific Marketplace products**        | A publisher hit alone is insufficient. Verify the live product match; coordinate non-Marketplace tagging with the vendor/MSP. |
| 7   | **No public IP / inbound SSH needed**                   | Use `az vm run-command invoke ... --command-id RunShellScript` to run scripts in-guest.                                       |
| 8   | **Run in the correct subscription**                     | `az account show` before running; `az account set --subscription <id>` to switch.                                             |

### One-line summary

> In this lab, with the same OS/kernel and region, `D4s_v5` used **ConnectX-5** (`mlx5_core`) and `D4ds_v6` used **MANA** (`00ba`, driver `mana`). Treat the v5 result as an observation; eligible existing series may use either NIC family. Microsoft documents Intel v6 or later as MANA-based. Confirm the actual VF driver after allocation.
