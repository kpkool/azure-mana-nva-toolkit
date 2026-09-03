# Implementing the `LegacyVMNVA` Temporary Exception (az CLI)

> All operations below are taken from the official NVA opt-out page. See [references.md](./references.md).
> **Verified:** 2026-09-03.

**Order matters:** Assign policy → Remediate (adds tag) → **Reapply (enables tag)** → Verify. Applying the tag **alone is not sufficient** for existing resources.

> **Use only when needed.** Microsoft says the exception is needed for AN workloads that observe degradation on MANA-capable hardware. A provider may also direct it as part of the provider's migration plan. Compatibility uncertainty alone is a review and pilot trigger, not proof that the tag is required.

> To validate the opt-out end-to-end with before/after NIC + traffic evidence, use [evidence-lab.md](./evidence-lab.md).

---

## When to use / When NOT to use

**Use `LegacyVMNVA` when:**

- An NVA with **Accelerated Networking** observes performance degradation on MANA-capable hardware.
- The NVA or managed-service provider directs use of the exception while you migrate.
- You need a **temporary bridge** after one of those triggers. Marketplace products can use the built-in policy; BYO/non-Marketplace deployments follow the provider's tagging mechanism.

**Do NOT use `LegacyVMNVA` when:**

- **Accelerated Networking is disabled** → no MANA action needed.
- Compatibility is merely **unknown** → complete the supported-configuration review and pilot first; guest driver presence alone is not compatibility proof.
- The workload is **MANA-compatible** based on a supported configuration/vendor confirmation and workload validation.
- **General (non-NVA) workloads** → don't apply broadly; it forgoes MANA benefits and (with ODCR) voids the capacity-reservation SLA.
- **AKS node pools** → not impacted by MANA; don't tag.
- **After May 31, 2027** → the tag is no longer honored.

> **Why (business):** the tag temporarily avoids MANA placement for a degraded or provider-identified NVA. **How:** policy or provider mechanism → tag → reapply (below). Remove it after migration and validation.

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
> Confirm the role assignment exists before remediation; propagation timing varies.

> **New deployments** within the assigned scope automatically have the `LegacyVMNVA` tag enabled — Steps 2–3 are only for **existing** resources.

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

> **Scoping caveat:** the built-in policy applies the tag only to its **specific Marketplace NVA publisher/product combinations** (its display name is _"Configure Marketplace Network Virtual Appliances (NVAs) to add a MANA support tag"_). A publisher match alone does not prove applicability. For NVAs acquired outside Marketplace or via a managed service, apply the tag through your own tooling / the vendor's process.

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
   az policy assignment delete --name "LegacyVMNVA-optout" --scope "$SCOPE"
   ```
   For gradual rollback, update the policy **resource selector** to incrementally remove regions.
2. **Remove the tag** from existing VMs (if it persists) and **redeploy** the VMs:
   ```bash
   az tag update \
    --resource-id <vm-resource-id> \
    --operation Delete \
    --tags LegacyVMNVA
   ```
   This deletes only `LegacyVMNVA`; all unrelated tags remain unchanged. Repeat for each tagged VM or VMSS in `$SCOPE`.
3. For **ODCR** VMs, removing the tag + ensuring MANA compatibility **restores ODCR SLA eligibility**.

> **After May 31, 2027**, the tag is no longer honored and MANA-eligible series may be placed on MANA-capable hardware ([Microsoft](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-network-virtual-appliance-opt-out)). It's a bridge _"while you complete your migration"_ — make NVAs MANA-compatible before this date, then remove the policy assignment.

---

## Exemptions (exclude specific resources/scopes)

Use Azure Policy exemptions rather than editing the policy. See [Azure Policy exemption structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/exemption-structure).

---

## Special scenarios

- **NVA acquired outside Azure Marketplace:** work with the NVA provider so the tag is applied to existing and new deployments (deployment templates/mechanisms may need changes).
- **Managed-service NVA:** work with the managed service provider on their tag-application process.
