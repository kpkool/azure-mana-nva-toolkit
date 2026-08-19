<#
  validate-nva-mana.ps1 — per-VM MANA readiness validator (Windows)
  Checks, at the VM level: (1) LegacyVMNVA tag, (2) MANA hardware present,
  (3) MANA driver installed, (4) adapter functioning, plus link sanity.
  Run without RDP via:
    az vm run-command invoke -g <rg> -n <vm> --command-id RunPowerShellScript `
      --scripts "@scripts/validate-nva-mana.ps1" --query "value[0].message" -o tsv
#>
$ErrorActionPreference = 'SilentlyContinue'
function Row($tag,$msg){ "[{0,-4}] {1}" -f $tag,$msg }
function Line(){ '-' * 60 }

$imds = 'http://169.254.169.254/metadata/instance'
$hdr  = @{ Metadata = 'true' }

"############ MANA NVA VALIDATOR (Windows) ############"
"host: $env:COMPUTERNAME   date: $((Get-Date).ToUniversalTime().ToString('s'))Z"
Line

# ---- 0. Identity + size (IMDS) ----
$compute = Invoke-RestMethod -Headers $hdr -Uri "$imds/compute?api-version=2021-02-01"
"== Identity =="
Row 'INFO' "VM name (IMDS): $($compute.name)"
Row 'INFO' "VM size (IMDS): $($compute.vmSize)"
Line

# ---- 1. Tag check (LegacyVMNVA) ----
"== 1. LegacyVMNVA tag =="
$tag = $compute.tagsList | Where-Object { $_.name -ieq 'LegacyVMNVA' }
if ($null -eq $tag -and $compute.tags) {
  # older format: "name:value;name:value"
  $pair = ($compute.tags -split ';') | Where-Object { $_ -match '^(?i)LegacyVMNVA:' }
  if ($pair) { $tag = [pscustomobject]@{ name='LegacyVMNVA'; value=($pair -split ':')[1] } }
}
"raw tags: $($compute.tags)"
if ($tag) { Row 'PASS' "LegacyVMNVA tag present (value: $($tag.value))" }
else      { Row 'WARN' "LegacyVMNVA tag NOT present (exception not applied to this VM)" }
Line

# ---- 2. MANA hardware present (PCI VEN_1414 DEV_00BA) ----
"== 2. MANA hardware (PCI VEN_1414&DEV_00BA) =="
$pnp = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '^PCI\\VEN_1414&DEV_00BA&' }
$onManaHw = [bool]$pnp
if ($pnp) { $pnp | Select-Object Status,Class,FriendlyName | Format-Table -Auto | Out-String | Write-Output
            Row 'PASS' 'MANA NIC PCI device present (Microsoft Azure Network Adapter Virtual Bus)' }
else      { Row 'INFO' 'No MANA PCI device -> VM is on Mellanox/ConnectX hardware (not MANA)' }
Line

# ---- 3. MANA driver installed (adapter exposed) ----
"== 3. MANA driver (adapter) =="
$mana = Get-NetAdapter | Where-Object InterfaceDescription -Like '*Microsoft Azure Network Adapter*'
Get-NetAdapter | Select-Object Name,InterfaceDescription,Status,LinkSpeed | Format-Table -Auto | Out-String | Write-Output
if ($mana) { Row 'PASS' "MANA adapter present and driver loaded: $($mana.InterfaceDescription)" }
elseif ($onManaHw) { Row 'FAIL' 'On MANA hardware but MANA adapter NOT exposed -> driver missing -> NetVSC fallback. Install driver: https://aka.ms/manawindowsdrivers' }
else { Row 'INFO' 'No MANA adapter (expected when not on MANA hardware)' }
# Accelerated Networking present = a VF adapter other than the synthetic Hyper-V NIC (Mellanox VF or MANA)
$accel = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Hyper-V Network Adapter' }
$anEnabled = [bool]$accel
if     ($anEnabled -and -not $mana) { Row 'INFO' "Accelerated Networking active on non-MANA VF: $(@($accel)[0].InterfaceDescription)" }
elseif (-not $anEnabled)            { Row 'INFO' 'Accelerated Networking not detected (no VF adapter) -> no MANA action' }
Line

# ---- 4. Adapter functioning (statistics) ----
"== 4. Adapter functioning (statistics) =="
if ($mana) {
  $s1 = ($mana | Get-NetAdapterStatistics).ReceivedBytes
  Start-Sleep -Seconds 2
  $s2 = ($mana | Get-NetAdapterStatistics).ReceivedBytes
  "ReceivedBytes: $s1 -> $s2"
  if ($s2 -ge $s1 -and $s2 -gt 0) { Row 'PASS' 'MANA adapter counters non-zero (datapath in use)' }
  else { Row 'WARN' 'MANA adapter counters flat/zero (little traffic)' }
} else { Row 'INFO' 'No MANA adapter to measure' }
Line

# ---- 5. Link sanity (extra tests) ----
"== 5. Link sanity =="
Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object Name,LinkSpeed,MtuSize,MacAddress | Format-Table -Auto | Out-String | Write-Output
Line

# ---- SUMMARY VERDICT ----
"== SUMMARY =="
"(Reports hardware/driver/AN facts only. NVA-vs-general-workload classification comes from your vendor/CMDB; the LegacyVMNVA tag is only for AN-based NVAs, not general VMs.)"
if     ($onManaHw -and $mana)      { 'VERDICT: ON MANA, driver working. No action for general workloads. If this is an NVA, validate appliance behavior and consider migrating to a MANA-optimized series.' }
elseif ($onManaHw -and -not $mana) { 'VERDICT: ON MANA hardware but driver MISSING -> NetVSC fallback. Install MANA driver (aka.ms/manawindowsdrivers); if this is an NVA that degrades, keep LegacyVMNVA.' }
elseif (-not $anEnabled)           { 'VERDICT: Accelerated Networking DISABLED -> no MANA action required.' }
else                               { 'VERDICT: NOT on MANA (on Mellanox/ConnectX). No action for general workloads. Apply LegacyVMNVA ONLY if this is an Accelerated-Networking NVA (firewall/router/SD-WAN) not yet confirmed MANA-compatible, before the earliest placement date.' }
"####################################################"
