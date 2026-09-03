# MANA / NVA — Validated Facts & Timeline

> All statements below are confirmed against official Microsoft Learn pages. See [references.md](./references.md).
> **Verified:** 2026-09-03. Source pages last updated 2026-08-06 (opt-out) / 2026-08-11 (existing-sizes). Re-verify dates against the live docs before relying on them.

## 1. What MANA is

- **Microsoft Azure Network Adapter (MANA)** is a next-generation network interface and a **component of Azure Boost**.
- Provides **stable, forward-compatible device drivers** for Windows and Linux.
- Maintains **feature parity** with previous Azure networking. VMs run on hardware with both Mellanox and MANA NICs, so existing `mlx4`/`mlx5` support must still be present.

## 2. How placement changes

- Both **existing and newly created** VMs in eligible series may be placed on MANA-capable hardware.
- Existing VMs can land on MANA hardware after a **stop-deallocate-and-start** operation **or** a **standard Azure maintenance event**.
- New VMs in eligible series are also eligible for MANA placement.

## 3. Impact scope

- **Most workloads transition without issue.**
- **NVAs are uniquely impacted** due to direct dependency on the underlying network hardware and drivers.
- **DPDK-based workloads** are also impacted — DPDK on MANA requires Linux kernel **6.14+** or backports of the 6.14+ MANA Ethernet and InfiniBand drivers.
- **Not impacted:** Azure Kubernetes Service (AKS) instances; VNet encryption. Both continue to perform as expected on MANA hardware.
- **If Accelerated Networking is NOT enabled on the VM → no action required.** The VM may still land on MANA hardware but the workload runs as expected.

## 4. Eligible VM series (may land on MANA-capable hardware)

| Family   | Series                                                                                                                                 |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| A-family | Av2\*                                                                                                                                  |
| B-family | Bsv2                                                                                                                                   |
| D-family | Dv1\*, Dsv1\*, Dv2\*, Dsv2\*, Dv3, Dsv3, Dv4, Dsv4, Ddv4, Ddsv4, Dv5, Dsv5, Ddv5, Ddsv5, Dlsv5, Dldsv5, Dpsv6, Dpdsv6, Dplsv6, Dpldsv6 |
| E-family | Ev3, Esv3, Ev4, Esv4, Edv4, Edsv4, Ev5, Esv5, Edv5, Edsv5, Epsv6, Epdsv6                                                               |
| F-family | F\*, Fs\*, Fsv2\*                                                                                                                      |
| G-family | G\*, Gs\*                                                                                                                              |
| L-family | Ls\*                                                                                                                                   |

\* Announced for retirement — migrate to a replacement series. See the retired-sizes list and migration guide in [references.md](./references.md).

> Always confirm the current list at the [Applicable VM series](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-existing-sizes#applicable-vm-series) section — Microsoft updates it.

## 5. Timeline — earliest placement & tag honoring

| Milestone                                                                                                                                                                  | Date                      | Notes                                                                                                                                                                                         |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Earliest MANA placement — **Intel v5** (Dv5/Dsv5/Ddv5/Ddsv5/Dlsv5/Dldsv5/Ev5/Esv5/Edv5/Edsv5) & **Cobalt 100 v6** (Dpsv6/Dpdsv6/Dplsv6/Dpldsv6/Epsv6/Epdsv6), Public cloud | **May 26, 2026**          | Complete compatibility review and migration planning before this date; enable an exception before the date only if it is needed                                                               |
| Earliest MANA placement — **all other eligible series** (Dsv2, Dv2, Dsv3, Dv3, Dsv4, Dv4, Esv3/4, Bsv2, Av2, Fsv2, Fs, F, G, GS, Ls, …)                                    | **Timeline under review** | **No confirmed date yet** — Microsoft has not published one; re-check the live page                                                                                                           |
| **`LegacyVMNVA` tag honored until**                                                                                                                                        | **May 31, 2027**          | If tag applied+enabled before this date, VM avoids MANA placement until this date                                                                                                             |
| Tag no longer honored                                                                                                                                                      | **After May 31, 2027**    | Tag no longer honored; MANA-eligible series may be placed on MANA-capable hardware. Make NVAs MANA-compatible before this date; Microsoft recommends removing the policy assignment afterward |

> **Important:** the live docs list **only** May 26, 2026 (Intel v5 + Cobalt 100 v6) as a confirmed date; **every other series — including Dsv2/Dv2/Dsv3/etc. — is "Timeline under review" with no published date.** Re-check the live page and complete compatibility work without inferring that every candidate needs the tag.

## 6. Network performance if OS doesn't support MANA (fallback)

If a VM lands on MANA hardware but the OS doesn't support MANA, networking **falls back to the NetVSC adapter**:

- The MANA Virtual Function (VF) may be visible, but no interfaces are exposed by the MANA driver.
- Performance is expected to be **comparable to SR-IOV `ConnectX-3`, `ConnectX-4 Lx`, `ConnectX-5`** devices.
- Workloads with a **high number of concurrent connections** may see reduced performance.

## 7. The `LegacyVMNVA` temporary exception

- An **applied and enabled tag**, deployable through a **built-in Azure Policy** for its matched Marketplace products, that temporarily keeps NVA VMs / VM Scale Sets off MANA hardware while you migrate.
- Microsoft says the exception is needed for Accelerated Networking workloads that **observe degradation** on MANA-capable hardware. A provider may also direct it during migration. Do **not** use compatibility uncertainty alone as proof that the tag is required.
- The built-in policy **scopes tag application to specific NVA publishers and product IDs in Azure Marketplace**.
- Applying the policy has **no cost implications**.
- The built-in policy **cannot be edited directly** (duplicate it if customization is needed).
- Compliance is tracked in Azure Policy: _compliant_ = tag applied; _noncompliant_ = not yet applied.

## 8. On-demand capacity reservation (ODCR) caveat

- Using `LegacyVMNVA` on ODCR VMs **reduces the available placement pool**, and **ODCR SLA guarantees do not apply** to those VMs.
- **Remove the tag** and ensure MANA compatibility to **restore ODCR SLA eligibility**.

## 9. NVAs outside Azure Marketplace / managed-service NVAs

- **Acquired outside Marketplace:** work with your NVA provider to ensure the `LegacyVMNVA` tag is applied to existing and new deployments.
- **Managed-service NVAs:** work with your managed service provider on their plans/processes for applying the tag.

## 10. Migration end-state

- Plan to migrate to a **MANA-compatible NVA configuration** (compatible VM series and/or OS, confirmed vendor support) and **remove the temporary exception** once compatibility is confirmed.
- Microsoft recommends **newer VM series** (built/optimized for MANA) for the most optimal networking experience.
