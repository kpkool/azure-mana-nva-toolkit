# MANA NIC detection (Windows).
# Run in-guest, or remotely without RDP:
#   az vm run-command invoke -g <rg> -n <vm> --command-id RunPowerShellScript --scripts @detect-mana.ps1 --query "value[0].message" -o tsv
Write-Output "=== Get-NetAdapter ==="
Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, LinkSpeed -AutoSize | Out-String
Write-Output "=== MANA PCI device (VEN_1414 & DEV_00BA) ==="
$pnp = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '^PCI\\VEN_1414&DEV_00BA&' }
if ($pnp) { ($pnp | Format-Table Status, Class, FriendlyName -AutoSize | Out-String) } else { "No MANA PCI device present" }
Write-Output "=== MANA verdict ==="
$manaNic = Get-NetAdapter | Where-Object InterfaceDescription -Like "*Microsoft Azure Network Adapter*"
if ($manaNic) { "ON MANA: Microsoft Azure Network Adapter present" }
elseif ($pnp) { "MANA hardware present, but no MANA net adapter exposed (OS driver missing)" }
else { "NOT on MANA (no Microsoft Azure Network Adapter / 00ba)" }
Write-Output "=== MANA adapter statistics ==="
if ($manaNic) { ($manaNic | Get-NetAdapterStatistics | Format-List Name, ReceivedBytes, SentBytes | Out-String) } else { "n/a" }
