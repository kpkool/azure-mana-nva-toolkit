# Release Notes

Starting with this file's introduction, every update to `main` must add a dated entry here in the same change.
Entries must state what changed, how it was validated, and any material limitation. Synthetic measurements must be
labeled and must not be presented as an Azure service-level guarantee.

## 2026-09-11 - Release-note policy and performance evidence audit

- Added this append-only release ledger for all future `main` updates.
- Required evidence and limitations in each entry to prevent unsupported performance or behavior claims.
- Strengthened the benchmark to require the exact expected inventory and per-VM call set, not only equal totals.
- Expanded timing assertions and clarified retry-sensitive call counts and collection-timing scope.

## 2026-09-11 - Fleet assessment throughput

Commit: [`969d41a`](https://github.com/kpkool/azure-mana-nva-toolkit/commit/969d41ace358ba3949640316077253ad604659a3)

### Changed

- Added bounded guest-probe concurrency across distinct VMs with `-ThrottleLimit` (default `5`, range `1-32`).
- Preserved the per-VM sequence: instance-view check, then Action Run Command for running candidates.
- Kept checkpoint and event persistence in the parent process and checkpointed each completed remote probe.
- Batched deterministic no-probe results and replaced repeated result scans with VM-ID lookups.
- Added inventory, guest-probe, and total collection timings to `summary.json` without changing schema version `1.1`.
- Added a deterministic serial-versus-parallel benchmark and expanded PowerShell 5.1/7 regression coverage.

### Root cause and evidence

The implementation in parent commit `4aadd99` processed one VM at a time. For each candidate, it waited for the
instance-view request and then the blocking Run Command request before moving to the next VM. Filtering a resource
group reduced candidate probes but did not remove the selected-subscription inventory pass.

A five-pair local fixture benchmark injected `300 ms` per power check and `700 ms` per Run Command for three
candidate VMs:

| Mode                            | Median time | Azure calls |
| ------------------------------- | ----------: | ----------: |
| `ThrottleLimit 1`               |     8.727 s |           9 |
| `ThrottleLimit 5` (effective 3) |     4.504 s |           9 |

Measured result: `1.94x` speedup and `48.4%` elapsed-time reduction. SHA-256 hashes of every serial and parallel
`assessment.json` were identical, and every run made the same number of fixture Azure CLI calls. The gain came from
overlapping independent VM waits, not from skipping work.

### Validation

- Fleet regression suite passed under PowerShell 7 and Windows PowerShell 5.1.
- Retry, partial-result, resume, changed-inventory rejection, redaction, and raw-output non-persistence checks passed.
- PowerShell parser checks and `git diff --check` passed for the published change.
- A stricter five-pair recheck on 2026-09-11 measured `8.366 s` serial and `4.250 s` parallel: `1.97x` and
  `49.2%`, with identical assessments and the exact expected nine-call set in every run.

### Limitations

- The benchmark is a deterministic local fixture, not an Azure runtime SLA.
- Actual duration depends on selected-subscription inventory size, candidate count, Azure/guest-agent latency,
  retries, and throttling.
- Resource-group and VM filters are applied after inventory is retrieved for the selected subscriptions.
- External Azure CLI calls remain synchronous and have no runner-level process timeout.
- `summary.json` phase timings are the empirical source for customer-environment performance.
