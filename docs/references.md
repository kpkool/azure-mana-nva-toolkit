# Public Microsoft References — MANA / NVA / LegacyVMNVA

All references are public Microsoft Learn or Microsoft Tech Community pages. **Verified:** 2026-08-20.

## Core MANA / NVA pages

| Reference                                                            | URL                                                                                                                   | Source `ms.date` / last updated         |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| MANA support for Network Virtual Appliances (opt-out, `LegacyVMNVA`) | https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-network-virtual-appliance-opt-out | ms.date 2026-04-07 / updated 2026-08-06 |
| MANA support for existing VM series (eligible series list)           | https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-existing-sizes                    | ms.date 2026-07-30 / updated 2026-08-11 |
| Microsoft Azure Network Adapter (MANA) overview                      | https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-overview                          | ms.date 2025-09-04 / updated 2026-05-05 |

## Verify MANA on a VM

| Reference                                            | URL                                                                                         | Source `ms.date` / last updated         |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------- |
| Linux VMs with the Microsoft Azure Network Adapter   | https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-linux   | ms.date 2026-02-02 / updated 2026-06-02 |
| Windows VMs with the Microsoft Azure Network Adapter | https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-windows | ms.date 2023-07-10 / updated 2026-02-03 |
| Windows MANA driver download                         | https://aka.ms/manawindowsdrivers                                                           | n/a                                     |
| MANA and DPDK on Linux                               | https://learn.microsoft.com/en-us/azure/virtual-network/setup-dpdk-mana                     | —                                       |
| Azure Accelerated Networking overview (OS support)   | https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-overview     | —                                       |

## Policy, remediation & rollout

| Reference                                           | URL                                                                                               |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Remediate non-compliant resources with Azure Policy | https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources              |
| Azure Policy safe deployment practices              | https://learn.microsoft.com/en-us/azure/governance/policy/how-to/policy-safe-deployment-practices |
| Azure Policy exemption structure                    | https://learn.microsoft.com/en-us/azure/governance/policy/concepts/exemption-structure            |

## Capacity reservation (ODCR)

| Reference                               | URL                                                                                                                 |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| On-demand capacity reservation overview | https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-overview                              |
| SLA for capacity reservation            | https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-overview#sla-for-capacity-reservation |

## Timeline announcement

| Reference                                                                | URL                                                                                                                                                   |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Azure Infrastructure Blog — Announcing MANA support for existing VM SKUs | https://techcommunity.microsoft.com/blog/AzureInfrastructureBlog/announcing-microsoft-azure-network-adapter-mana-support-for-existing-vm-skus/4493279 |

## VM retirement (for `*` series)

| Reference                               | URL                                                                                                              |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Retired VM sizes list                   | https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/retirement/retired-sizes-list                     |
| D/Ds/Dv2/Dsv2/Ls series migration guide | https://learn.microsoft.com/en-us/azure/virtual-machines/migration/sizes/d-ds-dv2-dsv2-ls-series-migration-guide |

## Tooling & commands used by this toolkit

| Tool / command                                       | URL                                                                                     |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Azure Resource Graph — overview                      | https://learn.microsoft.com/en-us/azure/governance/resource-graph/overview              |
| Azure Resource Graph — starter query samples         | https://learn.microsoft.com/en-us/azure/governance/resource-graph/samples/starter       |
| `az graph query` (CLI reference)                     | https://learn.microsoft.com/en-us/cli/azure/graph                                       |
| Run scripts in a Linux VM with `az vm run-command`   | https://learn.microsoft.com/en-us/azure/virtual-machines/linux/run-command-managed      |
| Run scripts in a Windows VM with `az vm run-command` | https://learn.microsoft.com/en-us/azure/virtual-machines/windows/run-command-managed    |
| Accelerated Networking — overview                    | https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-overview |
| Auto-shutdown a VM (schedule)                        | https://learn.microsoft.com/en-us/azure/virtual-machines/auto-shutdown-vm               |

---

## Verified key values (quick audit)

| Item                                                    | Value                                            | Primary source        |
| ------------------------------------------------------- | ------------------------------------------------ | --------------------- |
| Cobalt 100 v6 & Intel v5 earliest placement (Public cloud) | **May 26, 2026**                                 | NVA opt-out / existing-sizes pages |
| All other eligible series (Dsv2, Dv2, Dsv3/4, Bsv2, …)      | **Timeline under review** (no published date)    | NVA opt-out / existing-sizes pages |
| Tag honored until                                       | **May 31, 2027**                                 | NVA opt-out page      |
| Built-in policy definition ID                           | `e87a87f5-e6dd-4919-be21-abb0a4ea4630` (v1.3.0)  | NVA opt-out page      |
| Tag name                                                | `LegacyVMNVA`                                    | NVA opt-out page      |
| VMSS Uniform reapply API version                        | `2025-11-01`                                     | NVA opt-out page      |
| Linux MANA PCI device                                   | `Microsoft Corporation Device 00ba` (`lspci`)    | Linux MANA page       |
| Linux MANA VF driver                                    | `mana` (`ethtool -i <vf>`)                       | Linux MANA page       |
| Windows MANA PCI ID                                     | `PCI\VEN_1414&DEV_00BA&`                         | Windows MANA page     |
| Linux MANA kernel (first upstream)                      | 5.15+ (6.2 for IB/RDMA & DPDK; DPDK needs 6.14+) | Linux MANA / overview |
