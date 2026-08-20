# Azure MANA + NVA Toolkit

**Assess, validate, and safely transition Network Virtual Appliance (NVA) workloads as Azure expands the Microsoft Azure Network Adapter (MANA) to existing VM series — with hands-on detection scripts, the `LegacyVMNVA` opt-out, and reproducible evidence.**

As Azure expands MANA (a component of Azure Boost) to existing VM series, VMs in eligible series may be placed on MANA-capable hardware. **Most workloads transition without issue**, but **NVAs need validation** because they depend directly on the underlying network hardware and drivers. This toolkit helps you check what your VMs are running on, apply the temporary `LegacyVMNVA` exception if needed, and plan migration.

> **Accuracy & sources:** every fact, date, tag, policy ID, and command is grounded in official Microsoft Learn (see [docs/references.md](./docs/references.md)). Re-verify dates against the live docs before relying on them.

## TL;DR

- Azure is expanding **MANA** (part of Azure Boost) to **existing** VM series. Eligible VMs may land on MANA-capable hardware after a **stop-deallocate-start** or a **maintenance event**.
- **General workloads transition transparently — no action.** **NVAs** (firewalls / routers / SD-WAN) using **Accelerated Networking** need validation because they depend directly on the NIC driver.
- If an NVA isn't confirmed MANA-compatible, apply the temporary **`LegacyVMNVA`** tag (honored to **May 31, 2027**) to defer MANA placement, then migrate to a MANA-ready config.
- This toolkit runs the loop end-to-end: **inventory → verify on host → safeguard (if needed) → migrate**, with reproducible evidence.

**Official refs:** [MANA overview](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-overview) · [existing VM series](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-existing-sizes) · [NVA opt-out (`LegacyVMNVA`)](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-network-virtual-appliance-opt-out).

## How it works

```mermaid
flowchart LR
  A["1 Inventory (ARG): vendor, OS, AN, NVA class, tag"] --> B{"AN on and NVA or unknown?"}
  B -->|"No: general, AN off, or AKS"| Z["No action"]
  B -->|"Yes or review"| C["2 Verify on host: driver mana vs mlx5, traffic"]
  C --> D{"MANA compatible?"}
  D -->|"Yes"| E["Allow MANA"]
  D -->|"No"| F["3 Apply LegacyVMNVA, reapply, then migrate"]
  E --> G["4 Govern and re-scan"]
  F --> G
  G -.->|"new VMs or drift"| A
```

The classifier is **conservative**: general/AN-off/AKS → no action; everything else (NVA, unlisted vendor, unknown/custom image) → **review on host** so no vendor is silently skipped. Governance model: [docs/governance.md](./docs/governance.md).

### Governance process (in depth)

For customers and reviewers who want the full decision path — discover, verify, allow-or-safeguard, migrate, then govern at scale in a continuous loop:

```mermaid
flowchart TD
  A["1 Discover and assess (ARG): vendor, OS, AN, NVA class, tag, verdict"] --> B{"AN on and NVA or unknown, not AKS?"}
  B -->|"No: general, AN off, or AKS"| Z["No action"]
  B -->|"Yes or review"| C["2 Verify on host: driver mana vs mlx5, Linux or Windows, traffic"]
  C --> D{"MANA compatible?"}
  D -->|"Yes"| E["Allow MANA and capture evidence"]
  D -->|"No"| F["3 Apply LegacyVMNVA (policy or manual), then reapply"]
  F --> G["Migrate to MANA-ready config, then remove tag"]
  E --> H["4 Govern: policy at scale, drift scan, timeline gates"]
  G --> H
  H -.->|"new VMs or drift"| A
```

Full continuous-governance model (scale enforcement, drift, vendor register, RACI, timeline gates): [docs/governance.md](./docs/governance.md).

## Prerequisites

- **Azure CLI** signed in: `az login`; then `az account set --subscription <subscription-id>`.
- **Resource Graph extension** (for inventory queries): `az extension add -n resource-graph`.
- **Permissions:** Reader for inventory; **Virtual Machine Contributor** to run `az vm run-command`; **Resource Policy Contributor** (plus a role for the policy's managed identity) to assign/remediate the opt-out policy.
- In-guest checks run via `az vm run-command` — **no public IP or inbound SSH required**.

## Step 1 — Find candidates at scale (Azure Resource Graph)

```bash
az extension add -n resource-graph            # one-time
az graph query -q "@scripts/inventory-nva-vms.kql" --first 1000 \
  --query "data[].{Sub:subscriptionId, RG:resourceGroup, VM:VMName, Vendor:Vendor, NVA:NVAClass, ImageSource:ImageSource, OS:OSType, OSVersion:OSVersion, Size:VMSize, AN:AcceleratedNetworking, Tag:LegacyVMNVATag, Verdict:Assessment}" \
  -o table
```

One row **per VM** (multi-NIC safe) with the identity to drive Step 2 (**Sub + RG + VM**), **Vendor** (Marketplace plan-publisher aware), **NVAClass** (policy-scoped / marketplace-unlisted / keyword-hint / custom-unknown / general), **ImageSource**, **OS + OSVersion** (drives `.sh` vs `.ps1`), NIC-accurate **AN**, the **tag**, and a **verdict**. Also run [scripts/inventory-nva-vmss.kql](./scripts/inventory-nva-vmss.kql) (scale sets, AKS-aware) and [scripts/discover-vendors.kql](./scripts/discover-vendors.kql) to **enumerate every vendor / plan / OS so no vendor is skipped**. Details: [docs/inventory-arg.md](./docs/inventory-arg.md).

> The KQL selects more columns than any one `--query` shows (`PlanPublisher`, `PlanProduct`, `Offer`, `Sku`, `location`). The `--query` is a **client-side filter** — Resource Graph Explorer shows all fields.
> ARG shows candidates only — it **cannot** confirm MANA hardware, nor that a tag was enabled via reapply. Do that in Step 2.

## Step 2 — Is a given VM on MANA? (driver + traffic — the durable check)

The **`LegacyVMNVA` tag is a temporary workaround** (honored only to May 31, 2027). The **durable signal is on the host**: which driver is bound to the accelerated VF (`mana` vs `mlx5_core`) and whether traffic actually flows over it. Use the Sub + RG + VM from Step 1 to target each VM directly.

**Pick the script by the `OS` column from Step 1** — the scripts are OS-specific because they call OS-native tools (`lspci`/`ethtool` on Linux; `Get-NetAdapter`/`Get-PnpDevice` on Windows):

| OS (from Step 1) | `--command-id`        | Scripts to use                                                                  |
| ---------------- | --------------------- | ------------------------------------------------------------------------------- |
| **Linux**        | `RunShellScript`      | `detect-mana.sh`, `validate-nva-mana.sh`, `distinguish-vf-mana.sh` (`.sh` only) |
| **Windows**      | `RunPowerShellScript` | `detect-mana.ps1`, `validate-nva-mana.ps1` (`.ps1` only)                        |

So yes — **`.sh` runs on Linux exclusively, `.ps1` on Windows exclusively.** Running the wrong one fails (the tools don't exist on the other OS). Appliance OSes (PAN-OS, FortiOS, etc.) run neither — use the vendor matrix.

```bash
az account set --subscription <Sub>          # from Step 1
# Linux quick check (driver + lspci + VF counters):
az vm run-command invoke -g <RG> -n <VM> --command-id RunShellScript \
  --scripts @scripts/detect-mana.sh --query "value[0].message" -o tsv
```

For a full per-VM verdict (tag + MANA hardware + driver + authoritative netvsc datapath + VF functioning), use the **validator**; to prove _which_ NIC carried live traffic under load, use the **distinguisher**:

```bash
# Full validator (Linux)
az vm run-command invoke -g <RG> -n <VM> --command-id RunShellScript \
  --scripts @scripts/validate-nva-mana.sh --query "value[0].message" -o tsv

# Attribute live traffic to MANA vs Mellanox (flood-ping a second VM's private IP)
az vm run-command invoke -g <RG> -n <VM> --command-id RunShellScript \
  --scripts @scripts/distinguish-vf-mana.sh --parameters "<target-private-ip>" --query "value[0].message" -o tsv
```

**Windows** uses `RunPowerShellScript` + [scripts/detect-mana.ps1](./scripts/detect-mana.ps1) (quick) or [scripts/validate-nva-mana.ps1](./scripts/validate-nva-mana.ps1) (full):

```bash
az vm run-command invoke -g <RG> -n <VM> --command-id RunPowerShellScript \
  --scripts @scripts/validate-nva-mana.ps1 --query "value[0].message" -o tsv
```

Read the result:

| VF driver (`ethtool -i <vf>`) | `lspci`                 | Meaning         |
| ----------------------------- | ----------------------- | --------------- |
| `mana`                        | `Device 00ba`           | **On MANA**     |
| `mlx5_core`                   | `Mellanox … ConnectX-5` | **Not on MANA** |

The **authoritative** "which VF carries traffic" signal is the netvsc log line `hv_netvsc … eth0: Data path switched to VF: <name>` (`sudo dmesg | grep "Data path switched"`). The `vf_*` counters prove traffic is _accelerated_ but are identical on MANA and Mellanox — attribute to MANA via the driver/`dmesg`. Real outputs (Linux + Windows, MANA vs not, traffic before/after): [docs/sample-outputs.md](./docs/sample-outputs.md).

> **Third-party appliances (Cisco, Palo Alto, Fortinet, Check Point, F5):** their OS has no standard shell, so `lspci`/`ethtool` won't run. Validate via the vendor's MANA/Accelerated Networking compatibility matrix + a support case, and the appliance's own CLI. See [docs/inventory-arg.md](./docs/inventory-arg.md#third-party-nvas-cisco-palo-alto-etc--non-windowslinux-images).

## What's inside

| Path                                                                       | Purpose                                                                       |
| -------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| [docs/facts-and-timeline.md](./docs/facts-and-timeline.md)                 | What MANA is, eligible VM series, placement dates, `LegacyVMNVA`, ODCR        |
| [docs/faq.md](./docs/faq.md)                                               | FAQ: AN-disabled action, tag mechanism/dates, non-Marketplace NVAs, ODCR, v6+ |
| [docs/inventory-arg.md](./docs/inventory-arg.md)                           | Inventory NVA candidates at scale with Azure Resource Graph (multi-NIC safe)  |
| [docs/verify-mana-nic.md](./docs/verify-mana-nic.md)                       | Verify MANA (Portal, Linux, Windows) — the definitive checks                  |
| [docs/implementation-legacyvmnva.md](./docs/implementation-legacyvmnva.md) | Apply the opt-out (policy → remediate → reapply → verify → roll back), az CLI |
| [docs/governance.md](./docs/governance.md)                                 | Continuous governance: scale enforcement, drift, vendor register, RACI, gates |
| [docs/evidence-lab.md](./docs/evidence-lab.md)                             | Reproducible MVP lab: deploy, detect, capture traffic, compare MANA vs not    |
| [docs/sample-outputs.md](./docs/sample-outputs.md)                         | Real (anonymized) script/query outputs: Linux, Windows, traffic, ARG          |
| [docs/references.md](./docs/references.md)                                 | Public Microsoft references + verified key values                             |

**Scripts** (`scripts/`) — run in-guest via `az vm run-command` (no SSH/RDP), or the `.kql` in Resource Graph Explorer:

- **Inventory:** [`inventory-nva-vms.kql`](./scripts/inventory-nva-vms.kql), [`inventory-nva-vmss.kql`](./scripts/inventory-nva-vmss.kql) — classify candidates at scale (Sub+RG+VM, NVAClass, ImageSource, OS).
- **Discovery:** [`discover-vendors.kql`](./scripts/discover-vendors.kql) — enumerate **every** vendor / plan / OS so no vendor is missed.
- **Quick detect:** [`detect-mana.sh`](./scripts/detect-mana.sh), [`detect-mana.ps1`](./scripts/detect-mana.ps1) — driver + `lspci` + VF counters.
- **Full validator:** [`validate-nva-mana.sh`](./scripts/validate-nva-mana.sh), [`validate-nva-mana.ps1`](./scripts/validate-nva-mana.ps1) — tag + hardware + driver + netvsc datapath + functioning + verdict.
- **Traffic:** [`distinguish-vf-mana.sh`](./scripts/distinguish-vf-mana.sh) (MANA vs Mellanox under load) · [`traffic-capture.sh`](./scripts/traffic-capture.sh) (VF counters before/after).

## Recommended actions (summary)

1. Identify NVA workloads on MANA-eligible VM series; confirm whether Accelerated Networking is enabled. If not enabled, no action is required.
2. Confirm MANA compatibility with your NVA vendor (VM series, OS, drivers, image version).
3. **If an NVA is not confirmed MANA-compatible, apply the `LegacyVMNVA` opt-out proactively — don't wait for a performance hit** (which can be severe and cause an outage). It keeps the NVA off MANA hardware until you validate compatibility and migrate. See [when / why / how / when-not](./docs/implementation-legacyvmnva.md#when-to-use--when-not-to-use).
4. Assign the built-in `LegacyVMNVA` Azure Policy; for existing resources, remediate to add the tag, then **reapply** to enable it. New in-scope deployments get the tag automatically.
5. Roll out gradually with safe-deployment practices; validate app + network behavior.
6. Migrate to a MANA-compatible configuration and remove the exception when compatibility is confirmed.

**Key dates:** earliest MANA placement (public cloud) — **May 26, 2026** for Intel v5 + Cobalt 100 v6. Other eligible series (incl. **Dsv2/Dv2/Bsv2/Av2, Dsv3/Dsv4, Fsv2, Ls**) are currently **"Timeline under review"** — no confirmed date. The `LegacyVMNVA` tag is honored **until May 31, 2027**. See [docs/facts-and-timeline.md](./docs/facts-and-timeline.md).

## Important notes

- **Placement is Azure-controlled** — you cannot force a VM onto MANA. Newer (v6) sizes are far more likely to land on MANA.
- **`LegacyVMNVA` is a situational safeguard, not the goal** — a documented process for **when / why / how (and when not)** to defer MANA placement. Apply it **proactively** to NVAs not yet confirmed MANA-compatible; **don't** apply it broadly, to MANA-compatible workloads, to AN-disabled VMs, or to AKS pools. Details: [implementation-legacyvmnva.md](./docs/implementation-legacyvmnva.md#when-to-use--when-not-to-use).
- The built-in policy auto-tags only **Marketplace NVA** images. For NVAs acquired outside Marketplace or via a managed service, coordinate tag deployment with the vendor/MSP.

## License

[Apache-2.0](./LICENSE).

> This toolkit is provided as-is for guidance. Confirm all behavior against official Microsoft documentation for your environment before production use.
