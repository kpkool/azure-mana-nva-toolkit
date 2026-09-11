#requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateRange(1, 10)]
  [int]$Trials = 3,

  [ValidateRange(0, 10000)]
  [int]$PowerDelayMilliseconds = 300,

  [ValidateRange(0, 10000)]
  [int]$RunCommandDelayMilliseconds = 700,

  [ValidateRange(2, 32)]
  [int]$ParallelThrottleLimit = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runner = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/invoke-mana-fleet-assessment.ps1'
$fakeAz = Join-Path $PSScriptRoot 'fake-az.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "mana-fleet-benchmark-$PID"
$hostExecutable = (Get-Process -Id $PID).Path
$subscriptionId = '00000000-0000-0000-0000-000000000001'

function Get-Median([double[]]$Values) {
  $ordered = @($Values | Sort-Object)
  $middle = [Math]::Floor($ordered.Count / 2)
  if ($ordered.Count % 2 -eq 1) { return $ordered[$middle] }
  return ($ordered[$middle - 1] + $ordered[$middle]) / 2
}

function Invoke-BenchmarkTrial([int]$Trial, [int]$ThrottleLimit) {
  $trialRoot = Join-Path $testRoot "$Trial-$ThrottleLimit"
  $stateRoot = Join-Path $trialRoot 'state'
  $outputRoot = Join-Path $trialRoot 'output'
  New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
  $env:MANA_FAKE_STATE_DIR = $stateRoot

  $timer = [Diagnostics.Stopwatch]::StartNew()
  & $hostExecutable -NoProfile -File $runner `
    -SubscriptionId $subscriptionId `
    -OutputDirectory $outputRoot `
    -PageSize 2 `
    -MaxAttempts 1 `
    -ThrottleLimit $ThrottleLimit `
    -AzExecutable $fakeAz *> $null
  $exitCode = $LASTEXITCODE
  $timer.Stop()

  $calls = @(Get-Content -LiteralPath (Join-Path $stateRoot 'calls.log'))
  return [pscustomobject]@{
    trial          = $Trial
    throttleLimit  = $ThrottleLimit
    seconds        = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
    exitCode       = $exitCode
    azureCallCount = $calls.Count
    azureCallSet   = (@($calls | Sort-Object) -join '|')
    assessmentHash = (Get-FileHash -LiteralPath (Join-Path $outputRoot 'assessment.json') -Algorithm SHA256).Hash
  }
}

try {
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
  $env:MANA_FAKE_WINDOWS_RUNNING = '1'
  $env:MANA_FAKE_POWER_DELAY_MS = [string]$PowerDelayMilliseconds
  $env:MANA_FAKE_RUN_DELAY_MS = [string]$RunCommandDelayMilliseconds

  $samples = @(
    foreach ($trial in 1..$Trials) {
      Invoke-BenchmarkTrial -Trial $trial -ThrottleLimit 1
      Invoke-BenchmarkTrial -Trial $trial -ThrottleLimit $ParallelThrottleLimit
    }
  )
  if (@($samples | Where-Object exitCode -ne 0).Count -gt 0) { throw 'A benchmark run failed.' }
  if (@($samples.assessmentHash | Sort-Object -Unique).Count -ne 1) { throw 'Serial and parallel assessments differ.' }
  $expectedCalls = @(
    'graph-query', 'graph-query', 'graph-query',
    'power:vm-custom', 'power:vm-general', 'power:vm-windows',
    'run:vm-custom', 'run:vm-general', 'run:vm-windows'
  )
  $expectedCallSet = (@($expectedCalls | Sort-Object) -join '|')
  if (@($samples | Where-Object azureCallCount -ne $expectedCalls.Count).Count -gt 0) {
    throw "A benchmark run did not make the expected $($expectedCalls.Count) Azure calls."
  }
  if (@($samples | Where-Object azureCallSet -ne $expectedCallSet).Count -gt 0) {
    throw 'A benchmark run did not make the expected inventory and per-VM calls.'
  }

  $serialMedian = Get-Median @($samples | Where-Object throttleLimit -eq 1 | ForEach-Object seconds)
  $parallelMedian = Get-Median @($samples | Where-Object throttleLimit -eq $ParallelThrottleLimit | ForEach-Object seconds)
  if ($parallelMedian -ge $serialMedian) { throw 'Bounded concurrency did not improve median elapsed time.' }

  [pscustomobject][ordered]@{
    trials                 = $Trials
    candidateVmCount       = 3
    serialMedianSeconds    = [Math]::Round($serialMedian, 3)
    parallelMedianSeconds  = [Math]::Round($parallelMedian, 3)
    speedup                = [Math]::Round($serialMedian / $parallelMedian, 2)
    elapsedTimeReductionPc = [Math]::Round((1 - ($parallelMedian / $serialMedian)) * 100, 1)
    identicalAssessments   = $true
    azureCallsPerRun       = $expectedCalls.Count
  }
} finally {
  Remove-Item Env:MANA_FAKE_STATE_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:MANA_FAKE_WINDOWS_RUNNING -ErrorAction SilentlyContinue
  Remove-Item Env:MANA_FAKE_POWER_DELAY_MS -ErrorAction SilentlyContinue
  Remove-Item Env:MANA_FAKE_RUN_DELAY_MS -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}