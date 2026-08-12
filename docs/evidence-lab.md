# Evidence Lab — Verify MANA NIC Status & Traffic (MVP, az CLI only)

> **Purpose:** Produce reproducible, customer-ready evidence that shows (a) a VM **on MANA** with the MANA VF active and traffic flowing through it, and (b) a VM **not on MANA** (ConnectX) and/or kept off MANA via the `LegacyVMNVA` opt-out. Capture NIC status + traffic counters as proof.
>
> **Accuracy note:** Detection commands are cross-checked with [verify-mana-nic.md](./verify-mana-nic.md) and the official pages in [references.md](./references.md). Reference results below were captured on a real run; your placement outcome will vary (see caveat).

---

## Read first — what is and isn't controllable

- **Azure controls hardware placement.** You **cannot** force a VM onto MANA hardware with a flag. A VM on an eligible series with a MANA-capable OS and Accelerated Networking (AN) _may_ land on MANA, and can be re-placed after a **stop-deallocate-and-start**.
- **VM size strongly influences the outcome.** In testing, an older eligible size (`D4s_v5`) stayed on ConnectX even after re-rolls, while a newer MANA-optimized size (`D4ds_v6`) landed on MANA on first boot. Newer (v6) sizes are far more likely to get MANA — still not guaranteed.
- **The only supported lever to guarantee "off MANA"** is the **`LegacyVMNVA` opt-out** (see [implementation-legacyvmnva.md](./implementation-legacyvmnva.md)).
- This lab is **detection-and-evidence first**: deploy → detect actual placement → capture whatever state you observe.

---

## Prerequisites

- An Azure subscription, a VNet, and a subnet (you provide these).
- Permissions to create VMs/NICs (and, for the opt-out, assign Azure Policy + run remediation).
- Azure CLI signed in: `az login` and `az account set --subscription <subscription-id>`.

> **OS choice:** use an image whose kernel supports MANA. MANA Ethernet drivers are upstream in **Linux kernel 5.15+** (6.2 adds IB/RDMA & DPDK). Confirm against the [supported OS list](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-overview#supported-operating-systems). A recent Ubuntu LTS (kernel ≥ 6.2) is a reasonable default; **verify** rather than assume.

---

## Step 0 — Variables

```bash
RG="rg-mana-evidence"
LOC="<region>"                        # e.g., westus (public cloud)
SUBNET_ID="/subscriptions/<subscription-id>/resourceGroups/<network-rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>"
IMAGE="Canonical:ubuntu-24_04-lts:server:latest"   # gen2; verify MANA/kernel support
ADMIN="azureuser"

VM_MANA="vm-mana-v6"                  # MANA-optimized v6 size (more likely to get MANA)
VM_CX="vm-mana-a"                     # older v5 size (likely ConnectX) — contrast
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

VF byte/packet counters should jump by the number of packets sent, proving traffic rides the accelerated VF.

---

## Step 4 — Apply the `LegacyVMNVA` opt-out (control VM)

Follow [implementation-legacyvmnva.md](./implementation-legacyvmnva.md): assign policy → remediate → **reapply**. For a non-Marketplace test image, apply the tag directly then reapply:

```bash
az vm update -g "$RG" -n "$VM_OPTOUT" --set tags.LegacyVMNVA=true
az vm reapply -g "$RG" -n "$VM_OPTOUT"
az vm show -g "$RG" -n "$VM_OPTOUT" --query "tags" -o json
```

---

## Step 5 — Re-roll placement (if the candidate didn't get MANA)

Documented behavior: existing VMs can move to MANA hardware after a stop-deallocate-and-start.

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

The definitive discriminator is the **bound VF driver**:

| Signal                | Command           | ✅ MANA                             | ❌ NOT MANA (ConnectX)        |
| --------------------- | ----------------- | ----------------------------------- | ----------------------------- |
| PCI device (Linux)    | `lspci`           | `Microsoft Corporation Device 00ba` | `Mellanox … ConnectX-5 VF`    |
| **VF driver (Linux)** | `ethtool -i <vf>` | **`mana`**                          | **`mlx5_core`**               |
| VF interface name     | `ip -br link`     | typically **`ens1`** (SLAVE)        | typically `enP*` (SLAVE)      |
| Primary iface driver  | `ethtool -i eth0` | `hv_netvsc`                         | `hv_netvsc` (same)            |
| VF traffic counters   | `ethtool -S eth0` | `vf_*` increment                    | `vf_*` increment (same names) |
| Windows adapter       | `Get-NetAdapter`  | `Microsoft Azure Network Adapter`   | `Mellanox …`                  |
| Windows PCI           | `Get-PnpDevice`   | `PCI\VEN_1414&DEV_00BA&`            | `VEN_15B3` (Mellanox)         |

**Third state:** a VM on MANA hardware whose OS lacks the MANA driver shows `00ba` in `lspci` but exposes **no accelerated VF** (only `hv_netvsc`) → traffic falls back to NetVSC with ConnectX-class performance. This is the degradation case the `LegacyVMNVA` exception addresses.

---

## Reference results (anonymized, from a real run)

Ubuntu 24.04 (kernel 6.17.x-azure, `mana.ko` present), public-cloud region, AN enabled, no public IP:

| VM (size)               | `lspci`       | VF iface / driver    | Verdict                          |
| ----------------------- | ------------- | -------------------- | -------------------------------- |
| v6 (`D4ds_v6`)          | `Device 00ba` | `ens1` / **`mana`**  | ✅ ON MANA                       |
| v5 (`D4s_v5`)           | `ConnectX-5`  | `enP*` / `mlx5_core` | ❌ NOT MANA                      |
| v5 (`D4s_v5`) + opt-out | `ConnectX-5`  | `enP*` / `mlx5_core` | ❌ NOT MANA (`LegacyVMNVA=True`) |

- **Traffic proof (MANA VM):** flood ping moved VF counters by ~5,000 packets each way (`vf_rx_packets` and `vf_tx_packets`), confirming traffic on the MANA VF.
- **Re-roll proof:** `deallocate → start` changes the VF PCI address and resets counters — confirming Azure re-placed the VM. The v5 VMs stayed on ConnectX across re-rolls; the v6 VM stayed on MANA across a restart.

---

## Findings & gotchas

| #   | Issue                                                   | Guidance                                                                                                                        |
| --- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **MANA placement cannot be forced**                     | Azure controls it. Prefer a **v6** size to raise MANA odds; re-roll via deallocate→start; never claim a command "enables MANA". |
| 2   | **VM size drives MANA likelihood**                      | `D4s_v5` never got MANA even after re-rolls; `D4ds_v6` got MANA on first boot.                                                  |
| 3   | **MANA VF is named `ens1`, not `enP*`**                 | Match the bonded **SLAVE** interface generically (any name). `scripts/detect-mana.sh` does this.                                |
| 4   | **`ethtool -i <vf>` is the definitive check**           | `mana` = MANA, `mlx5_core` = ConnectX. `lspci 00ba` corroborates.                                                               |
| 5   | **VF counter names are identical on ConnectX and MANA** | `vf_*` counters prove the accelerated data path, not MANA specifically — confirm with driver/PCI.                               |
| 6   | **Built-in policy only tags Marketplace NVA images**    | It won't auto-tag a plain VM. Apply the tag directly for test/non-Marketplace VMs; coordinate with vendor/MSP otherwise.        |
| 7   | **No public IP / inbound SSH needed**                   | Use `az vm run-command invoke ... --command-id RunShellScript` to run scripts in-guest.                                         |
| 8   | **Run in the correct subscription**                     | `az account show` before running; `az account set --subscription <id>` to switch.                                               |

### One-line summary

> Same OS/kernel, same region: an older eligible size (`D4s_v5`) landed on **ConnectX-5** (`mlx5_core`), while a MANA-optimized `D4ds_v6` landed on **MANA** (`00ba`, driver `mana`). Definitive check = **`ethtool -i <vf>`**. The `LegacyVMNVA` tag + reapply keeps an NVA off MANA until migration. Placement is Azure-controlled; newer (v6) sizes are far more likely to get MANA.
