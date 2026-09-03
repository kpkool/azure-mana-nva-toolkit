# Continuous Governance — Keeping NVAs MANA-Safe Over Time

Assessment is one-time; **governance is ongoing.** New VMs deploy, appliances change versions, and Azure keeps expanding MANA and adding eligible sizes. This is the model to keep NVAs safe after the first pass.

> Primary goals: (1) **no NVA suffers a surprise networking regression from a MANA placement change** — now or later; and (2) **eligible general workloads progressively adopt MANA** to gain its performance, reliability, and resiliency. The `LegacyVMNVA` tag is a _situational safeguard_ within this loop, not the objective.

## Two tracks share the loop

**"No action" is never "ignore forever."** Every workload stays in the re-scan loop under one of two tracks:

- **Risk track (defensive)** — NVAs / AN workloads → verify support and pilot → update or migrate; use `LegacyVMNVA` only after degradation or provider direction.
- **Optimization track (opportunity)** — Microsoft documents no MANA action for **AN-off** workloads. Periodically reassess general/AN-off workloads as opt-in candidates: enable Accelerated Networking on a MANA-ready OS/series to gain its benefits. They re-enter the loop as optimization candidates, not dead-ends.
- **AKS is the exception** — Microsoft states that AKS instances are not impacted and continue to perform as expected on MANA hardware; track them for awareness, with no customer MANA action.

## The loop

1. **Discover (continuous):** run the ARG queries on a schedule (or as an Azure Workbook / Policy compliance view) — don't rely on a point-in-time scan.
2. **Assess:** eligible size + Accelerated Networking + vendor compatibility status.
3. **Verify:** in-guest (`detect-mana.sh` / `detect-mana.ps1`) or vendor tooling for appliances.
4. **Safeguard (as needed):** apply `LegacyVMNVA` after observed degradation or provider direction.
5. **Migrate:** to a MANA-ready size/OS/vendor version; remove the tag.
6. **Report & repeat:** track status, prove compliance, feed changes back to step 1.

## What to put in place

| Control                  | Purpose                                                                       | How                                                                                                                                         |
| ------------------------ | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| **Exception deployment** | Apply a required exception consistently                                       | If the trigger is met, roll out the built-in policy gradually at the approved scope; evaluate ODCR and placement effects first              |
| **Continuous discovery** | Catch new/changed VMs & VMSS                                                  | Scheduled ARG (`scripts/*.kql`), an Azure Workbook, or Policy compliance dashboard                                                          |
| **Drift alerting**       | Flag an untagged AN NVA on an eligible size                                   | ARG-backed alert via Azure Monitor / Logic App                                                                                              |
| **Vendor register**      | Compatibility is per vendor + version and changes                             | Track: appliance, publisher/product, current version, MANA-supported (Y/N), target migration date, owner                                    |
| **Tag lifecycle**        | Tag is a bridge, not a destination                                            | Apply → validate → migrate → **remove**; ensure nothing relies on it past expiry                                                            |
| **MANA opt-in review**   | General / AN-off workloads are candidates for MANA performance gains          | On each re-scan, flag AN-off VMs on eligible sizes for a modernization decision (enable AN + MANA-ready OS/series); not urgent, but tracked |
| **ODCR / SLA watch**     | Tag on capacity-reservation VMs voids ODCR SLA and shrinks the placement pool | Track tagged VMs on ODCR; prioritize their migration to restore SLA eligibility                                                             |
| **Evidence & audit**     | Record due diligence                                                          | Retain `detect`/traffic outputs + policy compliance snapshots                                                                               |

## Timeline gates (act before these)

| Date                      | Meaning                                                                                                                                            |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| **May 26, 2026**          | Earliest MANA placement — Intel v5 & Cobalt 100 v6 (public cloud)                                                                                  |
| **Timeline under review** | Earliest placement for all other eligible series (Dsv2, Dv2, Dsv3/4, Bsv2, Av2, Fsv2, F, G, Ls, …) — **no published date**; re-check the live page |
| **May 31, 2027**          | `LegacyVMNVA` tag **no longer honored** — all reliance must end before this                                                                        |

## Ownership (RACI, illustrative)

| Activity                          | Responsible     | Accountable     | Consulted             | Informed     |
| --------------------------------- | --------------- | --------------- | --------------------- | ------------ |
| Inventory & drift scans           | Infra Engineer  | Infra Lead      | Security              | Architecture |
| Verify NIC / vendor compatibility | Infra Engineer  | Infra Architect | NVA vendor            | Infra Lead   |
| Policy at scale + safeguard       | Infra Architect | Infra Lead      | Security / Governance | Engineers    |
| Migration to MANA-ready config    | Infra Engineer  | Infra Architect | NVA vendor            | Infra Lead   |
| Reporting & audit                 | Infra Lead      | Infra Lead      | Security              | Leadership   |

## Reporting (minimum)

- **Coverage:** % of AN NVAs on eligible sizes that are verified.
- **Risk:** count with unresolved vendor/configuration review, failed pilots, or observed degradation.
- **Bridge debt:** count relying on `LegacyVMNVA`, with target migration dates before May 31, 2027.
- **Drift:** new candidates found since last scan.

## Rollback / de-risk

Remove the safeguard once an NVA is MANA-compatible:

```bash
az policy assignment delete --name "LegacyVMNVA-optout" --scope "/subscriptions/<subscription-id>"
# then remove the tag from any VM where it persists and redeploy
```

See [implementation-legacyvmnva.md](./implementation-legacyvmnva.md) for the full apply/verify/roll-back CLI.
