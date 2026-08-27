# Implementing the `LegacyVMNVA` Temporary Exception (az CLI)

> All operations below are taken from the official NVA opt-out page. See [references.md](./references.md).
> **Verified:** 2026-08-20.

**Order matters:** Assign policy → Remediate (adds tag) → **Reapply (enables tag)** → Verify. Applying the tag **alone is not sufficient** for existing resources.

> **Use proactively as a temporary safeguard.** If an NVA (on an eligible size, with Accelerated Networking) is **not confirmed MANA-compatible**, apply the opt-out **before** it can land on MANA hardware — don't wait for a performance hit, which can be severe and cause an outage. It's a **bridge** while you validate compatibility and migrate, **not the end state**. See [When to use / When NOT to use](#when-to-use--when-not-to-use).

> To validate the opt-out end-to-end with before/after NIC + traffic evidence, use [evidence-lab.md](./evidence-lab.md).

---

## When to use / When NOT to use

**Use `LegacyVMNVA` when:**

- An NVA on an eligible VM series with **Accelerated Networking** is **not confirmed MANA-compatible** (vendor hasn't confirmed your VM size + OS + software version). Apply **proactively / ASAP** to keep it off MANA hardware.
- You need a **temporary bridge** during migration to a MANA-compatible configuration.
- The NVA is a **Marketplace** image (built-in policy auto-tags by publisher/product) **or** a **BYO/non-Marketplace** image (apply the tag via your own tooling + reapply).

**Do NOT use `LegacyVMNVA` when:**

- **Accelerated Networking is disabled** → no MANA action needed.
- The workload is **already MANA-compatible** (vendor-confirmed, or in-guest shows the `mana` driver working) → let it use MANA; don't tag.
- **General (non-NVA) workloads** → don't apply broadly; it forgoes MANA benefits and (with ODCR) voids the capacity-reservation SLA.
- **AKS node pools** → not impacted by MANA; don't tag.
- **After May 31, 2027** → the tag is no longer honored.

> **Why (business):** applying the tag proactively prevents a MANA placement change from disrupting an incompatible NVA (throughput/connectivity loss). **How:** policy → remediate → reapply (below). Remove it once the NVA is MANA-compatible.

---

## Built-in policy identity

| Item                            | Value                                                               |
| ------------------------------- | ------------------------------------------------------------------- |
| Policy definition ID            | `e87a87f5-e6dd-4919-be21-abb0a4ea4630`                              |
| Version at time of verification | `1.3.0`                                                             |
| Recommended version pin         | `1.*.*` (or enable _Automatically enroll in minor version changes_) |
| Tag applied                     | `LegacyVMNVA`                                                       |
| Cost                            | None                                                                |
| Editable?                       | No — assign as-is (duplicate to customize)                          |

---

## Step 1 — Assign the built-in policy at the right scope

Choose scope: Root Management Group (whole tenant) → Management Group (multi-sub) → Subscription → Resource Group.

```bash
SCOPE="/subscriptions/<subscription-id>"     # or a resource-group / management-group scope

az policy assignment create \
  --name "LegacyVMNVA-optout" \
  --display-name "LegacyVMNVA MANA opt-out" \
  --policy "e87a87f5-e6dd-4919-be21-abb0a4ea4630" \
  --scope "$SCOPE" \
  --location <region> \
  --mi-system-assigned
```

- A managed identity (`--mi-system-assigned`) is required because the policy performs **remediation** (a `modify` effect that adds the tag).
- Pin to minor auto-enrollment by assigning version `1.*.*` so revisions apply automatically.
- Apply enforcement **gradually** using [Azure Policy safe deployment practices](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/policy-safe-deployment-practices) (incremental rollout by region/resource type).

## Step 1b — Grant the managed identity its role (REQUIRED via CLI)

> **Mandatory and easy to miss.** In the **portal**, Azure Policy auto-grants the identity the roles the policy needs. Via **CLI/SDK it does NOT** — you must grant them yourself, or **Step 2 remediation fails with an authorization error**. The built-in `LegacyVMNVA` policy requires **Contributor** (`b24988ac-6180-42a0-ab88-20f7382dd24c`).

```bash
# principalId of the assignment's system-assigned identity (avoid the name PID -- it is reserved in PowerShell)
MI_ID=$(az policy assignment show --name "LegacyVMNVA-optout" --scope "$SCOPE" --query identity.principalId -o tsv)

# grant the role(s) from the policy's roleDefinitionIds (Contributor for this policy) at the assignment scope
az role assignment create \
  --assignee-object-id "$MI_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "b24988ac-6180-42a0-ab88-20f7382dd24c" \
  --scope "$SCOPE"
```

> Confirm the exact role(s) for the version you assigned:
> `az policy definition show --name e87a87f5-e6dd-4919-be21-abb0a4ea4630 --query policyRule.then.details.roleDefinitionIds -o tsv`
> Allow ~30–60s for the role assignment to propagate before running remediation.

> **New deployments** within the assigned scope get the `LegacyVMNVA` tag **automatically** — Steps 2–3 are only for **existing** resources.

---

## Step 2 — Remediate existing resources (adds the tag)

```bash
# reference the assignment by ID (robust if an assignment of the same name is inherited from a higher scope)
ASSIGN_ID=$(az policy assignment show --name "LegacyVMNVA-optout" --scope "$SCOPE" --query id -o tsv)

az policy remediation create \
  --name "LegacyVMNVA-remediate" \
  --policy-assignment "$ASSIGN_ID" \
  --resource-group <resource-group-name>
```

See [Remediate non-compliant resources](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources). This covers individual VMs and VM Scale Set scenarios.

> **Scoping caveat:** the built-in policy applies the tag only to **Marketplace NVA** publisher/product images (its display name is _"Configure Marketplace Network Virtual Appliances (NVAs) to add a MANA support tag"_). It will not auto-tag a non-NVA image. For NVAs acquired outside Marketplace or via a managed service, apply the tag through your own tooling / the vendor's process.

---

## Step 3 — Reapply to enable the tag (REQUIRED)

The tag must be **enabled** via a reapply operation.

**Standalone VM or VMSS Flex instance:**

```bash
az vm reapply --resource-group <resource-group-name> --name <vm-name>
```

**VMSS Uniform:**

```bash
az rest --method post \
  --url "https://management.azure.com/subscriptions/<subscription-id>/resourceGroups/<resource-group-name>/providers/Microsoft.Compute/virtualMachineScaleSets/<vmss-name>/reapply?api-version=2025-11-01"
```

> The Accelerated Networking status of a VM does **not** affect whether the policy is applied.

---

## Step 4 — Verify

**Check the tag on a VM:**

```bash
az vm show --resource-group <resource-group-name> --name <vm-name> --query "tags"
```

**Check policy compliance (portal):** VM → **Policy** tab, or the **Policy** blade → _compliant_ (tag applied) vs _noncompliant_ (not yet applied). The tag is also visible in the portal for IaaS VMs and VMSS.

---

## Step 5 — Roll back / migrate off the exception

When your NVA is MANA-compatible:

1. **Delete the policy assignment:**
   ```bash
   az policy assignment delete --name "LegacyVMNVA-optout" --scope "/subscriptions/<subscription-id>"
   ```
   For gradual rollback, update the policy **resource selector** to incrementally remove regions.
2. **Remove the tag** from existing VMs (if it persists) and **redeploy** the VMs:
   ```bash
   az resource tag --ids <vm-resource-id> --tags   # re-set tags without LegacyVMNVA
   ```
3. For **ODCR** VMs, removing the tag + ensuring MANA compatibility **restores ODCR SLA eligibility**.

> After **May 31, 2027**, per Microsoft, _"the tag will no longer be honored, and all MANA-eligible VM series may be placed on MANA-capable hardware."_ The tag keeps NVAs off MANA hardware _"while you complete your migration,"_ so validate/migrate NVAs to a MANA-compatible configuration before this date. Microsoft recommends **removing the policy assignment** from all subscriptions afterward. Source: [MANA NVA opt-out](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-network-virtual-appliance-opt-out).

---

## Exemptions (exclude specific resources/scopes)

Use Azure Policy exemptions rather than editing the policy. See [Azure Policy exemption structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/exemption-structure).

---

## Special scenarios

- **NVA acquired outside Azure Marketplace:** work with the NVA provider so the tag is applied to existing and new deployments (deployment templates/mechanisms may need changes).
- **Managed-service NVA:** work with the managed service provider on their tag-application process.
