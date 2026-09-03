#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$runner = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/invoke-mana-fleet-assessment.ps1'
$fakeAz = Join-Path $PSScriptRoot 'fake-az.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "mana-fleet-tests-$PID"
$stateRoot = Join-Path $testRoot 'state'
$outputRoot = Join-Path $testRoot 'output'
$redactedRoot = Join-Path $testRoot 'redacted'
$changedInventoryRoot = Join-Path $testRoot 'changed-inventory'
$hostExecutable = (Get-Process -Id $PID).Path
$subscriptionId = '00000000-0000-0000-0000-000000000001'

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Invoke-Runner([string]$Output, [switch]$Resume, [switch]$InventoryOnly, [switch]$Redact) {
  $arguments = @(
    '-NoProfile', '-File', $runner,
    '-SubscriptionId', $subscriptionId,
    '-OutputDirectory', $Output,
    '-PageSize', '2',
    '-MaxAttempts', '2',
    '-InitialRetryDelaySeconds', '1',
    '-AzExecutable', $fakeAz
  )
  if ($Resume) { $arguments += '-Resume' }
  if ($InventoryOnly) { $arguments += '-InventoryOnly' }
  if ($Redact) { $arguments += '-RedactResourceNames' }
  & $hostExecutable @arguments | Out-Host
  $runnerExitCode = $LASTEXITCODE
  return $runnerExitCode
}

try {
  New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
  $env:MANA_FAKE_STATE_DIR = $stateRoot
  $env:MANA_FAKE_FAIL_GRAPH_ONCE = '1'
  $env:MANA_FAKE_FAIL_RUN_ONCE = '1'
  $env:MANA_FAKE_WINDOWS_RUNNING = '0'

  $firstExitCode = Invoke-Runner -Output $outputRoot
  Assert-True ($firstExitCode -eq 2) 'The first run must report a partial result for the deallocated VM.'
  $firstSummary = Get-Content (Join-Path $outputRoot 'summary.json') -Raw | ConvertFrom-Json
  $firstRows = @(Get-Content (Join-Path $outputRoot 'assessment.json') -Raw | ConvertFrom-Json)
  Assert-True ($firstSummary.runStatus -eq 'PARTIAL') 'First summary status must be PARTIAL.'
  Assert-True ($firstRows.Count -eq 5) 'All five inventory records must be reported.'
  $generalRow = $firstRows | Where-Object VMName -eq 'vm-general'
  Assert-True ($generalRow.ReadinessStatus -eq 'REVIEW_REQUIRED') 'Guest telemetry alone must not classify a workload READY.'
  Assert-True ($generalRow.ReasonCode -eq 'MANA_WORKLOAD_PILOT_REQUIRED') 'Validated MANA guest evidence must still require a workload pilot.'
  Assert-True ($generalRow.DatapathState -eq 'CONFIRMED') 'The report must surface guest datapath state.'
  Assert-True ($generalRow.GuestEvidenceScope -eq 'VM' -and $generalRow.DatapathScope -eq 'VM_AGGREGATE') 'Linux guest evidence must be explicitly VM-scoped.'
  Assert-True (@($firstRows | Where-Object ReadinessStatus -eq 'READY').Count -eq 0) 'No telemetry-only assessment row may be READY.'
  Assert-True (($firstRows | Where-Object VMName -eq 'vm-custom').ReasonCode -eq 'CUSTOM_IMAGE_VALIDATION_REQUIRED') 'Custom images must require explicit image validation.'
  Assert-True (($firstRows | Where-Object VMName -eq 'vm-noan').ReadinessStatus -eq 'NOT_APPLICABLE') 'AN-disabled NIC must be NOT_APPLICABLE.'
  Assert-True (($firstRows | Where-Object VMName -eq 'vm-windows').ReasonCode -eq 'VM_NOT_RUNNING') 'Stopped VM must remain UNKNOWN.'
  $missingNicRow = $firstRows | Where-Object VMName -eq 'vm-nic-missing'
  Assert-True ($missingNicRow.ReadinessStatus -eq 'UNKNOWN' -and $missingNicRow.ReasonCode -eq 'NIC_DATA_MISSING') 'Missing NIC linkage must remain UNKNOWN.'

  $calls = @(Get-Content (Join-Path $stateRoot 'calls.log'))
  Assert-True (@($calls | Where-Object { $_ -eq 'run:vm-general' }).Count -eq 2) 'Transient Run Command failure must be retried once.'
  Assert-True (@($calls | Where-Object { $_ -eq 'power:vm-noan' }).Count -eq 0) 'AN-disabled VM must not receive a guest probe.'
  Assert-True (@($calls | Where-Object { $_ -eq 'power:vm-nic-missing' }).Count -eq 0) 'Missing NIC linkage must not trigger a guest probe.'
  $persistedText = ((Get-ChildItem $outputRoot -File | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n")
  Assert-True ($persistedText -notmatch 'RAW_GUEST_SECRET_SHOULD_NOT_PERSIST') 'Raw guest output must not be persisted.'

  $env:MANA_FAKE_WINDOWS_RUNNING = '1'
  $resumeExitCode = Invoke-Runner -Output $outputRoot -Resume
  Assert-True ($resumeExitCode -eq 0) 'Resume must complete after the pending VM becomes available.'
  $resumeSummary = Get-Content (Join-Path $outputRoot 'summary.json') -Raw | ConvertFrom-Json
  $resumeRows = @(Get-Content (Join-Path $outputRoot 'assessment.json') -Raw | ConvertFrom-Json)
  $checkpoint = Get-Content (Join-Path $outputRoot 'checkpoint.json') -Raw | ConvertFrom-Json
  Assert-True ($resumeSummary.runStatus -eq 'COMPLETE') 'Resumed summary status must be COMPLETE.'
  $windowsRow = $resumeRows | Where-Object VMName -eq 'vm-windows'
  Assert-True ($windowsRow.ReadinessStatus -eq 'REVIEW_REQUIRED') 'Resumed Windows telemetry must still require a workload pilot.'
  Assert-True ($windowsRow.DatapathScope -eq 'VM_SHARED_MANA_VF') 'Windows datapath evidence must identify the VM-shared MANA VF scope.'
  Assert-True (@($checkpoint.completedVmIds).Count -eq 5) 'Checkpoint must contain all completed VMs.'
  $resumedCalls = @(Get-Content (Join-Path $stateRoot 'calls.log'))
  Assert-True (@($resumedCalls | Where-Object { $_ -eq 'run:vm-general' }).Count -eq 2) 'Resume must not repeat completed VM probes.'

  $env:MANA_FAKE_WINDOWS_RUNNING = '0'
  $changedFirstExitCode = Invoke-Runner -Output $changedInventoryRoot
  Assert-True ($changedFirstExitCode -eq 2) 'Changed-inventory fixture must first create a partial checkpoint.'
  $windowsCallsBeforeRejectedResume = @((Get-Content (Join-Path $stateRoot 'calls.log')) | Where-Object { $_ -eq 'run:vm-windows' }).Count
  $env:MANA_FAKE_WINDOWS_RUNNING = '1'
  $env:MANA_FAKE_INVENTORY_CHANGED = '1'
  $changedResumeExitCode = Invoke-Runner -Output $changedInventoryRoot -Resume
  Assert-True ($changedResumeExitCode -ne 0) 'Resume must reject changed control-plane inventory.'
  $windowsCallsAfterRejectedResume = @((Get-Content (Join-Path $stateRoot 'calls.log')) | Where-Object { $_ -eq 'run:vm-windows' }).Count
  Assert-True ($windowsCallsAfterRejectedResume -eq $windowsCallsBeforeRejectedResume) 'Rejected resume must not probe a pending VM.'
  Remove-Item Env:MANA_FAKE_INVENTORY_CHANGED -ErrorAction SilentlyContinue

  $redactedExitCode = Invoke-Runner -Output $redactedRoot -InventoryOnly -Redact
  Assert-True ($redactedExitCode -eq 0) 'Redacted inventory-only run must succeed.'
  $redactedSummary = Get-Content (Join-Path $redactedRoot 'summary.json') -Raw | ConvertFrom-Json
  $redactedText = Get-Content (Join-Path $redactedRoot 'assessment.json') -Raw
  Assert-True ([bool]$redactedSummary.reportsRedacted) 'Summary must record report redaction.'
  Assert-True ($redactedText -notmatch 'vm-general|rg-fixture|nic-general') 'Redacted report must not expose resource names.'

  'Fleet assessment fixture tests: PASS'
} finally {
  Remove-Item Env:MANA_FAKE_STATE_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:MANA_FAKE_FAIL_GRAPH_ONCE -ErrorAction SilentlyContinue
  Remove-Item Env:MANA_FAKE_FAIL_RUN_ONCE -ErrorAction SilentlyContinue
  Remove-Item Env:MANA_FAKE_WINDOWS_RUNNING -ErrorAction SilentlyContinue
  Remove-Item Env:MANA_FAKE_INVENTORY_CHANGED -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
