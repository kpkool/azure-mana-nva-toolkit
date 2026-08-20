# FAQ — Azure MANA & Network Virtual Appliances (NVAs)

Common questions about the Microsoft Azure Network Adapter (MANA) expansion to existing VM series and the `LegacyVMNVA` opt-out. Every answer is grounded in **public Microsoft Learn** (links at the end). Confirm vendor-specific details with your NVA vendor and Microsoft Support.

> **Verified against Microsoft Learn:** 2026-08-20 (opt-out page updated 2026-08-06; existing-sizes page updated 2026-08-11). Re-verify dates before relying on them.

---

## What is changing?

Azure is expanding **MANA** (a component of Azure Boost) to **existing** VM series. Eligible VMs may be placed on MANA-capable hardware over time. Most workloads transition transparently; **NVAs and Accelerated-Networking (AN) workloads on older/unsupported OS or kernels** are the ones that need validation, because they depend directly on the NIC hardware/driver.

## Are running VMs impacted immediately?

No. A VM stays on its current hardware until an action re-runs allocation — a **stop-deallocate-and-start** or a **standard Azure maintenance event**. New VMs in eligible series are also eligible for MANA placement.

## Which workloads are most at risk?

- **NVAs** (firewalls, routers, SD-WAN) using **Accelerated Networking**.
- VMs on **older OS versions, older kernels, or custom kernels** that don't support MANA.
- General-purpose workloads **not** using Accelerated Networking are typically **not** impacted.

---

## ⭐ If Accelerated Networking is DISABLED on a VM or NVA, what action is required?

**None.** Per Microsoft Learn: *"If Accelerated Networking is not enabled on your VM, no action is required. While your VM may still be placed on MANA-capable hardware, your workload will continue to run as expected without changes."*

- AN is a **per-NIC** setting, so **yes, an NVA can have AN disabled** on some or all NICs (though NVAs usually enable AN on data-path NICs for throughput).
- With AN disabled there is **no SR-IOV Virtual Function and no MANA driver dependency**, so MANA placement is a non-event for that NIC/VM.
- **Process:** (1) confirm AN status per NIC (ARG inventory / portal), (2) if disabled → **no action**, (3) optionally still modernize the OS/VM series for the best networking experience, but it is **not required** for MANA.
- You do **not** need the `LegacyVMNVA` tag on AN-disabled VMs. The tag is only for **AN-based NVAs** that observe degradation on MANA hardware.

## When the `LegacyVMNVA` tag is no longer honored, what happens to AN-disabled devices?

**Nothing changes for them.** The tag is honored until **May 31, 2027**; after that, all MANA-eligible series may be placed on MANA-capable hardware. AN-disabled workloads were never at risk (no AN = no VF/driver dependency), so they **continue to run as expected** before and after that date. Only **AN-enabled NVAs on unsupported OS/kernel** face placement risk after the tag stops being honored.

---

## What is the opt-out mechanism and tag?

An **Azure Policy** applies the **`LegacyVMNVA`** tag, which keeps tagged NVA VMs and VM Scale Sets off MANA-capable hardware while you migrate. Built-in policy definition ID: `e87a87f5-e6dd-4919-be21-abb0a4ea4630`. Applying the policy has **no cost**. The policy **scopes tag application to specific NVA publishers/product IDs in the Azure Marketplace**.

## Is applying the tag alone sufficient?

**No.** For **existing** resources: add the tag via a **remediation task**, then run a **`reapply`** operation to enable it (`az vm reapply` for standalone VMs / VMSS Flex; the documented `reapply` REST call for VMSS Uniform). **New** deployments within the policy scope are tagged automatically. Applying the tag in the portal alone does not enable the exception.

## How long is the tag honored?

Until **May 31, 2027**. If the tag is applied **and enabled** before that date, the VM avoids MANA placement until then. **After May 31, 2027** the tag is no longer honored — no action is required, but Microsoft recommends removing the policy assignment.

## What about custom kernels or non-Marketplace NVAs?

Higher risk — Azure can't automatically detect them, and the built-in policy only auto-tags **listed Marketplace publishers**. Work directly with your vendor to validate MANA support, and if needed apply the `LegacyVMNVA` tag through your own tooling (tag + `reapply`), then redeploy per your change process.

## What role do On-Demand Capacity Reservations (ODCR) play?

If you apply `LegacyVMNVA` to VMs backed by an ODCR, the available placement pool is reduced and **ODCR SLA guarantees do not apply** to those VMs. Remove the tag and confirm MANA compatibility to restore ODCR SLA eligibility.

## Are v6/v7 sizes impacted?

Intel **v6 and later** always run on MANA-capable hardware. They are not affected as long as the OS supports MANA. (Resizing an older Intel VM to v6+ satisfies the hardware requirement, but the guest OS must still support MANA.)

## Are AKS or VNet encryption impacted?

No. AKS instances and VNet encryption continue to perform as expected on MANA hardware.

## What if a VM is on MANA hardware but the OS lacks the MANA driver?

Networking falls back to the **NetVSC** adapter. The MANA VF may be visible but no interfaces are exposed by the MANA driver; performance is comparable to SR-IOV `ConnectX-3/4 Lx/5`. Workloads with a high number of concurrent connections may see reduced performance. Fix by updating the OS/kernel (Linux) or installing the driver (Windows).

## How do I verify the tag / check MANA on a host?

- **Tag / compliance:** portal **Policy** tab (compliant = tag applied), or `az` — see [implementation-legacyvmnva.md](./implementation-legacyvmnva.md).
- **On-host MANA/driver:** [verify-mana-nic.md](./verify-mana-nic.md) and the scripts in [`../scripts/`](../scripts/) (`detect-mana.*`, `validate-nva-mana.*`). Appliance OSes (PAN-OS, FortiOS, etc.) can't run these — confirm via the vendor matrix.

## What should I do now?

1. **Inventory** NVAs and AN workloads at scale ([inventory-arg.md](./inventory-arg.md)).
2. **Validate** OS/kernel + on-host MANA state ([verify-mana-nic.md](./verify-mana-nic.md)).
3. **Engage your NVA vendor** for MANA support/upgrade guidance (supported VM series, appliance OS/version, drivers).
4. **Apply the opt-out** only where needed (AN-based NVAs not yet MANA-compatible).
5. **Plan migration** to a MANA-optimized, non-retiring series before **May 31, 2027**; secure capacity (e.g., ODCR) for constrained regions before redeploying.

---

## References (public Microsoft Learn)

- MANA support for NVAs (`LegacyVMNVA` opt-out): <https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-network-virtual-appliance-opt-out>
- MANA support for existing VM series (dates, AN-disabled note): <https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-existing-sizes>
- MANA overview: <https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-overview>
- Linux VMs with MANA: <https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-linux>
- Windows VMs with MANA: <https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-windows>
