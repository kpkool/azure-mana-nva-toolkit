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

$imds = 'http://169.254.169.254/metadata/instance'
$hdr  = @{ Metadata = 'true' }

# Tri-state check results: 'yes' | 'no' | 'unknown'. Any 'unknown' forces an UNKNOWN verdict.
$tagState = 'unknown'; $hwState = 'unknown'; $drvState = 'unknown'; $anState = 'unknown'
$checkErrors = @()

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
  "raw tags: $($compute.tags)"
  if ($tag) { $tagState = 'yes'; Row 'PASS' "LegacyVMNVA tag present (value: $($tag.value))" }
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
  else      { $hwState = 'no';  Row 'INFO' 'No MANA PCI device -> VM is on Mellanox/ConnectX hardware (not MANA)' }
} catch {
  Row 'ERR ' "Get-PnpDevice FAILED ($($_.Exception.Message)) -> MANA hardware state UNKNOWN"
  $checkErrors += 'Get-PnpDevice (hardware)'
}
Line

# ---- 3. MANA driver installed (adapter exposed) ----
"== 3. MANA driver (adapter) =="
$adapters = $null; $mana = $null; $anEnabled = $null    # $null = unknown
try {
  $adapters = Get-NetAdapter                     # cache once; reused in sections 3-5
  $mana = $adapters | Where-Object InterfaceDescription -Like '*Microsoft Azure Network Adapter*'
  $adapters | Select-Object Name,InterfaceDescription,Status,LinkSpeed | Format-Table -Auto | Out-String | Write-Output
  if ($mana) { $drvState = 'yes'; Row 'PASS' "MANA adapter present and driver loaded: $((@($mana)[0]).InterfaceDescription)" }
  elseif ($onManaHw -eq $true) { $drvState = 'no'; Row 'FAIL' 'On MANA hardware but MANA adapter NOT exposed -> driver missing -> NetVSC fallback. Install driver: https://aka.ms/manawindowsdrivers' }
  else { $drvState = 'no'; Row 'INFO' 'No MANA adapter (expected when not on MANA hardware)' }
  # Accelerated Networking present = an SR-IOV VF from a known family (Mellanox ConnectX or MANA); report EVERY such NIC (multi-NIC NVAs)
  $vfPattern = 'Mellanox|Microsoft Azure Network Adapter'
  $accel = @($adapters | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match $vfPattern })
  $anEnabled = [bool]$accel.Count
  if ($anEnabled) {
    $anState = 'yes'
    foreach ($a in $accel) { Row 'INFO' "Accelerated VF NIC: $($a.Name) - $($a.InterfaceDescription)" }
  } else { $anState = 'no'; Row 'INFO' 'Accelerated Networking not detected (no VF adapter) -> no MANA action' }
} catch {
  Row 'ERR ' "Get-NetAdapter FAILED ($($_.Exception.Message)) -> driver/AN state UNKNOWN"
  $checkErrors += 'Get-NetAdapter (driver/AN)'
}
Line

# ---- 4. Adapter functioning (statistics) ----
"== 4. Adapter functioning (statistics) =="
if ($mana) {
  try {
    $s1 = ((@($mana)[0]) | Get-NetAdapterStatistics).ReceivedBytes
    Start-Sleep -Seconds 2
    $s2 = ((@($mana)[0]) | Get-NetAdapterStatistics).ReceivedBytes
    "ReceivedBytes: $s1 -> $s2"
    if ($s2 -ge $s1 -and $s2 -gt 0) { Row 'PASS' 'MANA adapter counters non-zero (datapath in use)' }
    else { Row 'WARN' 'MANA adapter counters flat/zero (little traffic)' }
  } catch { Row 'ERR ' "Get-NetAdapterStatistics FAILED ($($_.Exception.Message))" }
} else { Row 'INFO' 'No MANA adapter to measure' }
Line

# ---- 5. Link sanity (extra tests) ----
"== 5. Link sanity =="
if ($adapters) { $adapters | Where-Object Status -eq 'Up' | Select-Object Name,LinkSpeed,MtuSize,MacAddress | Format-Table -Auto | Out-String | Write-Output }
else { Row 'INFO' 'Adapter list unavailable (Get-NetAdapter failed above)' }
Line

# ---- SUMMARY VERDICT ----
"== SUMMARY =="
"(Reports hardware/driver/AN facts only. NVA-vs-general-workload classification comes from your vendor/CMDB; the LegacyVMNVA tag is only for AN-based NVAs, not general VMs.)"
if ($checkErrors.Count -gt 0 -or $hwState -eq 'unknown' -or $drvState -eq 'unknown') {
  "VERDICT: UNKNOWN - one or more checks failed, so MANA state could NOT be determined (do NOT treat as 'no action'). Failed: $([string]::Join('; ', $checkErrors)). Re-run; if it persists, verify IMDS reachability and run elevated."
}
elseif ($onManaHw -eq $true -and $mana)      { 'VERDICT: ON MANA, driver working. No action for general workloads. If this is an NVA, validate appliance behavior and consider migrating to a MANA-optimized series.' }
elseif ($onManaHw -eq $true -and -not $mana) { 'VERDICT: ON MANA hardware but driver MISSING -> NetVSC fallback. Install MANA driver (aka.ms/manawindowsdrivers); if this is an NVA that degrades, keep LegacyVMNVA.' }
elseif ($anState -eq 'no')                   { 'VERDICT: Accelerated Networking DISABLED -> no MANA action required.' }
else                                         { 'VERDICT: NOT on MANA (on Mellanox/ConnectX). No action for general workloads. Apply LegacyVMNVA ONLY if this is an Accelerated-Networking NVA (firewall/router/SD-WAN) not yet confirmed MANA-compatible, before the earliest placement date.' }
if ($tagState -eq 'unknown') { Row 'ERR ' 'Tag state UNKNOWN (IMDS failed) - re-check the tag before relying on it' }
"####################################################"
