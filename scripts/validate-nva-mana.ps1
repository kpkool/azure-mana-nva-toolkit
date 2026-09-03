<#
  validate-nva-mana.ps1 — per-VM MANA readiness validator (Windows)
  Checks, at the VM level: (1) LegacyVMNVA tag, (2) MANA hardware present,
  (3) MANA driver installed, (4) adapter functioning, plus link sanity.
  Run without RDP via:
    az vm run-command invoke -g <rg> -n <vm> --command-id RunPowerShellScript `
      --scripts "@scripts/validate-nva-mana.ps1" --query "value[0].message" -o tsv
#>
# Fail loud: every external call is wrapped in try/catch so a failed check becomes an explicit UNKNOWN
# state (never a silent "safe" negative). ErrorActionPreference=Stop makes cmdlet errors catchable.
$ErrorActionPreference = 'Stop'
function Row($tag,$msg){ "[{0,-4}] {1}" -f $tag,$msg }
function Line(){ '-' * 60 }
function Add-CustomizationSignal([string]$code) {
  if ($script:customizationSignals -notcontains $code) { $script:customizationSignals += $code }
}

$imds = 'http://169.254.169.254/metadata/instance'
$hdr  = @{ Metadata = 'true' }

# Tri-state check results: 'yes' | 'no' | 'unknown'. Any 'unknown' forces an UNKNOWN verdict.
$tagState = 'unknown'; $hwState = 'unknown'; $drvState = 'unknown'; $anState = 'unknown'
$datapathState = 'NOT_APPLICABLE'
$checkErrors = @()
$customizationSignals = @()

"############ MANA NVA VALIDATOR (Windows) ############"
"host: $env:COMPUTERNAME   date: $((Get-Date).ToUniversalTime().ToString('s'))Z"
Line

# ---- 0. Identity + size (IMDS) ----
"== Identity =="
$compute = $null
try {
  $compute = Invoke-RestMethod -Headers $hdr -Uri "$imds/compute?api-version=2021-02-01" -TimeoutSec 10
  Row 'INFO' "VM name (IMDS): $($compute.name)"
  Row 'INFO' "VM size (IMDS): $($compute.vmSize)"
} catch {
  Row 'ERR ' "IMDS query FAILED ($($_.Exception.Message)) -> identity/tag UNKNOWN"
  $checkErrors += 'IMDS (identity/tag)'
}
Line

# ---- 1. Tag check (LegacyVMNVA) ----
"== 1. LegacyVMNVA tag =="
if ($null -eq $compute) {
  Row 'ERR ' 'Cannot read tags (IMDS check failed) -> tag state UNKNOWN'
  $tagState = 'unknown'
} else {
  $tag = $compute.tagsList | Where-Object { $_.name -ieq 'LegacyVMNVA' }
  if ($null -eq $tag -and $compute.tags) {
    # older format: "name:value;name:value"
    $pair = ($compute.tags -split ';') | Where-Object { $_ -match '^(?i)LegacyVMNVA:' }
    if ($pair) { $tag = [pscustomobject]@{ name='LegacyVMNVA'; value=($pair -split ':')[1] } }
  }
  if ($tag) { $tagState = 'yes'; Row 'PASS' 'LegacyVMNVA tag present' }
  else      { $tagState = 'no';  Row 'WARN' "LegacyVMNVA tag NOT present (exception not applied to this VM)" }
}
Line

# ---- 2. MANA hardware present (PCI VEN_1414 DEV_00BA) ----
"== 2. MANA hardware (PCI VEN_1414&DEV_00BA) =="
$onManaHw = $null                      # $true / $false / $null (unknown)
try {
  $pnp = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '^PCI\\VEN_1414&DEV_00BA&' }
  $onManaHw = [bool]$pnp
  if ($pnp) { $hwState = 'yes'; $pnp | Select-Object Status,Class,FriendlyName | Format-Table -Auto | Out-String | Write-Output
              Row 'PASS' 'MANA NIC PCI device present (Microsoft Azure Network Adapter Virtual Bus)' }
  else      { $hwState = 'no';  Row 'INFO' 'MANA PCI device not observed; inspect the accelerated adapter description before naming another NIC family' }
} catch {
  Row 'ERR ' "Get-PnpDevice FAILED ($($_.Exception.Message)) -> MANA hardware state UNKNOWN"
  $checkErrors += 'Get-PnpDevice (hardware)'
}
Line

# ---- 3. MANA driver installed (adapter exposed) ----
"== 3. MANA driver (adapter) =="
$adapters = @(); $mana = @(); $manaUp = @(); $accel = @(); $anEnabled = $null    # $null = unknown
try {
  $adapters = Get-NetAdapter                     # cache once; reused in sections 3-5
  $mana = @($adapters | Where-Object InterfaceDescription -Like '*Microsoft Azure Network Adapter*')
  $manaUp = @($mana | Where-Object Status -eq 'Up')
  $adapters | Select-Object Name,InterfaceDescription,Status,LinkSpeed | Format-Table -Auto | Out-String | Write-Output
  if ($mana) {
    $drvState = 'yes'
    if ($manaUp.Count -eq $mana.Count) { Row 'PASS' "All $($mana.Count) MANA adapter(s) are present, loaded, and Up" }
    else { Row 'WARN' "$($mana.Count - $manaUp.Count) of $($mana.Count) MANA adapter(s) do not report Up" }
  }
  elseif ($onManaHw -eq $true) { $drvState = 'no'; Row 'FAIL' 'On MANA hardware but MANA adapter NOT exposed -> driver missing -> NetVSC fallback. Install driver: https://aka.ms/manawindowsdrivers' }
  else { $drvState = 'no'; Row 'INFO' 'No MANA adapter (expected when not on MANA hardware)' }
  # Accelerated Networking present = an SR-IOV VF from a known family (Mellanox ConnectX or MANA); report EVERY such NIC (multi-NIC NVAs)
  $vfPattern = 'Mellanox|Microsoft Azure Network Adapter'
  $accel = @($adapters | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match $vfPattern })
  $anEnabled = [bool]$accel.Count
  if ($anEnabled) {
    $anState = 'yes'
    foreach ($a in $accel) { Row 'INFO' "Accelerated VF NIC: $($a.Name) - $($a.InterfaceDescription)" }
  } else { $anState = 'unknown'; Row 'WARN' 'No guest VF detected -> verify Accelerated Networking on the Azure NIC resource' }
} catch {
  Row 'ERR ' "Get-NetAdapter FAILED ($($_.Exception.Message)) -> driver/AN state UNKNOWN"
  $checkErrors += 'Get-NetAdapter (driver/AN)'
}
Line

# ---- 4. Adapter functioning (statistics) ----
"== 4. Adapter functioning (statistics) =="
if ($mana) {
  $beforeStatistics = @{}
  $statisticsErrors = 0
  foreach ($adapter in $mana) {
    try {
      $beforeStatistics[$adapter.Name] = [uint64](($adapter | Get-NetAdapterStatistics -ErrorAction Stop).ReceivedBytes)
    } catch {
      $statisticsErrors++
      $checkErrors += "Get-NetAdapterStatistics ($($adapter.Name))"
      Row 'ERR ' "Get-NetAdapterStatistics FAILED for $($adapter.Name) ($($_.Exception.Message))"
    }
  }
  if ($beforeStatistics.Count -gt 0) { Start-Sleep -Seconds 2 }
  $incrementingAdapters = 0
  foreach ($adapter in $mana) {
    if (-not $beforeStatistics.ContainsKey($adapter.Name)) { continue }
    try {
      $before = $beforeStatistics[$adapter.Name]
      $after = [uint64](($adapter | Get-NetAdapterStatistics -ErrorAction Stop).ReceivedBytes)
      "$($adapter.Name) ReceivedBytes: $before -> $after"
      if ($after -gt $before) {
        $incrementingAdapters++
        Row 'PASS' "MANA adapter $($adapter.Name) counters incremented"
      } else {
        Row 'WARN' "MANA adapter $($adapter.Name) counters did not increment"
      }
    } catch {
      $statisticsErrors++
      $checkErrors += "Get-NetAdapterStatistics ($($adapter.Name))"
      Row 'ERR ' "Get-NetAdapterStatistics FAILED for $($adapter.Name) ($($_.Exception.Message))"
    }
  }
  if ($statisticsErrors -gt 0) { $datapathState = 'UNKNOWN' }
  elseif ($incrementingAdapters -gt 0) { $datapathState = 'CONFIRMED'; Row 'PASS' 'Traffic was observed through the VM-shared MANA VF' }
  else { $datapathState = 'NOT_CONFIRMED'; Row 'WARN' 'No MANA adapter counters incremented; datapath is not confirmed' }
} else { Row 'INFO' 'No MANA adapter to measure' }
Line

# ---- 5. Link sanity (extra tests) ----
"== 5. Link sanity =="
if ($adapters) { $adapters | Where-Object Status -eq 'Up' | Select-Object Name,LinkSpeed,MtuSize,MacAddress | Format-Table -Auto | Out-String | Write-Output }
else { Row 'INFO' 'Adapter list unavailable (Get-NetAdapter failed above)' }
Line

# ---- 6. Non-sensitive customization risk signals ----
"== 6. Custom NIC configuration risk signals =="
try {
  $ipInterfaces = @(Get-NetIPInterface -AddressFamily IPv4)
  if ($ipInterfaces | Where-Object { $_.Dhcp -eq 'Disabled' -and $_.ConnectionState -eq 'Connected' }) {
    Add-CustomizationSignal 'DHCP_DISABLED_ON_CONNECTED_INTERFACE'
  }
} catch {
  Row 'WARN' "Get-NetIPInterface failed while checking DHCP state ($($_.Exception.Message))"
}
try {
  $persistentRoutes = @(Get-NetRoute -PolicyStore PersistentStore -ErrorAction Stop | Where-Object {
    $_.DestinationPrefix -notin @('0.0.0.0/0', '::/0')
  })
  if ($persistentRoutes.Count -gt 0) { Add-CustomizationSignal 'PERSISTENT_STATIC_ROUTE' }
} catch {
  Row 'INFO' 'Persistent-route store could not be inspected'
}
if (Get-Command Get-NetLbfoTeam -ErrorAction SilentlyContinue) {
  try { if (@(Get-NetLbfoTeam -ErrorAction Stop).Count -gt 0) { Add-CustomizationSignal 'LBFO_TEAM' } } catch {}
}
if (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) {
  try { if (@(Get-VMSwitch -ErrorAction Stop).Count -gt 0) { Add-CustomizationSignal 'HYPERV_SWITCH' } } catch {}
}
if (Get-Command Get-NetNat -ErrorAction SilentlyContinue) {
  try { if (@(Get-NetNat -ErrorAction Stop).Count -gt 0) { Add-CustomizationSignal 'WINDOWS_NETNAT' } } catch {}
}
try {
  $userSpaceDrivers = @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop | Where-Object {
    $_.Name -match '(?i)dpdk|netmap|windivert' -or $_.PathName -match '(?i)dpdk|netmap|windivert'
  })
  if ($userSpaceDrivers.Count -gt 0) { Add-CustomizationSignal 'USERSPACE_OR_PACKET_DRIVER' }
} catch {
  Row 'INFO' 'System-driver inventory could not be inspected'
}
if ($accel) {
  try {
    foreach ($vf in $accel) {
      $vfIp = @(Get-NetIPAddress -InterfaceIndex $vf.ifIndex -ErrorAction SilentlyContinue | Where-Object {
        $_.AddressState -eq 'Preferred' -and $_.IPAddress -notmatch '^(127\.|::1$|fe80:)'
      })
      if ($vfIp.Count -gt 0) { Add-CustomizationSignal 'IP_BOUND_TO_ACCELERATED_VF'; break }
    }
  } catch {
    Row 'INFO' 'Accelerated-VF IP binding could not be inspected'
  }
}
$customizationRisk = if ($customizationSignals.Count -gt 0) { 'REVIEW_REQUIRED' } else { 'NONE_DETECTED' }
if ($customizationSignals.Count -gt 0) {
  Row 'WARN' "Customization signals detected (codes only): $($customizationSignals -join ',')"
} else {
  Row 'INFO' 'No reviewed customization signals detected; this is not proof that none exist'
}
Line

# ---- SUMMARY VERDICT ----
"== SUMMARY =="
"(Reports hardware/driver/AN facts only. NVA-vs-general-workload classification comes from your vendor/CMDB; the LegacyVMNVA tag is only for AN-based NVAs, not general VMs.)"
"A guest PASS does not approve migration; image/vendor review and a representative workload pilot remain separate gates."
if ($checkErrors.Count -gt 0 -or $hwState -eq 'unknown' -or $drvState -eq 'unknown') {
  $guestEvidenceStatus = 'UNKNOWN'; $reasonCode = 'GUEST_CHECK_INCOMPLETE'
  "VERDICT: UNKNOWN - one or more checks failed, so MANA state could NOT be determined (do NOT treat as 'no action'). Failed: $([string]::Join('; ', $checkErrors)). Re-run; if it persists, verify IMDS reachability and run elevated."
}
elseif ($onManaHw -eq $true -and $mana -and $manaUp.Count -ne $mana.Count) {
  $guestEvidenceStatus = 'UNKNOWN'; $reasonCode = 'MANA_ADAPTER_NOT_UP'
  'VERDICT: UNKNOWN - one or more MANA adapters do not report Up. Investigate before declaring readiness.'
}
elseif ($onManaHw -eq $true -and $mana -and $datapathState -ne 'CONFIRMED') {
  $guestEvidenceStatus = 'UNKNOWN'; $reasonCode = 'MANA_DATAPATH_NOT_CONFIRMED'
  'VERDICT: UNKNOWN - MANA adapter is present, but traffic through the VF was not confirmed. Generate representative traffic and retest.'
}
elseif ($onManaHw -eq $true -and $mana) {
  $guestEvidenceStatus = 'PASS'; $reasonCode = 'MANA_ADAPTER_PRESENT'
  'VERDICT: ON MANA, adapter is Up and VF traffic was observed. If this is an NVA or custom image, vendor/image review and a workload pilot are still required.'
}
elseif ($onManaHw -eq $true -and -not $mana) {
  $guestEvidenceStatus = 'NOT_READY'; $reasonCode = 'MANA_ADAPTER_MISSING'
  'VERDICT: ON MANA hardware but driver MISSING -> NetVSC fallback. Install MANA driver (aka.ms/manawindowsdrivers); if this is an NVA that degrades, keep LegacyVMNVA.'
}
elseif ($anState -ne 'yes') {
  $guestEvidenceStatus = 'UNKNOWN'; $reasonCode = 'GUEST_VF_NOT_DETECTED'
  'VERDICT: UNKNOWN - no guest VF was detected. Verify Accelerated Networking on the Azure NIC resource; guest visibility is not authoritative.'
}
else {
  $guestEvidenceStatus = 'UNKNOWN'; $reasonCode = 'NON_MANA_REQUIRES_PILOT'
  'VERDICT: NOT on MANA (on Mellanox/ConnectX). Current operation is visible, but future MANA readiness is UNKNOWN until a MANA pilot or vendor evidence confirms it.'
}
if ($tagState -eq 'unknown') { Row 'ERR ' 'Tag state UNKNOWN (IMDS failed) - re-check the tag before relying on it' }
"####################################################"
$result = [ordered]@{
  schemaVersion        = '1.1'
  os                   = 'Windows'
  guestEvidenceStatus  = $guestEvidenceStatus
  reasonCode           = $reasonCode
  guestEvidenceScope   = 'VM'
  hardwareState        = if ($hwState -eq 'yes') { 'MANA' } elseif ($hwState -eq 'no') { 'NON_MANA' } else { 'UNKNOWN' }
  guestAnState         = $anState
  manaAdapterPresent   = [bool]$mana
  manaAdapterCount     = $mana.Count
  manaAdaptersUp       = $manaUp.Count
  datapathState        = $datapathState
  datapathScope        = 'VM_SHARED_MANA_VF'
  tagState             = $tagState
  customizationRisk    = $customizationRisk
  customizationSignals = @($customizationSignals)
}
"MANA_RESULT_JSON=$($result | ConvertTo-Json -Compress -Depth 4)"
