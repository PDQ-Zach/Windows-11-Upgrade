<#
  Win11Upgrade.ps1
  Improved script to expand a prepared Windows 11 setup ZIP and run setup.exe with
  robust logging, validation and error handling.

  Expectations / assumptions:
  - The ZIP containing the Windows 11 setup files (named "setup.zip") has already
	been copied to the working folder (no copy steps in this script).
  - Script is executed on the target machine (not a remote copy step).
  - This script should be run elevated (it will check and fail early if not).

  Changes added:
  - Timestamped log file under %ProgramData%\Win11UpgradeLogs\
  - Verbose console output and log file writes
  - Input validations (elevation, existence of ZIP, free disk space)
  - Try/Catch and exit codes for common failure modes
  - Comments that explain the upgrade steps and common flags
#>

param(
	[string]$ZipName = "setup.zip",    # Name of the ZIP file expected in the working dir
	[string]$WorkDir = "C:\\win_11_upgrade\", # Working directory containing the ZIP
	[switch]$DryRun = $false,           # If true, log actions but do not run setup
	[switch]$SkipHardwareChecks = $false # If true, log TPM / Secure Boot problems but do not block the upgrade
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
		# If LogFile is not set, create a fallback in the user's TEMP directory so we can always log
		if (-not $Global:LogFile) {
			try {
				if (-not $Global:LogDir) { $Global:LogDir = 'C:\\temp\\winupgradelogs' }
				New-Item -Path $Global:LogDir -ItemType Directory -Force | Out-Null
				$Global:LogFile = Join-Path -Path $Global:LogDir -ChildPath "Win11Upgrade_fallback_$(Get-Date -Format yyyyMMdd_HHmmss).log"
			} catch {
				Write-Output "Failed to create fallback log path: $_"
				return
			}
		}
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

function Test-FreeSpace {
	param(
		[string]$Path,
		[int64]$RequiredBytes
	)
	try {
		$drive = Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($Path).TrimEnd('\')) -ErrorAction Stop
		return $drive.Free -ge $RequiredBytes
	} catch {
		Write-Log ("Unable to determine free disk space on {0}: {1}" -f $Path, $_) "WARN"
		return $false
	}
}

function Get-OSVersionInfo {
	try {
		$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
		return @{ Version = $os.Version; Caption = $os.Caption; BuildNumber = [int]$os.BuildNumber }
	} catch {
		Write-Log "Unable to determine OS version: $_" "WARN"
		return $null
	}
}

function Test-TPM {
	try {
		if (Get-Command -Name Get-Tpm -ErrorAction SilentlyContinue) {
			$tpm = Get-Tpm
			return @{ Present = $tpm.TpmPresent; Ready = $tpm.TpmReady; SpecVersion = $tpm.SpecVersion }
		} else {
			# Fallback to WMI namespace (older systems may not have Get-Tpm)
			$wmi = Get-WmiObject -Namespace 'Root\\CIMv2\\Security\\MicrosoftTpm' -Class Win32_Tpm -ErrorAction Stop
			return @{ Present = $true; Ready = $wmi.IsActivated_InitialValue -eq $true; SpecVersion = $wmi.SpecVersion }
		}
	} catch {
		Write-Log "TPM check failed or TPM not present: $_" "WARN"
		return @{ Present = $false; Ready = $false; SpecVersion = $null }
	}
}

function Test-SecureBoot {
	try {
		if (Get-Command -Name Confirm-SecureBootUEFI -ErrorAction SilentlyContinue) {
			$sb = Confirm-SecureBootUEFI
			return $sb
		} else {
			Write-Log "Confirm-SecureBootUEFI not available on this system; unable to verify Secure Boot." "WARN"
			return $false
		}
	} catch {
		Write-Log "Secure Boot check failed: $_" "WARN"
		return $false
	}
}

# Log OS / TPM / Secure Boot state and return a list of blocking problems (empty list = OK).
# TPM must be present, ready and version 2.0; Secure Boot must be enabled.
function Test-HardwareRequirements {
	$problems = @()

	$osInfo = Get-OSVersionInfo
	if ($osInfo) { Write-Log "OS: $($osInfo.Caption) Version $($osInfo.Version) Build $($osInfo.BuildNumber)" }

	$tpmInfo = Test-TPM
	Write-Log "TPM present: $($tpmInfo.Present); Ready: $($tpmInfo.Ready); SpecVersion: $($tpmInfo.SpecVersion)"
	if (-not $tpmInfo.Present) {
		$problems += "TPM not present"
	} elseif (-not $tpmInfo.Ready) {
		$problems += "TPM present but not ready"
	}
	if ($tpmInfo.Present -and ($tpmInfo.SpecVersion -notmatch '^\s*2\.0')) {
		$problems += "TPM 2.0 required (found spec version '$($tpmInfo.SpecVersion)')"
	}

	$secureBoot = Test-SecureBoot
	Write-Log "Secure Boot detected: $secureBoot"
	if (-not $secureBoot) {
		$problems += "Secure Boot is not enabled or could not be verified"
	}

	return $problems
}

# --- Start script ---
New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
# Use the requested fixed log directory so logs are always placed at the same location
$Global:LogDir = 'C:\\temp\\winupgradelogs'
New-Item -Path $Global:LogDir -ItemType Directory -Force | Out-Null
$Global:LogFile = Join-Path -Path $Global:LogDir -ChildPath "Win11Upgrade_$(Get-Date -Format yyyyMMdd_HHmmss).log"

try {
	Write-Log "Starting Windows 11 upgrade script"

	Assert-Elevated

	# Validate working directory and ZIP
	Write-Log "Using working directory: $WorkDir"
	if (-not (Test-Path -Path $WorkDir)) {
		Write-Log "Working directory $WorkDir does not exist. Creating..."
		New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
	}

	$zipPath = Join-Path -Path $WorkDir -ChildPath $ZipName
	if (-not (Test-Path -Path $zipPath)) {
		Write-Log "Expected zip file not found: $zipPath" "ERROR"
		throw "ZipMissing"
	}

	# Basic free space check: require at least 20 GB free on the drive hosting WorkDir (tunable)
	$requiredBytes = 20GB
	if (-not (Test-FreeSpace -Path $WorkDir -RequiredBytes $requiredBytes)) {
		Write-Log "Insufficient free space for upgrade. Require at least 20 GB free on $WorkDir" "ERROR"
		throw "InsufficientDiskSpace"
	}

	# Expand the archive - idempotent if destination already has files
	Write-Log "Expanding archive $zipPath to $WorkDir"
	try {
		Expand-Archive -Path $zipPath -DestinationPath $WorkDir -Force -ErrorAction Stop
		Write-Log "Archive expanded successfully"
	} catch {
		Write-Log "Failed to expand archive: $_" "ERROR"
		throw
	}

	# Locate setup.exe - it should be in the working directory after expanding the ZIP
	$setupExe = Join-Path -Path $WorkDir -ChildPath "setup.exe"
	if (-not (Test-Path -Path $setupExe)) {
		Write-Log "setup.exe not found in $WorkDir after expanding archive" "ERROR"
		throw "SetupMissing"
	}

	# Explain the flags used when launching setup.exe
	Write-Log "Preparing to run setup.exe with silent upgrade flags"
	Write-Log "Flags reference: /auto Upgrade (perform upgrade), /migratedrivers all (keep drivers),/EULA accept, /ShowOOBE none (suppress OOBE), /dynamicupdate disable (skip online updates during setup), /quiet (silent), /compat ignorewarning (continue despite compatibility warnings), /copylogs <path> (copy setup logs)"

	# Notes about the upgrade process:
	# - The setup.exe program performs several steps: pre-upgrade checks, driver compatibility checks,
	#   copying / staging files, applying feature updates, rebooting into Windows PE for offline phases,
	#   and finalizing the upgrade in the target OS. Many of these steps are internal to setup and
	#   produce rich logs under the %windir%\Panther and the location passed to /copylogs.
	# - /dynamicupdate disable disables additional online downloads during setup which can speed
	#   the process and make behavior more deterministic. Remove if you prefer the latest updates
	#   to be pulled during setup.
	# - /compat ignorewarning is useful for bulk upgrades where small compatibility checks would
	#   otherwise halt the process. Use with caution: ignoring compatibility warnings may cause
	#   post-upgrade issues.
	# - Ensure your environment's driver management and applications are compatible before wide
	#   deployment. Consider running the Windows Upgrade Health checks or the Microsoft PC Health
	#   Checkup tool prior to upgrade.

	$copyLogsPath = "C:\\Temp\\Logs\\WinSetup"
	New-Item -Path $copyLogsPath -ItemType Directory -Force | Out-Null

	$arguments = "/auto Upgrade /migratedrivers all /EULA accept /ShowOOBE none /dynamicupdate disable /quiet /compat ignorewarning /copylogs `"$copyLogsPath`""

	# Run pre-upgrade hardware checks: OS build, TPM, Secure Boot
	$hardwareProblems = @(Test-HardwareRequirements)
	if ($hardwareProblems.Count -gt 0) {
		foreach ($problem in $hardwareProblems) { Write-Log "Hardware check failed: $problem" "ERROR" }
		if ($SkipHardwareChecks) {
			Write-Log "-SkipHardwareChecks set - continuing despite failed hardware checks." "WARN"
		} elseif ($DryRun) {
			Write-Log "DryRun enabled - the upgrade would be blocked by the failed hardware checks above." "WARN"
		} else {
			Write-Log "Device does not meet Windows 11 requirements. Use -SkipHardwareChecks to override." "ERROR"
			throw "HardwareRequirementsNotMet"
		}
	}

	if ($DryRun) {
		Write-Log "DryRun enabled - would run: $setupExe $arguments"
		Write-Log "Finished (dry run)."
		exit 0
	}

	# Start setup.exe and wait for completion. Capture exit code for reporting.
	Write-Log "Launching setup.exe"

	$startInfo = New-Object System.Diagnostics.ProcessStartInfo
	$startInfo.FileName = $setupExe
	$startInfo.Arguments = $arguments
	$startInfo.UseShellExecute = $false
	$startInfo.RedirectStandardOutput = $true
	$startInfo.RedirectStandardError = $true
	$startInfo.CreateNoWindow = $true

	$process = New-Object System.Diagnostics.Process
	$process.StartInfo = $startInfo

	# Start the process and stream output to the log file in real time
	$stdoutReader = $null
	$stderrReader = $null
	if ($process.Start()) {
		$stdoutReader = $process.StandardOutput
		$stderrReader = $process.StandardError
		Write-Log "setup.exe started (PID $($process.Id)). Streaming output to log."
	} else {
		Write-Log "Failed to start setup.exe" "ERROR"
		exit 4
	}

	# Read output while the process is running
	while (-not $process.HasExited) {
		Start-Sleep -Seconds 1
		if ($stdoutReader.Peek() -gt -1) {
			$line = $stdoutReader.ReadLine()
			if ($line) { Write-Log $line "OUT" }
		}
		if ($stderrReader.Peek() -gt -1) {
			$eline = $stderrReader.ReadLine()
			if ($eline) { Write-Log $eline "ERR" }
		}
	}

	# Drain remaining output
	while ($stdoutReader.Peek() -gt -1) { $line = $stdoutReader.ReadLine(); if ($line) { Write-Log $line "OUT" } }
	while ($stderrReader.Peek() -gt -1) { $eline = $stderrReader.ReadLine(); if ($eline) { Write-Log $eline "ERR" } }

	$exitCode = $process.ExitCode
	Write-Log "setup.exe exited with code $exitCode"

	# Common exit codes can be documented or acted on. Here we treat 0 as success.
	if ($exitCode -eq 0) {
		Write-Log "Upgrade completed successfully."
		exit 0
	} else {
		Write-Log "Upgrade failed or requires attention. Exit code: $exitCode" "ERROR"
		exit $exitCode
	}

} catch {
	Write-Log "Unhandled error: $_" "ERROR"
	exit 1
} finally {
	Write-Log "Script finished at $(Get-Date -Format o)"
}
