# MANA NIC detection (Windows).
# Run in-guest, or remotely without RDP:
#   az vm run-command invoke -g <rg> -n <vm> --command-id RunPowerShellScript --scripts @detect-mana.ps1 --query "value[0].message" -o tsv
$adapterProbeSucceeded = $false
$adapters = @()
Write-Output "=== Get-NetAdapter ==="
try {
	$adapters = @(Get-NetAdapter -ErrorAction Stop)
	$adapterProbeSucceeded = $true
	$adapters | Format-Table Name, InterfaceDescription, Status, LinkSpeed -AutoSize | Out-String
} catch {
	Write-Output "UNKNOWN: Get-NetAdapter failed: $($_.Exception.Message)"
}
Write-Output "=== MANA PCI device (VEN_1414 & DEV_00BA) ==="
$pnpProbeSucceeded = $false
$pnp = @()
try {
	$pnp = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.InstanceId -match '^PCI\\VEN_1414&DEV_00BA&' })
	$pnpProbeSucceeded = $true
	if ($pnp) { $pnp | Format-Table Status, Class, FriendlyName -AutoSize | Out-String } else { "MANA PCI device not observed" }
} catch {
	Write-Output "UNKNOWN: Get-PnpDevice failed: $($_.Exception.Message)"
}
Write-Output "=== MANA verdict ==="
$manaNic = @($adapters | Where-Object InterfaceDescription -Like "*Microsoft Azure Network Adapter*")
if ($manaNic) { "MANA hardware and adapter present; datapath not proven by this quick check" }
elseif ($pnp) { "MANA hardware present, but no MANA net adapter exposed (OS driver missing)" }
elseif ($pnpProbeSucceeded -and $adapterProbeSucceeded) { "MANA not observed by completed probes; another NIC family is not inferred" }
else { "UNKNOWN: one or more hardware probes did not complete" }
Write-Output "=== MANA adapter statistics ==="
if ($manaNic) { ($manaNic | Get-NetAdapterStatistics | Format-List Name, ReceivedBytes, SentBytes | Out-String) } else { "n/a" }
