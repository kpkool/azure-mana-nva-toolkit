# Inventory NVA Candidates at Scale (Azure Resource Graph)

Before checking individual VMs, use **Azure Resource Graph (ARG)** to list every VM with its **vendor (image publisher)**, **size**, **OS**, **NIC count**, and **Accelerated Networking (AN) status** across all accessible subscriptions. This finds your **candidate** NVA workloads fast.

> **What ARG can and can't tell you:**
>
> - ✅ Vendor/publisher, size, OS, per-NIC **Accelerated Networking** (the MANA precondition), and the **`LegacyVMNVA` tag**.
> - ❌ It **cannot** tell you whether a VM is currently on **MANA hardware** — that is host placement, only visible **in-guest** (confirm with [verify-mana-nic.md](./verify-mana-nic.md) / `scripts/detect-mana.sh`).
> - ❌ A present `LegacyVMNVA` tag does **not** prove it was **enabled** — enabling requires a **reapply** operation (see [implementation-legacyvmnva.md](./implementation-legacyvmnva.md)).

## Query (VMs)

Use [`../scripts/inventory-nva-vms.kql`](../scripts/inventory-nva-vms.kql). Runs in **Azure Resource Graph Explorer** (portal) or via CLI:

```bash
az extension add -n resource-graph            # one-time (CLI only)
az graph query -q "@scripts/inventory-nva-vms.kql" --first 1000 \
  --query "data[].{Sub:subscriptionId, RG:resourceGroup, VM:VMName, Vendor:Vendor, Size:VMSize, OS:OSType, NICs:NICCount, AN:AcceleratedNetworking, Tag:LegacyVMNVATag, Verdict:Assessment}" \
  -o table
```

Columns: **Sub + RG + VM** (the identity you feed straight into Step 2 per VM), **AN** (per-NIC accurate), **LegacyVMNVATag** (`True`/`Not set`), and **Assessment** (a triage verdict). The KQL always selects `subscriptionId` and `resourceGroup`; just keep them in the `--query` projection so every row is directly runnable.

## Why this differs from the common one-liner (multiple-NIC fix)

A frequently shared version joins VMs directly to **individual NICs**:

```kusto
| join kind=leftouter ( Resources | where type =~ 'microsoft.network/networkinterfaces' ... ) on vmId
```

That produces **one row per NIC**, so:

- A **multi-NIC VM appears multiple times** (double-counted).
- If NICs differ (one AN-enabled, one not), the VM shows **conflicting rows** with no clear status.

This toolkit's query **summarizes NICs per VM first**, then joins — so each VM is **exactly one row** and mixed AN is surfaced explicitly:

| NIC situation   | Reported `AcceleratedNetworking` |
| --------------- | -------------------------------- |
| No NIC found    | `No NIC found`                   |
| All NICs AN off | `Disabled`                       |
| All NICs AN on  | `Enabled`                        |
| Some NICs AN on | `Partial (n/m)`                  |

`Partial` matters: MANA impact is per-NIC/hardware, so a mixed VM needs closer review.

## Interpreting results

- **Vendor** = image publisher. Marketplace NVAs show the vendor (e.g., `paloaltonetworks`, `checkpoint`, `fortinet`).
- **Empty Vendor** = custom image, shared image gallery, or disk-based VM — common for NVAs **not** from Marketplace. These won't be auto-tagged by the built-in `LegacyVMNVA` policy; handle via the vendor/your tooling (see [implementation-legacyvmnva.md](./implementation-legacyvmnva.md)).
- **AN = Disabled** → no MANA action needed for that VM.
- **AN = Enabled / Partial** on a MANA-eligible size → **candidate**; confirm on the box with `scripts/detect-mana.sh`.
- **LegacyVMNVATag = True** → opt-out tag present; confirm it was **enabled via reapply**, then plan migration.
- **Assessment** = triage verdict (control-plane only): `No action - AN disabled`, `Candidate - verify on host`, `Opt-out tag present - confirm reapply`, or `AKS-managed - not impacted`.

## Sample output (anonymized)

```
RG                VM         Size              AN        Tag      Verdict
----------------  ---------  ----------------  --------  -------  ---------------------------------------------------------
rg-net-01         web-01     Standard_B4ms     Disabled  Not set  No action - AN disabled
rg-net-01         nva-fw-01  Standard_D4s_v5   Enabled   Not set  Candidate - verify on host (detect-mana.sh)
rg-net-01         nva-fw-02  Standard_D4s_v5   Partial   Not set  Candidate - verify on host (detect-mana.sh)
rg-net-01         nva-fw-03  Standard_D4s_v5   Enabled   True     Opt-out tag present - confirm reapply, then plan migration
```

> The `Sub` (subscriptionId) column is omitted above only for page width — include `Sub:subscriptionId` in real runs (it is already selected by the KQL). With Sub + RG + VM on each row you can run Step 2 directly: `az account set --subscription <Sub>` then `az vm run-command -g <RG> -n <VM> ...`.

## VMSS (scale sets)

NVAs are often deployed as **VMSS**. Run [`../scripts/inventory-nva-vmss.kql`](../scripts/inventory-nva-vmss.kql) as well:

```bash
az graph query -q "@scripts/inventory-nva-vmss.kql" --first 1000 \
  --query "data[].{Sub:subscriptionId, RG:resourceGroup, VMSS:VMSSName, Mode:OrchestrationMode, Vendor:Vendor, Size:VMSize, OS:OSType, AN:AcceleratedNetworking, Tag:LegacyVMNVATag, Verdict:Assessment}" -o table
```

- Covers **VMSS Uniform**; VMSS **Flex** instances already appear in the VM query.
- **AKS node pools are excluded** from action — AKS is **not impacted** by MANA (per Microsoft docs), so those rows show `AKS-managed - not impacted`.

## Third-party NVAs (Cisco, Palo Alto, etc.) — non-Windows/Linux images

Appliance OSes (Palo Alto **PAN-OS**, Cisco **IOS-XE / ASAv / FTDv**, Check Point **Gaia**, Fortinet **FortiOS**, F5 **TMOS**) don't expose a standard shell, so `lspci` / `ethtool` / `Get-NetAdapter` **won't run**. Validate differently:

- **ARG still works** — publisher, size, and Accelerated Networking come from Azure, not the guest. Use it to build the candidate list.
- **Check the vendor's MANA / Accelerated Networking compatibility matrix** (release notes / admin guide) for: supported VM series, minimum **PAN-OS/IOS-XE/FortiOS** version, and any required image/driver update.
- **Confirm with the vendor (TAC/support case)** whether your exact version + VM size supports MANA, and the recommended upgrade path.
- **Use the appliance's own CLI/console** where it exposes interface/driver detail (e.g., PAN-OS `show system state`, Cisco `show platform`/`show interface`), rather than Linux tools.
- **If an NVA isn't confirmed MANA-compatible:** apply the `LegacyVMNVA` opt-out **proactively** (don't wait for degradation). For **Marketplace** appliances the built-in policy tags by publisher/product; for **BYO / non-Marketplace** images, apply the tag through your own tooling and coordinate with the vendor/MSP (see [implementation-legacyvmnva.md](./implementation-legacyvmnva.md#when-to-use--when-not-to-use)).

> Do not assume a vendor supports (or doesn't support) MANA — always confirm against the vendor's current documentation for your version.

## Next step

Take every **AN-enabled candidate on an eligible size** and confirm actual NIC/hardware with [verify-mana-nic.md](./verify-mana-nic.md). For any NVA **not confirmed MANA-compatible**, apply the [`LegacyVMNVA` opt-out](./implementation-legacyvmnva.md#when-to-use--when-not-to-use) **proactively** as a safeguard, then migrate and remove it.
