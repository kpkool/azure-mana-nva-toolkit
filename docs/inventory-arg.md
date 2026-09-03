# Inventory NVA Candidates at Scale (Azure Resource Graph)

Before checking individual VMs, use **Azure Resource Graph (ARG)** to list every VM with its **vendor (image publisher)**, **size**, **OS**, **NIC count**, and **Accelerated Networking (AN) status** across all accessible subscriptions. This finds your **candidate** NVA workloads fast.

> **What ARG can and can't tell you:**
>
> - ✅ Vendor/publisher, size, OS, per-NIC **Accelerated Networking** (the MANA precondition), and the **`LegacyVMNVA` tag**.
> - ❌ It **cannot** tell you whether a VM is currently on **MANA hardware** — that is host placement, only visible **in-guest** (confirm with [verify-mana-nic.md](./verify-mana-nic.md) / `scripts/detect-mana.sh`).
> - ❌ A present `LegacyVMNVA` tag does **not** prove it was **enabled** — enabling requires a **reapply** operation (see [implementation-legacyvmnva.md](./implementation-legacyvmnva.md)).

## Query (VM summary)

Use [`../scripts/inventory-nva-vms.kql`](../scripts/inventory-nva-vms.kql). Runs in **Azure Resource Graph Explorer** (portal) or via CLI:

```bash
az extension add -n resource-graph            # one-time (CLI only)
az graph query -q "@scripts/inventory-nva-vms.kql" --first 1000 \
  --query "data[].{Sub:subscriptionId, RG:resourceGroup, VM:VMName, Vendor:Vendor, NVA:NVAClass, ImageSource:ImageSource, OS:OSType, OSVersion:OSVersion, Size:VMSize, AN:AcceleratedNetworking, Tag:LegacyVMNVATag, Verdict:Assessment}" \
  -o table
```

Columns: **Sub + RG + VM** (the identity you feed straight into Step 2 per VM), **Vendor** (Marketplace plan publisher first, else image publisher), **NVAClass** (6-state — see below), **ImageSource** (`Marketplace` / `Gallery/Custom` / `Platform` / `Custom/VHD`), **OS + OSVersion**, **AN** (per-NIC accurate), **LegacyVMNVATag**, and **Assessment**. The full column list (incl. `PlanPublisher`, `PlanProduct`, `Offer`, `Sku`) is documented in the KQL header — widen the `--query` projection to show more.

## Query (per NIC)

Use [`../scripts/inventory-mana-nics.kql`](../scripts/inventory-mana-nics.kql) when each NIC must retain its own
identity and AN state:

```bash
az graph query -q "@scripts/inventory-mana-nics.kql" --subscriptions <subscription-id> --first 1000 \
  --query "data[].{Sub:subscriptionId,RG:resourceGroup,VM:VMName,NIC:NICName,Primary:NICPrimary,AN:AcceleratedNetworking,Exposure:ExposureStatus,Readiness:ReadinessStatus,Confidence:Confidence,Reason:ReasonCode,Action:RequiredAction}" \
  -o table
```

The query intentionally separates `ExposureStatus` from `ReadinessStatus`. ARG can prove whether AN is enabled
on an Azure NIC, but cannot prove current MANA host placement, guest-driver health, custom-image safety, or NVA
vendor support. AN-enabled NICs therefore start as `POTENTIAL` / `UNKNOWN`.

For complete pagination and durable JSON/CSV output, use
[`../scripts/invoke-mana-fleet-assessment.ps1`](../scripts/invoke-mana-fleet-assessment.ps1). Manual
`--first 1000` output is capped at 1,000 rows.

> **Enumerate every vendor (safety net):** [`../scripts/discover-vendors.kql`](../scripts/discover-vendors.kql) lists **all** distinct Vendor / PlanPublisher / PlanProduct / OS / ImageSource combinations with counts, a `PublisherListed` hint, and a `RecognizedOSPublisher` routing flag. Review every row where `RecognizedOSPublisher=No`. `PublisherListed=Yes` does not prove that the policy matches the product, and `PublisherListed=No` does not clear an unrecognized publisher.

## Why the VM summary aggregates first

A direct VM-to-NIC join intentionally produces a per-NIC report, but it is unsafe when the required output is
one row per VM:

```kusto
| join kind=leftouter ( Resources | where type =~ 'microsoft.network/networkinterfaces' ... ) on vmId
```

Without aggregation:

- A **multi-NIC VM appears multiple times** (double-counted).
- If NICs differ (one AN-enabled, one not), the VM shows **conflicting rows** with no clear status.

The VM-summary query **summarizes NICs per VM first**, then joins, so each VM is exactly one row and mixed AN is
surfaced explicitly. The dedicated per-NIC query retains those rows by design.

| NIC situation   | Reported `AcceleratedNetworking` |
| --------------- | -------------------------------- |
| No NIC found    | `No NIC found`                   |
| All NICs AN off | `Disabled`                       |
| All NICs AN on  | `Enabled`                        |
| Some NICs AN on | `Partial (n/m)`                  |

`Partial` matters: MANA impact is per-NIC/hardware, so a mixed VM needs closer review.

## Interpreting results

- **Vendor** = the **Marketplace plan publisher** if present (this is what the built-in `LegacyVMNVA` policy matches), else the image publisher; `unknown/custom` for gallery/VHD images.
- **NVAClass** — 6-state so nothing is silently skipped: **`Publisher-listed NVA (product match unverified)`** (publisher appears in the policy snapshot; verify the exact `PlanProduct` against the live policy), **`Marketplace - not in policy list (review)`**, **`Possible NVA - keyword hint (review)`**, **`Custom/unknown image (review)`**, **`Third-party publisher (review)`**, or **`General (platform OS)`**. Every class except `General` remains an explicit review state.
- **ImageSource** → `Marketplace`, `Gallery/Custom`, `Platform`, or `Custom/VHD`. This is image provenance, not proof of policy applicability.
- **AN = Disabled** → no MANA action needed for that VM.
- **AN = Enabled / Partial** on a MANA-eligible size → verify on the host with `scripts/detect-mana.sh` / `validate-nva-mana.*`.
- **LegacyVMNVATag = True** → opt-out tag present; confirm it was **enabled via reapply**, then plan migration.
- **Assessment** = triage verdict (control-plane only): `No action - AN disabled`, `Publisher-listed NVA - verify exact policy product match and vendor support`, `Marketplace review - confirm workload and vendor support`, `Third-party publisher - classify workload and confirm vendor support`, `Unknown/custom image - inspect image and workload assumptions`, `AN general VM - likely no action`, `Opt-out tag present - confirm reapply`, or `AKS-managed - not impacted`.

## Sample output (anonymized)

```text
RG        VM         Vendor            NVAClass                          ImageSource     OS      OSVersion                   AN        Tag      Verdict
--------  ---------  ----------------  --------------------------------  --------------  ------  --------------------------  --------  -------  ------------------------------------------------------------
rg-app    web-01     canonical         General (platform OS)             Platform        Linux   ubuntu-24_04-lts / server   Disabled  Not set  No action - AN disabled
rg-net    nva-fw-01  paloaltonetworks  Publisher-listed NVA (product match unverified)  Marketplace  Linux  vmseries-flex / byol  Enabled  Not set  Publisher-listed NVA - verify exact policy product match and vendor support
rg-net    nva-el-01  elisityinc123     Marketplace - not in policy list  Marketplace     Linux   elisity-edge / edge         Enabled   Not set  Marketplace review - confirm workload and vendor support
rg-net    nva-ac-01  acme-appliances   Third-party publisher (review)    Platform        Linux   acme-secure-gw / 2024       Enabled   Not set  Third-party publisher - classify workload and confirm vendor support
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
- **If compatibility is uncertain:** obtain provider confirmation and run a representative pilot. Use `LegacyVMNVA` only after observed degradation or provider direction; BYO / non-Marketplace deployments follow the provider's tagging mechanism.

> Do not assume a vendor supports (or doesn't support) MANA — always confirm against the vendor's current documentation for your version.

## Next step

Take every **AN-enabled candidate on an eligible size** through host verification, supported-configuration review, and a representative pilot. Update or migrate unsupported configurations. Apply the [`LegacyVMNVA` opt-out](./implementation-legacyvmnva.md#when-to-use--when-not-to-use) only when its trigger is met.
