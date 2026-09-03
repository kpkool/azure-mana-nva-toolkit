# Fleet Assessment

Use `invoke-mana-fleet-assessment.ps1` for durable, per-NIC MANA reporting across subscriptions. It is
read-only: the script does not start, stop, resize, reapply, tag, or otherwise modify a VM.

## Run

```powershell
pwsh ./scripts/invoke-mana-fleet-assessment.ps1 `
  -SubscriptionId <subscription-id> `
  -OutputDirectory ./mana-assessment-output
```

Useful modes:

```powershell
# Control-plane inventory only; no guest commands
pwsh ./scripts/invoke-mana-fleet-assessment.ps1 -SubscriptionId <id> `
  -OutputDirectory ./mana-inventory -InventoryOnly

# Continue only pending/failed VM probes after an interrupted or partial run
pwsh ./scripts/invoke-mana-fleet-assessment.ps1 -SubscriptionId <id> `
  -OutputDirectory ./mana-assessment-output -Resume

# Hash subscription, resource-group, VM, and NIC identifiers in reports
pwsh ./scripts/invoke-mana-fleet-assessment.ps1 -SubscriptionId <id> `
  -OutputDirectory ./mana-shareable -InventoryOnly -RedactResourceNames
```

The runner accepts multiple subscription IDs and optional `-ResourceGroup` and `-VmName` filters. It requires
PowerShell 5.1+ and Azure CLI with the Resource Graph extension.

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
Azure CLI failures use bounded exponential retries; each VM result is checkpointed immediately.

Action Run Command returns only its last 4,096 bytes and permits one active script at a time. Each validator
therefore emits a compact final `MANA_RESULT_JSON=` record. The runner parses only that record and never saves
the raw Run Command message, which can contain host or network details.

Exit code `0` means complete or inventory-only. Exit code `2` means a durable partial report was written and
pending VMs can be retried with `-Resume`. A fatal inventory or configuration error returns a nonzero error.

## Test

```powershell
pwsh ./tests/test-invoke-mana-fleet-assessment.ps1
```

The fixtures cover pagination, transient failures, checkpoint/resume, stopped VMs, report redaction, custom
images, and suppression of raw guest output.

**Official references:** [Resource Graph pagination](https://learn.microsoft.com/azure/governance/resource-graph/concepts/paging-results) ·
[Run Command limits](https://learn.microsoft.com/azure/virtual-machines/run-command-overview#compare-feature-support)
