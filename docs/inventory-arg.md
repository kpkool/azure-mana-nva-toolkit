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
  --query "data[].{Sub:subscriptionId, RG:resourceGroup, VM:VMName, Vendor:Vendor, NVA:NVAClass, ImageSource:ImageSource, OS:OSType, OSVersion:OSVersion, Size:VMSize, AN:AcceleratedNetworking, Tag:LegacyVMNVATag, Verdict:Assessment}" \
  -o table
```

Columns: **Sub + RG + VM** (the identity you feed straight into Step 2 per VM), **Vendor** (Marketplace plan publisher first, else image publisher), **NVAClass** (6-state — see below), **ImageSource** (`Marketplace` / `Gallery/Custom` / `Platform` / `Custom/VHD`), **OS + OSVersion**, **AN** (per-NIC accurate), **LegacyVMNVATag**, and **Assessment**. The full column list (incl. `PlanPublisher`, `PlanProduct`, `Offer`, `Sku`) is documented in the KQL header — widen the `--query` projection to show more.

> **Enumerate every vendor (safety net):** [`../scripts/discover-vendors.kql`](../scripts/discover-vendors.kql) lists **all** distinct Vendor / PlanPublisher / PlanProduct / OS / ImageSource across VMs + VMSS with counts, a `PolicyScoped` flag, and a **`FirstPartyOS`** flag — so no vendor is silently skipped. Review every row where **`FirstPartyOS=No`** (all third parties) or `PolicyScoped=No`.

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

- **Vendor** = the **Marketplace plan publisher** if present (this is what the built-in `LegacyVMNVA` policy matches), else the image publisher; `unknown/custom` for gallery/VHD images.
- **NVAClass** — 6-state so nothing is silently skipped: **`Policy-scoped NVA (auto-tag)`** (vendor in the policy allow-list → policy can auto-tag, e.g. `paloaltonetworks`), **`Marketplace - not in policy list (review)`** (a Marketplace NVA the policy will NOT tag — tag manually), **`Possible NVA - keyword hint (review)`** (name/product matches an NVA keyword), **`Custom/unknown image (review)`** (gallery/VHD — unidentifiable from metadata; check on host/CMDB), **`Third-party publisher (review)`** (a platform image from a publisher that is **not** a recognized first-party OS vendor — the resilience backstop that catches niche appliances), **`General (platform OS)`** (a normal first-party OS image — typically no action).
- **ImageSource** → `Marketplace` (policy can auto-tag in-scope publishers), or `Gallery/Custom` / `Platform` / `Custom/VHD` (the policy will **not** auto-tag — tag manually if it's an NVA).
- **AN = Disabled** → no MANA action needed for that VM.
- **AN = Enabled / Partial** on a MANA-eligible size → verify on the host with `scripts/detect-mana.sh` / `validate-nva-mana.*`.
- **LegacyVMNVATag = True** → opt-out tag present; confirm it was **enabled via reapply**, then plan migration.
- **Assessment** = triage verdict (control-plane only): `No action - AN disabled`, `NVA (policy-scoped) - validate on host`, `Marketplace NVA NOT in policy list - tag MANUALLY if not MANA-ready`, `Third-party publisher - verify on host; tag manually if it is an NVA`, `Unknown/custom image - tag manually if it is an NVA`, `AN general VM - likely no action`, `Opt-out tag present - confirm reapply`, or `AKS-managed - not impacted`.

## Sample output (anonymized)

```
RG        VM         Vendor            NVAClass                          ImageSource     OS      OSVersion                   AN        Tag      Verdict
--------  ---------  ----------------  --------------------------------  --------------  ------  --------------------------  --------  -------  ------------------------------------------------------------
rg-app    web-01     canonical         General (platform OS)             Platform        Linux   ubuntu-24_04-lts / server   Disabled  Not set  No action - AN disabled
rg-net    nva-fw-01  paloaltonetworks  Policy-scoped NVA (auto-tag)      Marketplace     Linux   vmseries-flex / byol        Enabled   Not set  NVA (policy-scoped) - validate on host; policy auto-tags in scope
rg-net    nva-el-01  elisityinc123     Marketplace - not in policy list  Marketplace     Linux   elisity-edge / edge         Enabled   Not set  Marketplace NVA NOT in policy list - verify on host; tag MANUALLY if not MANA-ready
rg-net    nva-ac-01  acme-appliances   Third-party publisher (review)    Platform        Linux   acme-secure-gw / 2024       Enabled   Not set  Third-party publisher - verify on host; tag manually if it is an NVA
rg-app    app-01     canonical         General (platform OS)             Platform        Linux   ubuntu-24_04-lts / server   Enabled   Not set  AN general VM - verify on host (likely no action)
```

> The `Sub` (subscriptionId) column is omitted above only for page width — include `Sub:subscriptionId` in real runs (it is already selected by the KQL). With Sub + RG + VM on each row you can run Step 2 directly: `az account set --subscription <Sub>` then `az vm run-command -g <RG> -n <VM> ...`.

## VMSS (scale sets)

NVAs are often deployed as **VMSS**. Run [`../scripts/inventory-nva-vmss.kql`](../scripts/inventory-nva-vmss.kql) as well:

```bash
az graph query -q "@scripts/inventory-nva-vmss.kql" --first 1000 \
  --query "data[].{Sub:subscriptionId, RG:resourceGroup, VMSS:VMSSName, Mode:OrchestrationMode, Vendor:Vendor, NVA:NVAClass, ImageSource:ImageSource, OS:OSType, OSVersion:OSVersion, Size:VMSize, AN:AcceleratedNetworking, Tag:LegacyVMNVATag, Verdict:Assessment}" -o table
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
