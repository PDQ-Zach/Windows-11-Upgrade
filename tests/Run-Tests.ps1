<#
  Run-Tests.ps1
  Smoke tests for Win11Upgrade.ps1 and Win11Cleanup.ps1. Runs on a Windows machine
  (the GitHub Actions workflow runs it on windows-latest) and never runs a real upgrade.

  Usage (from the repository root, elevated):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
#>

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$upgradeScript = Join-Path $repoRoot 'Win11Upgrade.ps1'
$cleanupScript = Join-Path $repoRoot 'Win11Cleanup.ps1'
$hostExe = (Get-Process -Id $PID).Path
$script:failures = 0

function Assert-True {
	param([bool]$Condition, [string]$Name, [string]$Detail = '')
	if ($Condition) {
		Write-Host "PASS  $Name"
	} else {
		Write-Host "FAIL  $Name"
		if ($Detail) { Write-Host ($Detail -split "`n" | ForEach-Object { "      $_" } | Out-String) }
		$script:failures++
	}
}

# Run a script in a child PowerShell and return its exit code and combined output.
function Invoke-Script {
	param([string]$Path, [string[]]$Arguments)
	$output = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String
	return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

# Build a ZIP from a folder. -IncludeBase keeps the folder itself inside the ZIP (the mistake the
# upgrade script is meant to catch).
function New-TestZip {
	param([string]$SourceDir, [string]$ZipPath, [switch]$IncludeBase)
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
	[System.IO.Compression.ZipFile]::CreateFromDirectory($SourceDir, $ZipPath, [System.IO.Compression.CompressionLevel]::Fastest, [bool]$IncludeBase)
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "win11tests_$(Get-Date -Format yyyyMMddHHmmss)"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
	Write-Host "Host: $hostExe (PowerShell $($PSVersionTable.PSVersion))"
	$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
	Write-Host "OS build: $build"

	# --- 1. Syntax ---
	foreach ($file in @($upgradeScript, $cleanupScript)) {
		$errors = $null
		[void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
		Assert-True (-not $errors) "Parses cleanly: $(Split-Path $file -Leaf)" ($errors | Out-String)
	}

	# --- 2. Cleanup path guard (function pulled out of the script, nothing is deleted) ---
	$ast = [System.Management.Automation.Language.Parser]::ParseFile($cleanupScript, [ref]$null, [ref]$null)
	$guard = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-SafeToRemove' }, $true)[0]
	. ([scriptblock]::Create($guard.Extent.Text))
	$sd = $env:SystemDrive
	foreach ($p in @("$sd\", $env:SystemRoot, "$env:SystemRoot\Temp", $env:ProgramFiles, "$env:ProgramFiles\Anything", "$sd\Users", "$sd\Temp", $env:ProgramData)) {
		Assert-True (-not (Test-SafeToRemove -Path $p)) "Guard refuses: $p"
	}
	foreach ($p in @("$sd\win_11_upgrade", "$sd\win_11_upgrade\", "$sd\Temp\Logs\WinSetup", "$sd\`$WINDOWS.~BT", "$sd\`$GetCurrent")) {
		Assert-True (Test-SafeToRemove -Path $p) "Guard allows: $p"
	}

	# --- 3. Upgrade script (-DryRun only; setup.exe is never launched) ---
	$goodSrc = Join-Path $tempRoot 'good_src'
	New-Item -ItemType Directory -Path $goodSrc -Force | Out-Null
	Set-Content -Path (Join-Path $goodSrc 'setup.exe') -Value 'not a real setup'
	Set-Content -Path (Join-Path $goodSrc 'sources.txt') -Value 'placeholder'
	$goodWork = Join-Path $tempRoot 'work_good'
	New-Item -ItemType Directory -Path $goodWork -Force | Out-Null
	New-TestZip -SourceDir $goodSrc -ZipPath (Join-Path $goodWork 'setup.zip')

	$nestedWork = Join-Path $tempRoot 'work_nested'
	New-Item -ItemType Directory -Path $nestedWork -Force | Out-Null
	New-TestZip -SourceDir $goodSrc -ZipPath (Join-Path $nestedWork 'setup.zip') -IncludeBase

	$corruptWork = Join-Path $tempRoot 'work_corrupt'
	New-Item -ItemType Directory -Path $corruptWork -Force | Out-Null
	Set-Content -Path (Join-Path $corruptWork 'setup.zip') -Value 'this is not a zip'

	$emptyWork = Join-Path $tempRoot 'work_empty'
	New-Item -ItemType Directory -Path $emptyWork -Force | Out-Null

	# Valid ZIP: dry run passes and does not expand anything
	$r = Invoke-Script $upgradeScript @('-WorkDir', $goodWork, '-DryRun', '-SkipHardwareChecks', '-Force')
	Assert-True ($r.ExitCode -eq 0) 'Upgrade -DryRun with a valid ZIP exits 0' $r.Output
	Assert-True ($r.Output -match 'DryRun enabled - would run') 'Upgrade -DryRun logs the setup.exe command' $r.Output
	Assert-True (-not (Test-Path (Join-Path $goodWork 'setup.exe'))) 'Upgrade -DryRun does not expand the ZIP'

	# ZIP made from the folder instead of its contents
	$r = Invoke-Script $upgradeScript @('-WorkDir', $nestedWork, '-DryRun', '-SkipHardwareChecks', '-Force')
	Assert-True ($r.ExitCode -eq 1) 'Upgrade rejects a ZIP with setup.exe nested in a folder' $r.Output
	Assert-True ($r.Output -match 'not at the top level') 'Upgrade explains the nested ZIP problem' $r.Output

	# Corrupt ZIP
	$r = Invoke-Script $upgradeScript @('-WorkDir', $corruptWork, '-DryRun', '-SkipHardwareChecks', '-Force')
	Assert-True ($r.ExitCode -eq 1) 'Upgrade rejects a corrupt ZIP' $r.Output
	Assert-True ($r.Output -match 'Unable to read') 'Upgrade reports the corrupt ZIP' $r.Output

	# Missing ZIP
	$r = Invoke-Script $upgradeScript @('-WorkDir', $emptyWork, '-DryRun', '-SkipHardwareChecks', '-Force')
	Assert-True ($r.ExitCode -eq 1) 'Upgrade fails when setup.zip is missing' $r.Output
	Assert-True ($r.Output -match 'Expected zip file not found') 'Upgrade reports the missing ZIP' $r.Output

	# Hardware checks. CI runners are virtual machines without a TPM, so the checks should block.
	# The ZIP is missing on purpose: if the checks unexpectedly pass, the run still stops safely.
	$r = Invoke-Script $upgradeScript @('-WorkDir', $emptyWork, '-Force')
	Assert-True ($r.ExitCode -eq 1) 'Upgrade stops (hardware check or missing ZIP) without -SkipHardwareChecks' $r.Output
	if ($r.Output -match 'HardwareRequirementsNotMet|Device does not meet') {
		Write-Host 'INFO  Hardware checks blocked this machine, as expected on a VM without a TPM'
	} else {
		Write-Host 'INFO  Hardware checks passed on this machine; it stopped on the missing ZIP instead'
	}
	$r = Invoke-Script $upgradeScript @('-WorkDir', $goodWork, '-DryRun', '-Force')
	Assert-True ($r.ExitCode -eq 0) 'Upgrade -DryRun reports hardware problems without failing' $r.Output

	# Already on Windows 11 (build 22000+): exits 0 without doing anything
	if ($build -ge 22000) {
		$r = Invoke-Script $upgradeScript @('-WorkDir', $emptyWork)
		Assert-True ($r.ExitCode -eq 0 -and $r.Output -match 'already on Windows 11') 'Upgrade exits 0 on a device already on Windows 11' $r.Output
	} else {
		Write-Host "SKIP  Already-on-Windows-11 test (this machine is build $build)"
	}

	# --- 4. Cleanup script ---
	$cleanWork = Join-Path $tempRoot 'cleanup_work'
	$cleanLogs = Join-Path $tempRoot 'cleanup_logs'
	New-Item -ItemType Directory -Path $cleanWork, $cleanLogs -Force | Out-Null
	Set-Content -Path (Join-Path $cleanWork 'setup.zip') -Value 'x'
	Set-Content -Path (Join-Path $cleanLogs 'setup.log') -Value 'x'

	$r = Invoke-Script $cleanupScript @('-WorkDir', $cleanWork, '-SetupLogsDir', $cleanLogs, '-Force', '-DryRun')
	Assert-True ($r.ExitCode -eq 0) 'Cleanup -DryRun exits 0' $r.Output
	Assert-True (Test-Path $cleanWork) 'Cleanup -DryRun deletes nothing'

	$r = Invoke-Script $cleanupScript @('-WorkDir', $cleanWork, '-SetupLogsDir', $cleanLogs, '-Force')
	Assert-True ($r.ExitCode -eq 0) 'Cleanup exits 0' $r.Output
	Assert-True (-not (Test-Path $cleanWork)) 'Cleanup removes the working folder'
	Assert-True (Test-Path $cleanLogs) 'Cleanup keeps setup logs by default'

	New-Item -ItemType Directory -Path $cleanWork -Force | Out-Null
	$r = Invoke-Script $cleanupScript @('-WorkDir', $cleanWork, '-SetupLogsDir', $cleanLogs, '-RemoveSetupLogs', '-Force')
	Assert-True (-not (Test-Path $cleanLogs)) 'Cleanup -RemoveSetupLogs removes the setup logs' $r.Output

	# Protected path: refused even in a dry run, and reported as a failure
	$r = Invoke-Script $cleanupScript @('-WorkDir', "$sd\", '-SetupLogsDir', $cleanLogs, '-Force', '-DryRun')
	Assert-True ($r.ExitCode -eq 2) 'Cleanup exits 2 when asked to remove a drive root' $r.Output
	Assert-True ($r.Output -match 'Refusing to remove protected path') 'Cleanup logs the refusal' $r.Output

	# Not on Windows 11 yet: refuses to run without -Force
	if ($build -lt 22000) {
		$r = Invoke-Script $cleanupScript @('-WorkDir', $cleanWork, '-DryRun')
		Assert-True ($r.ExitCode -eq 1) 'Cleanup refuses to run before the upgrade has completed' $r.Output
	} else {
		Write-Host "SKIP  Not-yet-Windows-11 test (this machine is build $build)"
	}
}
finally {
	Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) {
	Write-Host "`n$($script:failures) test(s) failed."
	exit 1
}
Write-Host "`nAll tests passed."
exit 0
