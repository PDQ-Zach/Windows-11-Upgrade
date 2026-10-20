<#
  Win11Cleanup.ps1
  Post-upgrade cleanup for machines upgraded with Win11Upgrade.ps1.

  Expectations / assumptions:
  - Run after the upgrade has finished and the machine has rebooted into Windows 11.
  - Script is executed on the target machine and must be run elevated.

  What it cleans by default:
  - The upgrade working folder (setup.zip and the expanded setup files)
  - Leftover Windows setup staging folders ($WINDOWS.~BT, $WINDOWS.~WS, $GetCurrent)

  Opt-in cleanup (off by default because it is not reversible):
  - -RemoveWindowsOld : delete C:\Windows.old (this removes the ability to roll back)
  - -RemoveSetupLogs  : delete the copied setup logs (C:\Temp\Logs\WinSetup)

  The cleanup log in C:\temp\winupgradelogs is never deleted.
#>

param(
	[string]$WorkDir = "C:\\win_11_upgrade\", # Working directory used by Win11Upgrade.ps1
	[string]$SetupLogsDir = "C:\\Temp\\Logs\\WinSetup", # Directory passed to setup.exe /copylogs
	[switch]$RemoveWindowsOld = $false, # If true, also delete Windows.old (no rollback afterwards)
	[switch]$RemoveSetupLogs = $false,  # If true, also delete the copied setup logs
	[switch]$Force = $false,            # If true, clean up even if the OS is not Windows 11
	[switch]$DryRun = $false            # If true, log actions but do not delete anything
)

function Write-Log {
	param(
		[string]$Message,
		[string]$Level = "INFO"
	)
	$timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
	$line = "[$timestamp] [$Level] $Message"
	Write-Output $line
	try {
		Add-Content -Path $Global:LogFile -Value $line -ErrorAction Stop
	} catch {
		Write-Output "Failed to write to log file: $_"
	}
}

function Assert-Elevated {
	if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
		Write-Log "Script is not running elevated. Please run as Administrator." "ERROR"
		throw "Not elevated"
	}
}

function Get-OSBuildNumber {
	try {
		$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
		return [int]$os.BuildNumber
	} catch {
		Write-Log "Unable to determine OS build: $_" "WARN"
		return $null
	}
}

function Get-FreeBytes {
	try {
		return (Get-PSDrive -Name 'C' -ErrorAction Stop).Free
	} catch {
		return $null
	}
}

# Remove a folder, taking ownership first when the normal delete fails (Windows.old and
# the setup staging folders are owned by SYSTEM / TrustedInstaller).
function Remove-Folder {
	param(
		[string]$Path,
		[switch]$TakeOwnership
	)
	if (-not (Test-Path -LiteralPath $Path)) {
		Write-Log "Not present, skipping: $Path"
		return $true
	}
	if ($DryRun) {
		Write-Log "DryRun enabled - would remove: $Path"
		return $true
	}
	Write-Log "Removing $Path"
	try {
		if ($TakeOwnership) {
			& takeown.exe /F $Path /R /D Y 2>&1 | Out-Null
			& icacls.exe $Path /grant "*S-1-5-32-544:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
		}
		Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
		Write-Log "Removed $Path"
		return $true
	} catch {
		Write-Log "Failed to remove ${Path}: $_" "WARN"
		return $false
	}
}

# --- Start script ---
$Global:LogDir = 'C:\\temp\\winupgradelogs'
New-Item -Path $Global:LogDir -ItemType Directory -Force | Out-Null
$Global:LogFile = Join-Path -Path $Global:LogDir -ChildPath "Win11Cleanup_$(Get-Date -Format yyyyMMdd_HHmmss).log"

$failures = 0

try {
	Write-Log "Starting Windows 11 post-upgrade cleanup"

	Assert-Elevated

	# Only clean up once the upgrade has actually landed. Windows 11 is build 22000 or newer.
	# If the upgrade failed, the working folder and staging files are still needed to retry.
	$build = Get-OSBuildNumber
	Write-Log "Detected OS build: $build"
	if (($null -eq $build -or $build -lt 22000) -and -not $Force) {
		Write-Log "This machine is not running Windows 11 yet. Skipping cleanup (use -Force to override)." "ERROR"
		throw "NotWindows11"
	}

	$freeBefore = Get-FreeBytes

	# Upgrade working folder: setup.zip + expanded setup files
	if (-not (Remove-Folder -Path $WorkDir)) { $failures++ }

	# Setup staging folders left on the system drive
	foreach ($dir in @('C:\$WINDOWS.~BT', 'C:\$WINDOWS.~WS', 'C:\$GetCurrent')) {
		if (-not (Remove-Folder -Path $dir -TakeOwnership)) { $failures++ }
	}

	# Copied setup logs (opt-in, they are useful for troubleshooting)
	if ($RemoveSetupLogs) {
		if (-not (Remove-Folder -Path $SetupLogsDir)) { $failures++ }
	} else {
		Write-Log "Keeping setup logs in $SetupLogsDir (use -RemoveSetupLogs to delete)"
	}

	# Windows.old (opt-in). Windows removes it automatically after about 10 days, and deleting
	# it early removes the ability to roll back to the previous version of Windows.
	if ($RemoveWindowsOld) {
		Write-Log "Removing Windows.old - rollback to the previous Windows version will no longer be possible" "WARN"
		if (-not (Remove-Folder -Path 'C:\Windows.old' -TakeOwnership)) { $failures++ }
	} elseif (Test-Path -LiteralPath 'C:\Windows.old') {
		Write-Log "Keeping C:\Windows.old for rollback (use -RemoveWindowsOld to delete)"
	}

	$freeAfter = Get-FreeBytes
	if (-not $DryRun -and $null -ne $freeBefore -and $null -ne $freeAfter) {
		Write-Log ("Reclaimed approximately {0:N2} GB on C:" -f (($freeAfter - $freeBefore) / 1GB))
	}

	if ($DryRun) {
		Write-Log "Finished (dry run)."
		exit 0
	}

	if ($failures -gt 0) {
		Write-Log "Cleanup finished with $failures item(s) that could not be removed." "WARN"
		exit 2
	}
	Write-Log "Cleanup completed successfully."
	exit 0

} catch {
	Write-Log "Unhandled error: $_" "ERROR"
	exit 1
} finally {
	Write-Log "Script finished at $(Get-Date -Format o)"
}
