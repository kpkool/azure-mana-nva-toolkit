$cliArguments = @($args | ForEach-Object { [string]$_ })
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures'
$stateRoot = $env:MANA_FAKE_STATE_DIR
if (-not $stateRoot) {
  [Console]::Error.WriteLine('(TestConfigurationError) MANA_FAKE_STATE_DIR is required.')
  exit 1
}
if (-not (Test-Path -LiteralPath $stateRoot)) { New-Item -ItemType Directory -Path $stateRoot | Out-Null }

function Get-ArgumentValue([string]$Name) {
  $index = [array]::IndexOf($cliArguments, $Name)
  if ($index -lt 0 -or $index + 1 -ge $cliArguments.Count) { return $null }
  return $cliArguments[$index + 1]
}

function Add-Call([string]$Value) {
  Add-Content -LiteralPath (Join-Path $stateRoot 'calls.log') -Value $Value -Encoding UTF8
}

function Update-TestCounter([string]$Name) {
  $path = Join-Path $stateRoot "$Name.count"
  $count = if (Test-Path -LiteralPath $path) { [int](Get-Content -LiteralPath $path -Raw) } else { 0 }
  $count++
  Set-Content -LiteralPath $path -Value $count -Encoding ASCII
  return $count
}

if ($cliArguments.Count -ge 2 -and $cliArguments[0] -eq 'graph' -and $cliArguments[1] -eq 'query') {
  Add-Call 'graph-query'
  $graphAttempt = Update-TestCounter 'graph'
  if ($env:MANA_FAKE_FAIL_GRAPH_ONCE -eq '1' -and $graphAttempt -eq 1) {
    [Console]::Error.WriteLine('(TooManyRequests) Injected transient ARG failure.')
    exit 1
  }
  $skipToken = Get-ArgumentValue '--skip-token'
  $fixture = if (-not $skipToken) {
    'arg-page-1.json'
  } elseif ($skipToken -eq 'fixture-page-2') {
    'arg-page-2.json'
  } elseif ($skipToken -eq 'fixture-page-3') {
    'arg-page-3.json'
  } else {
    [Console]::Error.WriteLine('(InvalidSkipToken) Unexpected fixture skip token.')
    exit 1
  }
  $fixtureText = [IO.File]::ReadAllText((Join-Path $fixtureRoot $fixture))
  if ($env:MANA_FAKE_INVENTORY_CHANGED -eq '1' -and $fixture -eq 'arg-page-1.json') {
    $payload = $fixtureText | ConvertFrom-Json
    $payload.data[0].VMSize = 'Standard_D8s_v5'
    $fixtureText = $payload | ConvertTo-Json -Depth 20
  }
  [Console]::Out.Write($fixtureText)
  exit 0
}

if ($cliArguments.Count -ge 2 -and $cliArguments[0] -eq 'vm' -and $cliArguments[1] -eq 'get-instance-view') {
  $vmName = Get-ArgumentValue '--name'
  Add-Call "power:$vmName"
  if ($vmName -eq 'vm-windows' -and $env:MANA_FAKE_WINDOWS_RUNNING -ne '1') {
    [Console]::Out.Write('"PowerState/deallocated"')
  } else {
    [Console]::Out.Write('"PowerState/running"')
  }
  exit 0
}

if ($cliArguments.Count -ge 3 -and $cliArguments[0] -eq 'vm' -and $cliArguments[1] -eq 'run-command') {
  $vmName = Get-ArgumentValue '--name'
  Add-Call "run:$vmName"
  if ($vmName -eq 'vm-general') {
    $runAttempt = Update-TestCounter 'run-vm-general'
    if ($env:MANA_FAKE_FAIL_RUN_ONCE -eq '1' -and $runAttempt -eq 1) {
      [Console]::Error.WriteLine('(GatewayTimeout) Injected transient Run Command failure.')
      exit 1
    }
  }
  $fixture = if ($vmName -eq 'vm-windows') { 'run-command-windows-pass.json' } else { 'run-command-linux-pass.json' }
  [Console]::Out.Write([IO.File]::ReadAllText((Join-Path $fixtureRoot $fixture)))
  exit 0
}

[Console]::Error.WriteLine('(UnsupportedFakeCommand) Unexpected fake Azure CLI arguments.')
exit 1
