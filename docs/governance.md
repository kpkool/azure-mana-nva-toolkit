# Continuous Governance — Keeping NVAs MANA-Safe Over Time

Assessment is one-time; **governance is ongoing.** New VMs deploy, appliances change versions, and Azure keeps expanding MANA and adding eligible sizes. This is the model to keep NVAs safe after the first pass.

> Primary goal: **no NVA suffers a surprise networking regression from a MANA placement change — now or later.** The `LegacyVMNVA` tag is a _situational safeguard_ within this loop, not the objective.

## The loop

1. **Discover (continuous):** run the ARG queries on a schedule (or as an Azure Workbook / Policy compliance view) — don't rely on a point-in-time scan.
2. **Assess:** eligible size + Accelerated Networking + vendor compatibility status.
3. **Verify:** in-guest (`detect-mana.sh` / `detect-mana.ps1`) or vendor tooling for appliances.
4. **Safeguard (as needed):** apply `LegacyVMNVA` proactively to not-yet-compatible NVAs.
5. **Migrate:** to a MANA-ready size/OS/vendor version; remove the tag.
6. **Report & repeat:** track status, prove compliance, feed changes back to step 1.

## What to put in place

| Control                  | Purpose                                                                       | How                                                                                                                               |
| ------------------------ | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| **Scale enforcement**    | New NVAs are safe by default                                                  | Assign the built-in `LegacyVMNVA` policy at **Management Group** scope (auto-tags in-scope Marketplace NVAs; pin version `1.*.*`) |
| **Continuous discovery** | Catch new/changed VMs & VMSS                                                  | Scheduled ARG (`scripts/*.kql`), an Azure Workbook, or Policy compliance dashboard                                                |
| **Drift alerting**       | Flag an untagged AN NVA on an eligible size                                   | ARG-backed alert via Azure Monitor / Logic App                                                                                    |
| **Vendor register**      | Compatibility is per vendor + version and changes                             | Track: appliance, publisher/product, current version, MANA-supported (Y/N), target migration date, owner                          |
| **Tag lifecycle**        | Tag is a bridge, not a destination                                            | Apply → validate → migrate → **remove**; ensure nothing relies on it past expiry                                                  |
| **ODCR / SLA watch**     | Tag on capacity-reservation VMs voids ODCR SLA and shrinks the placement pool | Track tagged VMs on ODCR; prioritize their migration to restore SLA eligibility                                                   |
| **Evidence & audit**     | Prove due diligence                                                           | Retain `detect`/traffic outputs + policy compliance snapshots                                                                     |

## Timeline gates (act before these)

| Date               | Meaning                                                                     |
| ------------------ | --------------------------------------------------------------------------- |
| **May 26, 2026**   | Earliest MANA placement — Cobalt 100 & Intel v5 (public cloud)              |
| **August 6, 2026** | Earliest MANA placement — Intel v1–v4 (public cloud)                        |
| **May 31, 2027**   | `LegacyVMNVA` tag **no longer honored** — all reliance must end before this |

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
- **Risk:** count not-yet-compatible without a safeguard tag (should trend to zero).
- **Bridge debt:** count relying on `LegacyVMNVA`, with target migration dates before May 31, 2027.
- **Drift:** new candidates found since last scan.

## Rollback / de-risk

Remove the safeguard once an NVA is MANA-compatible:

```bash
az policy assignment delete --name "LegacyVMNVA-optout" --scope "/subscriptions/<subscription-id>"
# then remove the tag from any VM where it persists and redeploy
```

See [implementation-legacyvmnva.md](./implementation-legacyvmnva.md) for the full apply/verify/roll-back CLI.
