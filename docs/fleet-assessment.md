# Fleet Assessment

Use `invoke-mana-fleet-assessment.ps1` for durable, per-NIC MANA reporting across subscriptions. It is
read-only: the script does not start, stop, resize, reapply, tag, or otherwise modify a VM.

## Run

```powershell
pwsh ./scripts/invoke-mana-fleet-assessment.ps1 `
  -SubscriptionId <subscription-id> `
  -OutputDirectory ./mana-assessment-output
```

The default `-ThrottleLimit 5` runs guest probes concurrently across distinct VMs. To serialize probes while
diagnosing throttling or another active Run Command, resume with `-ThrottleLimit 1`. The accepted range is 1-32;
start at the default and increase only in a controlled maintenance window.

Useful modes:

```powershell
# Control-plane inventory only; no guest commands
pwsh ./scripts/invoke-mana-fleet-assessment.ps1 -SubscriptionId <id> `
  -OutputDirectory ./mana-inventory -InventoryOnly

# Continue only pending/failed VM probes after an interrupted or partial run
pwsh ./scripts/invoke-mana-fleet-assessment.ps1 -SubscriptionId <id> `
  -OutputDirectory ./mana-assessment-output -Resume

# Resume serially without invalidating the existing checkpoint
pwsh ./scripts/invoke-mana-fleet-assessment.ps1 -SubscriptionId <id> `
  -OutputDirectory ./mana-assessment-output -Resume -ThrottleLimit 1

# Hash subscription, resource-group, VM, and NIC identifiers in reports
pwsh ./scripts/invoke-mana-fleet-assessment.ps1 -SubscriptionId <id> `
  -OutputDirectory ./mana-shareable -InventoryOnly -RedactResourceNames
```

The runner accepts multiple subscription IDs and optional `-ResourceGroup` and `-VmName` filters. It requires
PowerShell 5.1+ and Azure CLI with the Resource Graph extension.

## Performance and throttling

The runner first retrieves complete, paged inventory for the selected subscriptions, then applies resource-group
and VM filters locally. Selected-subscription fleet size affects this inventory prelude; only filtered VMs with a
`POTENTIAL` NIC incur guest work. Each running candidate requires an instance-view call followed by one blocking
Action Run Command.

Concurrency is bounded across distinct VMs. The scheduler assigns at most one worker to each VM; Azure permits one
active Action Run Command script per VM. Workers return structured results only; the parent process owns event and
checkpoint writes. Every completed remote probe is checkpointed immediately. Deterministic no-probe results, such
as AN-disabled VMs, are checkpointed in one batch before remote work starts.

`ThrottleLimit` changes scheduling, not evidence identity, so it can be changed with `-Resume`. For sustained `429`
responses, lower the limit and resume. For a persistent `Conflict`, allow the VM's existing Run Command to finish,
then resume. Existing bounded exponential retries still apply. Compute and Resource Manager limits are also enforced
per subscription and region, so `32` is a ceiling, not a recommendation.

### Reproducible benchmark

The deterministic fixture injects 300 ms into each power check and 700 ms into each Run Command. On the Windows
development workstation using PowerShell 7, a five-trial run against three candidate VMs produced:

| Mode                            | Median time | Result        |
| ------------------------------- | ----------: | ------------- |
| `ThrottleLimit 1`               |     8.727 s | 9 Azure calls |
| `ThrottleLimit 5` (effective 3) |     4.504 s | 9 Azure calls |

That is a `1.94x` speedup and `48.4%` elapsed-time reduction. All assessments were byte-identical. These fixture
numbers prove that overlap removes serialization cost; they are not an Azure runtime SLA. Real improvement depends
on candidate count, guest-agent latency, retry activity, and service throttling.

`summary.json` records `candidateVmCount`, `throttleLimit`, `inventoryDurationSeconds`,
`guestProbeDurationSeconds`, and `collectionDurationSeconds`. Use these per-run measurements to identify whether
inventory or guest commands dominate in the target subscription. On resume, candidate count and guest time cover
only probes attempted by that invocation.

## Status contract

`ExposureStatus` and `ReadinessStatus` answer different questions:

| Field             | Values                                                      | Meaning                                                                         |
| ----------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `ExposureStatus`  | `NOT_EXPOSED`, `POTENTIAL`, `UNKNOWN`                       | Azure NIC control-plane exposure to MANA placement; not current host placement. |
| `ReadinessStatus` | `NOT_READY`, `REVIEW_REQUIRED`, `NOT_APPLICABLE`, `UNKNOWN` | Decision state after the evidence available to this collector is applied.       |
| `Confidence`      | `HIGH`, `MEDIUM`, `LOW`                                     | Confidence in the final classification, not a workload SLA.                     |
| `ReasonCode`      | Stable uppercase code                                       | Machine-readable reason for the status.                                         |
| `RequiredAction`  | Stable uppercase code                                       | Next operator action.                                                           |

Conservative rules:

- AN-disabled NICs are `NOT_EXPOSED` / `NOT_APPLICABLE`.
- AN-enabled custom images remain `REVIEW_REQUIRED` until image validation and a pilot complete.
- NVAs and third-party appliances remain `REVIEW_REQUIRED` until vendor support and appliance behavior are confirmed.
- A stopped VM or failed guest-agent call remains `UNKNOWN`; the runner never starts it.
- Driver presence does not certify application behavior or vendor support.
- A guest PASS only confirms VM-scoped hardware, driver, and datapath evidence. It remains `REVIEW_REQUIRED`
  until a representative workload pilot and any required vendor review are completed outside this collector.
- `GuestEvidenceScope`, `DatapathState`, and `DatapathScope` prevent repeated VM-level evidence in per-NIC rows
  from being mistaken for evidence about one specific Azure NIC.

## Output and recovery

| File              | Purpose                                                                   |
| ----------------- | ------------------------------------------------------------------------- |
| `inventory.json`  | Per-NIC Azure Resource Graph facts.                                       |
| `assessment.json` | Final per-NIC status and evidence codes.                                  |
| `assessment.csv`  | Flat report for operations teams.                                         |
| `summary.json`    | Coverage, status counts, and partial-run state.                           |
| `checkpoint.json` | Resume state; contains raw Azure VM resource IDs and must remain private. |
| `events.jsonl`    | Minimal execution events; no raw guest output.                            |

Azure Resource Graph pages are ordered by unique VM/NIC IDs and followed with `skip_token`. The runner rejects
duplicate, repeated-token, and incomplete result sets rather than silently publishing a partial inventory.
Azure CLI failures use bounded exponential retries; each completed remote probe is checkpointed immediately.

Action Run Command returns only its last 4,096 bytes and permits one active script per VM at a time. Each validator
therefore emits a compact final `MANA_RESULT_JSON=` record. The runner parses only that record and never saves
the raw Run Command message, which can contain host or network details.

Exit code `0` means complete or inventory-only. Exit code `2` means a durable partial report was written and
pending VMs can be retried with `-Resume`. A fatal inventory or configuration error returns a nonzero error.

## Test

```powershell
pwsh ./tests/test-invoke-mana-fleet-assessment.ps1

# Compare serial and bounded execution with deterministic latency
pwsh ./tests/benchmark-invoke-mana-fleet-assessment.ps1 -Trials 3
```

The fixtures cover pagination, transient failures, checkpoint/resume, stopped VMs, report redaction, custom
images, both throttle paths, result equivalence, and suppression of raw guest output.

**Official references:** [Resource Graph pagination](https://learn.microsoft.com/azure/governance/resource-graph/concepts/paging-results) ·
[Run Command limits](https://learn.microsoft.com/azure/virtual-machines/run-command-overview#compare-feature-support) ·
[Compute throttling](https://learn.microsoft.com/azure/virtual-machines/compute-throttling-limits) ·
[Resource Manager throttling](https://learn.microsoft.com/azure/azure-resource-manager/management/request-limits-and-throttling)
