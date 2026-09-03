#requires -Version 5.1
<#!
.SYNOPSIS
  Builds a resumable per-NIC MANA assessment without changing Azure resources.

.DESCRIPTION
  Paginates Azure Resource Graph, invokes one OS-specific guest validator per
  running candidate VM, and writes JSON, CSV, summary, and checkpoint files.
  Raw Run Command output is never persisted.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string[]]$SubscriptionId,

  [string]$OutputDirectory = './mana-assessment-output',

  [ValidateRange(1, 1000)]
  [int]$PageSize = 1000,

  [ValidateRange(1, 10)]
  [int]$MaxAttempts = 3,

  [ValidateRange(1, 60)]
  [int]$InitialRetryDelaySeconds = 2,

  [string[]]$ResourceGroup,
  [string[]]$VmName,
  [switch]$InventoryOnly,
  [switch]$Resume,
  [switch]$RedactResourceNames,
  [string]$AzExecutable = 'az'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$schemaVersion = '1.1'
$queryPath = Join-Path $PSScriptRoot 'inventory-mana-nics.kql'
$linuxValidatorPath = Join-Path $PSScriptRoot 'validate-nva-mana.sh'
$windowsValidatorPath = Join-Path $PSScriptRoot 'validate-nva-mana.ps1'
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$checkpointPath = Join-Path $OutputDirectory 'checkpoint.json'
$inventoryPath = Join-Path $OutputDirectory 'inventory.json'
$assessmentJsonPath = Join-Path $OutputDirectory 'assessment.json'
$assessmentCsvPath = Join-Path $OutputDirectory 'assessment.csv'
$summaryPath = Join-Path $OutputDirectory 'summary.json'
$eventPath = Join-Path $OutputDirectory 'events.jsonl'
$utf8NoBom = New-Object Text.UTF8Encoding($false)

function Write-TextAtomic {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
  $temporaryPath = "$Path.tmp.$PID"
  [IO.File]::WriteAllText($temporaryPath, $Content, $utf8NoBom)
  Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Write-JsonAtomic {
  param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
  Write-TextAtomic -Path $Path -Content ($Value | ConvertTo-Json -Depth 20)
}

function Write-RunEvent {
  param([string]$Level, [string]$Code, [string]$Resource = '')
  $event = [ordered]@{
    timestampUtc = [DateTime]::UtcNow.ToString('o')
    level        = $Level
    code         = $Code
    resource     = $Resource
  }
  [IO.File]::AppendAllText($eventPath, (($event | ConvertTo-Json -Compress) + [Environment]::NewLine), $utf8NoBom)
}

function Get-Sha256Text {
  param([Parameter(Mandatory)][string]$Text)
  $algorithm = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return (-join ($algorithm.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }))
  } finally {
    $algorithm.Dispose()
  }
}

function Get-SafeErrorCode {
  param([string]$Text)
  foreach ($knownCode in @(
    'AuthorizationFailed', 'ResourceNotFound', 'ResourceGroupNotFound',
    'OperationNotAllowed', 'Conflict', 'TooManyRequests', 'GatewayTimeout',
    'InvalidAuthenticationTokenTenant', 'VMExtensionProvisioningError'
  )) {
    if ($Text -match [regex]::Escape($knownCode)) { return $knownCode.ToUpperInvariant() }
  }
  if ($Text -match '(?m)^\((?<code>[A-Za-z][A-Za-z0-9]+)\)') {
    return $Matches.code.ToUpperInvariant()
  }
  return 'AZ_CLI_ERROR'
}

function Invoke-AzJson {
  param(
    [Parameter(Mandatory)][string[]]$Arguments,
    [Parameter(Mandatory)][string]$Operation
  )

  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $errorPath = Join-Path ([IO.Path]::GetTempPath()) "mana-az-$PID-$([guid]::NewGuid().ToString('N')).err"
    try {
      if ([IO.Path]::GetExtension($AzExecutable) -ieq '.ps1') {
        $powerShellHost = (Get-Process -Id $PID).Path
        $output = @(& $powerShellHost -NoProfile -File $AzExecutable @Arguments 2> $errorPath)
      } else {
        $output = @(& $AzExecutable @Arguments 2> $errorPath)
      }
      $exitCode = $LASTEXITCODE
      $errorText = if (Test-Path -LiteralPath $errorPath) { [IO.File]::ReadAllText($errorPath) } else { '' }
      if ($exitCode -eq 0) {
        try {
          $parsed = (($output -join [Environment]::NewLine) | ConvertFrom-Json)
          return [pscustomobject]@{ Success = $true; Data = $parsed; ErrorCode = $null; Attempts = $attempt }
        } catch {
          $errorCode = 'INVALID_JSON_RESPONSE'
        }
      } else {
        $errorCode = Get-SafeErrorCode -Text $errorText
      }
    } catch {
      $errorCode = 'AZ_CLI_EXECUTION_FAILED'
    } finally {
      Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    }

    Write-Warning "$Operation failed ($errorCode), attempt $attempt of $MaxAttempts."
    if ($attempt -lt $MaxAttempts) {
      $delay = [Math]::Min(60, $InitialRetryDelaySeconds * [Math]::Pow(2, $attempt - 1))
      Start-Sleep -Seconds ([int]$delay)
    }
  }

  return [pscustomobject]@{ Success = $false; Data = $null; ErrorCode = $errorCode; Attempts = $MaxAttempts }
}

function Get-ArgInventory {
  $records = @()
  $skipToken = $null
  $seenTokens = @{}
  $expectedTotal = $null
  $pageNumber = 0

  do {
    $pageNumber++
    $arguments = @('graph', 'query', '-q', "@$queryPath", '--subscriptions') + @($SubscriptionId) + @(
      '--first', [string]$PageSize, '-o', 'json', '--only-show-errors'
    )
    if ($skipToken) { $arguments += @('--skip-token', [string]$skipToken) }

    $response = Invoke-AzJson -Arguments $arguments -Operation "Resource Graph page $pageNumber"
    if (-not $response.Success) { throw "Resource Graph inventory failed ($($response.ErrorCode))." }

    $page = $response.Data
    if ($null -eq $expectedTotal) { $expectedTotal = [int]$page.total_records }
    $records += @($page.data)
    $nextToken = [string]$page.skip_token
    if ($nextToken) {
      if ($seenTokens.ContainsKey($nextToken)) { throw 'Resource Graph returned a repeated skip token.' }
      $seenTokens[$nextToken] = $true
    }
    $skipToken = $nextToken
  } while ($skipToken)

  $uniqueKeys = @{}
  foreach ($record in $records) {
    $recordKey = "$($record.VMId)|$($record.NICId)"
    if ($uniqueKeys.ContainsKey($recordKey)) { throw "Resource Graph returned a duplicate record key: $recordKey" }
    $uniqueKeys[$recordKey] = $true
  }
  if ($records.Count -ne $expectedTotal) {
    throw "Resource Graph paging was incomplete: expected $expectedTotal records, received $($records.Count)."
  }
  return @($records)
}

function Get-RedactedValue {
  param([string]$Prefix, [string]$Value, [string]$Salt)
  if (-not $Value) { return '' }
  return "$Prefix-$((Get-Sha256Text -Text "$Salt|$Value").Substring(0, 12))"
}

function Convert-InventoryRecord {
  param($Record, [string]$Salt)
  $copy = [ordered]@{}
  foreach ($property in $Record.PSObject.Properties) { $copy[$property.Name] = $property.Value }
  if ($RedactResourceNames) {
    $copy.subscriptionId = Get-RedactedValue 'sub' ([string]$Record.subscriptionId) $Salt
    $copy.resourceGroup = Get-RedactedValue 'rg' ([string]$Record.resourceGroup) $Salt
    $copy.VMName = Get-RedactedValue 'vm' ([string]$Record.VMName) $Salt
    $copy.VMId = Get-RedactedValue 'vmid' ([string]$Record.VMId) $Salt
    $copy.NICName = Get-RedactedValue 'nic' ([string]$Record.NICName) $Salt
    $copy.NICId = Get-RedactedValue 'nicid' ([string]$Record.NICId) $Salt
  }
  return [pscustomobject]$copy
}

function Save-Checkpoint {
  param($Checkpoint)
  $Checkpoint.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
  Write-JsonAtomic -Value $Checkpoint -Path $checkpointPath
}

function Set-GuestResult {
  param($Checkpoint, $Result, [bool]$MarkComplete)
  $Checkpoint.guestResults = @($Checkpoint.guestResults | Where-Object { $_.vmId -ne $Result.vmId }) + @($Result)
  if ($MarkComplete) {
    $Checkpoint.completedVmIds = @($Checkpoint.completedVmIds + @($Result.vmId) | Sort-Object -Unique)
  }
  Save-Checkpoint -Checkpoint $Checkpoint
}

function Get-GuestResult {
  param($VmRecord)
  $vmLabel = [string]$VmRecord.VMName
  $powerArguments = @(
    'vm', 'get-instance-view', '--subscription', [string]$VmRecord.subscriptionId,
    '--resource-group', [string]$VmRecord.resourceGroup, '--name', [string]$VmRecord.VMName,
    '--query', "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]",
    '-o', 'json', '--only-show-errors'
  )
  $powerResponse = Invoke-AzJson -Arguments $powerArguments -Operation "Power-state check for $vmLabel"
  if (-not $powerResponse.Success) {
    return [pscustomobject][ordered]@{
      vmId = $VmRecord.VMId; probeStatus = 'ERROR'; powerState = 'UNKNOWN';
      errorCode = $powerResponse.ErrorCode; evidence = $null; attempts = $powerResponse.Attempts
    }
  }

  $powerState = [string]$powerResponse.Data
  if ($powerState -ne 'PowerState/running') {
    return [pscustomobject][ordered]@{
      vmId = $VmRecord.VMId; probeStatus = 'NOT_RUNNING'; powerState = $powerState;
      errorCode = 'VM_NOT_RUNNING'; evidence = $null; attempts = $powerResponse.Attempts
    }
  }

  switch -Regex ([string]$VmRecord.OSType) {
    '^Linux$'   { $commandId = 'RunShellScript'; $validatorPath = $linuxValidatorPath; break }
    '^Windows$' { $commandId = 'RunPowerShellScript'; $validatorPath = $windowsValidatorPath; break }
    default {
      return [pscustomobject][ordered]@{
        vmId = $VmRecord.VMId; probeStatus = 'UNSUPPORTED_OS'; powerState = $powerState;
        errorCode = 'STANDARD_GUEST_PROBE_UNSUPPORTED'; evidence = $null; attempts = $powerResponse.Attempts
      }
    }
  }

  $runArguments = @(
    'vm', 'run-command', 'invoke', '--subscription', [string]$VmRecord.subscriptionId,
    '--resource-group', [string]$VmRecord.resourceGroup, '--name', [string]$VmRecord.VMName,
    '--command-id', $commandId, '--scripts', "@$validatorPath", '-o', 'json', '--only-show-errors'
  )
  $runResponse = Invoke-AzJson -Arguments $runArguments -Operation "Guest validation for $vmLabel"
  if (-not $runResponse.Success) {
    return [pscustomobject][ordered]@{
      vmId = $VmRecord.VMId; probeStatus = 'ERROR'; powerState = $powerState;
      errorCode = $runResponse.ErrorCode; evidence = $null; attempts = $runResponse.Attempts
    }
  }

  $message = (@($runResponse.Data.value | ForEach-Object { $_.message }) -join [Environment]::NewLine)
  $matches = [regex]::Matches($message, 'MANA_RESULT_JSON=(\{[^\r\n]*\})')
  if ($matches.Count -eq 0) {
    return [pscustomobject][ordered]@{
      vmId = $VmRecord.VMId; probeStatus = 'ERROR'; powerState = $powerState;
      errorCode = 'STRUCTURED_RESULT_MISSING'; evidence = $null; attempts = $runResponse.Attempts
    }
  }
  try {
    $evidence = $matches[$matches.Count - 1].Groups[1].Value | ConvertFrom-Json
    $requiredProperties = @(
      'schemaVersion', 'guestEvidenceStatus', 'reasonCode', 'hardwareState',
      'datapathState', 'guestEvidenceScope', 'datapathScope',
      'customizationRisk', 'customizationSignals'
    )
    $evidenceProperties = @($evidence.PSObject.Properties.Name)
    if ($evidence.schemaVersion -ne $schemaVersion -or @($requiredProperties | Where-Object { $evidenceProperties -notcontains $_ }).Count -gt 0) {
      throw 'Unsupported or incomplete structured result schema.'
    }
  } catch {
    return [pscustomobject][ordered]@{
      vmId = $VmRecord.VMId; probeStatus = 'ERROR'; powerState = $powerState;
      errorCode = 'STRUCTURED_RESULT_INVALID'; evidence = $null; attempts = $runResponse.Attempts
    }
  }
  return [pscustomobject][ordered]@{
    vmId = $VmRecord.VMId; probeStatus = 'SUCCESS'; powerState = $powerState;
    errorCode = $null; evidence = $evidence; attempts = $runResponse.Attempts
  }
}

function Get-FinalClassification {
  param($InventoryRecord, $GuestResult)

  if ($InventoryRecord.ExposureStatus -eq 'NOT_EXPOSED') {
    return @('NOT_APPLICABLE', 'HIGH', 'AN_DISABLED', 'NONE')
  }
  if ($InventoryRecord.ExposureStatus -eq 'UNKNOWN') {
    return @('UNKNOWN', 'LOW', [string]$InventoryRecord.ReasonCode, [string]$InventoryRecord.RequiredAction)
  }
  if ($InventoryOnly) {
    return @('UNKNOWN', 'LOW', 'INVENTORY_ONLY', 'RUN_GUEST_OR_VENDOR_VALIDATION')
  }
  if ($null -eq $GuestResult) {
    return @('UNKNOWN', 'LOW', 'GUEST_RESULT_MISSING', 'RESUME_ASSESSMENT')
  }
  switch ($GuestResult.probeStatus) {
    'NOT_RUNNING'    { return @('UNKNOWN', 'LOW', 'VM_NOT_RUNNING', 'RUN_WHEN_VM_IS_RUNNING') }
    'ERROR'          { return @('UNKNOWN', 'LOW', [string]$GuestResult.errorCode, 'RESUME_ASSESSMENT') }
    'UNSUPPORTED_OS' { return @('REVIEW_REQUIRED', 'LOW', 'VENDOR_VALIDATION_REQUIRED', 'CONFIRM_VENDOR_SUPPORT_AND_RUN_PILOT') }
  }

  $evidence = $GuestResult.evidence
  if ($evidence.guestEvidenceStatus -eq 'NOT_READY') {
    return @('NOT_READY', 'HIGH', [string]$evidence.reasonCode, 'REMEDIATE_MANA_DRIVER_THEN_RETEST')
  }
  if ($evidence.guestEvidenceStatus -eq 'PASS' -and
      $evidence.hardwareState -eq 'MANA' -and
      $evidence.datapathState -ne 'CONFIRMED') {
    return @('UNKNOWN', 'LOW', 'MANA_DATAPATH_NOT_CONFIRMED', 'GENERATE_TRAFFIC_AND_RETEST')
  }
  if ($evidence.customizationRisk -eq 'REVIEW_REQUIRED') {
    return @('REVIEW_REQUIRED', 'MEDIUM', 'CUSTOMIZATION_REVIEW_REQUIRED', 'REVIEW_CUSTOM_NIC_CONFIG_AND_RUN_PILOT')
  }
  if ($InventoryRecord.ImageSource -in @('Gallery/Custom', 'Custom/VHD')) {
    return @('REVIEW_REQUIRED', 'LOW', 'CUSTOM_IMAGE_VALIDATION_REQUIRED', 'VALIDATE_IMAGE_DRIVERS_AND_RUN_PILOT')
  }
  if ($InventoryRecord.NVAClass -ne 'General (platform OS)') {
    return @('REVIEW_REQUIRED', 'LOW', 'VENDOR_VALIDATION_REQUIRED', 'CONFIRM_VENDOR_SUPPORT_AND_RUN_PILOT')
  }
  if ($evidence.guestEvidenceStatus -eq 'PASS' -and $evidence.hardwareState -eq 'MANA') {
    return @('REVIEW_REQUIRED', 'MEDIUM', 'MANA_WORKLOAD_PILOT_REQUIRED', 'RUN_WORKLOAD_PILOT')
  }
  if ($evidence.guestEvidenceStatus -eq 'PASS') {
    return @('REVIEW_REQUIRED', 'LOW', 'MANA_PLACEMENT_PILOT_REQUIRED', 'RUN_MANA_PLACEMENT_PILOT')
  }
  return @('UNKNOWN', 'LOW', [string]$evidence.reasonCode, 'REVIEW_GUEST_EVIDENCE')
}

foreach ($requiredFile in @($queryPath, $linuxValidatorPath, $windowsValidatorPath)) {
  if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) { throw "Required file not found: $requiredFile" }
}
if (-not (Get-Command $AzExecutable -ErrorAction SilentlyContinue)) { throw "Azure CLI executable not found: $AzExecutable" }
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }

$normalizedSubscriptions = @($SubscriptionId | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
$configurationText = @(
  "subscriptions=$($normalizedSubscriptions -join ',')",
  "resourceGroups=$(@($ResourceGroup | Sort-Object) -join ',')",
  "vmNames=$(@($VmName | Sort-Object) -join ',')",
  "inventoryOnly=$([bool]$InventoryOnly)",
  "redact=$([bool]$RedactResourceNames)",
  "query=$((Get-FileHash -LiteralPath $queryPath -Algorithm SHA256).Hash)",
  "linux=$((Get-FileHash -LiteralPath $linuxValidatorPath -Algorithm SHA256).Hash)",
  "windows=$((Get-FileHash -LiteralPath $windowsValidatorPath -Algorithm SHA256).Hash)"
) -join "`n"
$configurationHash = Get-Sha256Text -Text $configurationText

if ($Resume) {
  if (-not (Test-Path -LiteralPath $checkpointPath)) { throw "Resume requested but checkpoint not found: $checkpointPath" }
  $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
  if ($checkpoint.configurationHash -ne $configurationHash) {
    throw 'Checkpoint configuration does not match the current subscriptions, filters, mode, or script hashes.'
  }
} else {
  if (Test-Path -LiteralPath $checkpointPath) { throw "Checkpoint already exists. Use -Resume or choose another output directory: $checkpointPath" }
  $checkpoint = [pscustomobject][ordered]@{
    schemaVersion      = $schemaVersion
    configurationHash = $configurationHash
    startedAtUtc       = [DateTime]::UtcNow.ToString('o')
    updatedAtUtc       = [DateTime]::UtcNow.ToString('o')
    redactionSalt      = [guid]::NewGuid().ToString('N')
    completedVmIds     = @()
    guestResults       = @()
  }
}

Write-RunEvent -Level 'INFO' -Code 'INVENTORY_STARTED'
$inventory = @(Get-ArgInventory)
if ($ResourceGroup) { $inventory = @($inventory | Where-Object { $ResourceGroup -contains $_.resourceGroup }) }
if ($VmName) { $inventory = @($inventory | Where-Object { $VmName -contains $_.VMName }) }
$inventoryHash = Get-Sha256Text -Text (ConvertTo-Json -InputObject ([object[]]$inventory) -Depth 20 -Compress)
if ($Resume) {
  if ($checkpoint.PSObject.Properties.Name -notcontains 'inventoryHash' -or
      $checkpoint.inventoryHash -ne $inventoryHash) {
    throw 'Azure inventory changed since this assessment started. Use a new output directory for fresh evidence.'
  }
} else {
  Add-Member -InputObject $checkpoint -NotePropertyName inventoryHash -NotePropertyValue $inventoryHash
  Save-Checkpoint -Checkpoint $checkpoint
}
$publicInventory = @($inventory | ForEach-Object { Convert-InventoryRecord -Record $_ -Salt $checkpoint.redactionSalt })
Write-JsonAtomic -Value @($publicInventory) -Path $inventoryPath
Write-RunEvent -Level 'INFO' -Code 'INVENTORY_COMPLETED'

$vmGroups = @($inventory | Group-Object -Property VMId | Sort-Object Name)
if (-not $InventoryOnly) {
  foreach ($vmGroup in $vmGroups) {
    $vmId = [string]$vmGroup.Name
    if ($checkpoint.completedVmIds -contains $vmId) { continue }
    $vmRecord = $vmGroup.Group | Select-Object -First 1
    $hasCandidateNic = @($vmGroup.Group | Where-Object { $_.ExposureStatus -eq 'POTENTIAL' }).Count -gt 0
    if (-not $hasCandidateNic) {
      $hasUnknownExposure = @($vmGroup.Group | Where-Object { $_.ExposureStatus -eq 'UNKNOWN' }).Count -gt 0
      $guestResult = [pscustomobject][ordered]@{
        vmId = $vmId; probeStatus = if ($hasUnknownExposure) { 'SKIPPED_EXPOSURE_UNKNOWN' } else { 'SKIPPED_AN_DISABLED' };
        powerState = 'NOT_QUERIED'; errorCode = if ($hasUnknownExposure) { 'NIC_DATA_MISSING' } else { $null };
        evidence = $null; attempts = 0
      }
      Set-GuestResult -Checkpoint $checkpoint -Result $guestResult -MarkComplete $true
      continue
    }

    $eventResource = if ($RedactResourceNames) {
      Get-RedactedValue 'vm' ([string]$vmRecord.VMName) $checkpoint.redactionSalt
    } else { [string]$vmRecord.VMName }
    Write-RunEvent -Level 'INFO' -Code 'GUEST_PROBE_STARTED' -Resource $eventResource
    $guestResult = Get-GuestResult -VmRecord $vmRecord
    $markComplete = $guestResult.probeStatus -in @('SUCCESS', 'UNSUPPORTED_OS')
    Set-GuestResult -Checkpoint $checkpoint -Result $guestResult -MarkComplete $markComplete
    $eventLevel = if ($markComplete) { 'INFO' } else { 'WARN' }
    Write-RunEvent -Level $eventLevel -Code "GUEST_PROBE_$($guestResult.probeStatus)" -Resource $eventResource
  }
}

$assessment = @()
foreach ($record in $inventory) {
  $guestResult = @($checkpoint.guestResults | Where-Object { $_.vmId -eq $record.VMId } | Select-Object -First 1)
  if ($guestResult.Count -eq 0) { $guestResult = $null } else { $guestResult = $guestResult[0] }
  $classification = Get-FinalClassification -InventoryRecord $record -GuestResult $guestResult
  $publicRecord = Convert-InventoryRecord -Record $record -Salt $checkpoint.redactionSalt
  $evidence = if ($guestResult -and $guestResult.evidence) { $guestResult.evidence } else { $null }
  $assessment += [pscustomobject][ordered]@{
    schemaVersion               = $schemaVersion
    subscriptionId              = $publicRecord.subscriptionId
    resourceGroup               = $publicRecord.resourceGroup
    VMName                      = $publicRecord.VMName
    VMId                        = $publicRecord.VMId
    NICName                     = $publicRecord.NICName
    NICId                       = $publicRecord.NICId
    NICPrimary                  = $record.NICPrimary
    AcceleratedNetworking       = $record.AcceleratedNetworking
    ExposureStatus              = $record.ExposureStatus
    ExposureReasonCode          = $record.ReasonCode
    ReadinessStatus             = $classification[0]
    Confidence                  = $classification[1]
    ReasonCode                  = $classification[2]
    RequiredAction              = $classification[3]
    GuestProbeStatus            = if ($guestResult) { $guestResult.probeStatus } else { 'NOT_RUN' }
    GuestEvidenceStatus         = if ($evidence) { $evidence.guestEvidenceStatus } else { 'UNKNOWN' }
    GuestEvidenceReasonCode     = if ($evidence) { $evidence.reasonCode } else { 'GUEST_EVIDENCE_UNAVAILABLE' }
    GuestEvidenceScope          = if ($evidence) { $evidence.guestEvidenceScope } else { 'UNKNOWN' }
    HardwareState               = if ($evidence) { $evidence.hardwareState } else { 'UNKNOWN' }
    DatapathState               = if ($evidence) { $evidence.datapathState } else { 'UNKNOWN' }
    DatapathScope               = if ($evidence) { $evidence.datapathScope } else { 'UNKNOWN' }
    CustomizationRisk           = if ($evidence) { $evidence.customizationRisk } else { 'UNKNOWN' }
    CustomizationSignals        = if ($evidence) { @($evidence.customizationSignals) -join ';' } else { '' }
    PowerState                  = if ($guestResult) { $guestResult.powerState } else { 'NOT_QUERIED' }
    NVAClass                    = $record.NVAClass
    ImageSource                 = $record.ImageSource
    Vendor                      = $record.Vendor
    PlanPublisher               = $record.PlanPublisher
    PlanProduct                 = $record.PlanProduct
    OSType                      = $record.OSType
    OSVersion                   = $record.OSVersion
    VMSize                      = $record.VMSize
    LegacyVMNVATag              = $record.LegacyVMNVATag
    location                    = $record.location
  }
}

$failedGuestResults = @($checkpoint.guestResults | Where-Object { $_.probeStatus -in @('ERROR', 'NOT_RUNNING') })
$summary = [pscustomobject][ordered]@{
  schemaVersion       = $schemaVersion
  generatedAtUtc      = [DateTime]::UtcNow.ToString('o')
  runStatus           = if ($failedGuestResults.Count -gt 0) { 'PARTIAL' } elseif ($InventoryOnly) { 'INVENTORY_ONLY' } else { 'COMPLETE' }
  reportsRedacted     = [bool]$RedactResourceNames
  rawGuestOutputSaved = $false
  subscriptionCount   = $normalizedSubscriptions.Count
  vmCount             = $vmGroups.Count
  nicCount            = $assessment.Count
  failedVmCount       = $failedGuestResults.Count
  exposureCounts      = @($assessment | Group-Object ExposureStatus | ForEach-Object { [pscustomobject]@{ status = $_.Name; count = $_.Count } })
  readinessCounts     = @($assessment | Group-Object ReadinessStatus | ForEach-Object { [pscustomobject]@{ status = $_.Name; count = $_.Count } })
  reasonCodeCounts    = @($assessment | Group-Object ReasonCode | ForEach-Object { [pscustomobject]@{ reasonCode = $_.Name; count = $_.Count } })
  files               = [ordered]@{
    inventory  = 'inventory.json'
    assessment = 'assessment.json'
    csv        = 'assessment.csv'
    checkpoint = 'checkpoint.json'
    events     = 'events.jsonl'
  }
}

Write-JsonAtomic -Value @($assessment) -Path $assessmentJsonPath
$csvTemporaryPath = "$assessmentCsvPath.tmp.$PID"
@($assessment) | Export-Csv -LiteralPath $csvTemporaryPath -NoTypeInformation -Encoding UTF8
Move-Item -LiteralPath $csvTemporaryPath -Destination $assessmentCsvPath -Force
Write-JsonAtomic -Value $summary -Path $summaryPath
Write-RunEvent -Level 'INFO' -Code "RUN_$($summary.runStatus)"

Write-Host "MANA assessment: $($summary.runStatus)"
Write-Host "VMs: $($summary.vmCount)  NICs: $($summary.nicCount)  Failed/pending VMs: $($summary.failedVmCount)"
Write-Host "Reports: $OutputDirectory"
if ($summary.runStatus -eq 'PARTIAL') { exit 2 }
