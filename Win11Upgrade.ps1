<#
  Win11Upgrade.ps1
  Improved script to expand a prepared Windows 11 setup ZIP and run setup.exe with
  robust logging, validation and error handling.

  Expectations / assumptions:
  - The ZIP containing the Windows 11 setup files (named "setup.zip") has already
	been copied to the working folder (no copy steps in this script).
  - Script is executed on the target machine (not a remote copy step).
  - This script should be run elevated (it will check and fail early if not).

  Features:
  - Timestamped log file under C:\temp\winupgradelogs\
  - Verbose console output and log file writes
  - Skips devices that are already on Windows 11
  - Input validations (elevation, TPM 2.0, Secure Boot, existence of ZIP, free disk space)
  - -DryRun validates everything (including the ZIP contents) without expanding or running setup
  - Try/Catch and exit codes for common failure modes
  - Comments that explain the upgrade steps and common flags
#>

param(
	[string]$ZipName = "setup.zip",    # Name of the ZIP file expected in the working dir
	[string]$WorkDir = "C:\win_11_upgrade\", # Working directory containing the ZIP
	[switch]$DryRun = $false,           # If true, validate and log actions but do not expand the ZIP or run setup
	[switch]$SkipHardwareChecks = $false, # If true, log TPM / Secure Boot problems but do not block the upgrade
	[switch]$Force = $false             # If true, run even if the device is already on Windows 11
)

function Write-Log {
	param(
		[string]$Message,
		[string]$Level = "INFO"
	)
	$timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
	$line = "[$timestamp] [$Level] $Message"
	# Write-Host, not Write-Output: Write-Log is called inside functions whose return value is used
	Write-Host $line
	try {
		# If LogFile is not set, create a fallback in the user's TEMP directory so we can always log
		if (-not $Global:LogFile) {
			try {
				if (-not $Global:LogDir) { $Global:LogDir = 'C:\temp\winupgradelogs' }
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
		$present = $false
		$ready = $false
		$specVersion = $null
		if (Get-Command -Name Get-Tpm -ErrorAction SilentlyContinue) {
			$tpm = Get-Tpm
			$present = [bool]$tpm.TpmPresent
			$ready = [bool]$tpm.TpmReady
		}
		# SpecVersion (e.g. "2.0, 0, 1.38") is only exposed by Win32_Tpm, not by Get-Tpm
		$wmi = Get-CimInstance -Namespace 'root\cimv2\security\microsofttpm' -ClassName Win32_Tpm -ErrorAction SilentlyContinue
		if ($wmi) {
			$specVersion = $wmi.SpecVersion
			if (-not $present) { $present = $true; $ready = ($wmi.IsActivated_InitialValue -eq $true) }
		}
		return @{ Present = $present; Ready = $ready; SpecVersion = $specVersion }
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
# TPM must be present and version 2.0 (not-ready is only a warning); Secure Boot must be enabled.
function Test-HardwareRequirements {
	$problems = @()

	$osInfo = Get-OSVersionInfo
	if ($osInfo) { Write-Log "OS: $($osInfo.Caption) Version $($osInfo.Version) Build $($osInfo.BuildNumber)" }

	$tpmInfo = Test-TPM
	Write-Log "TPM present: $($tpmInfo.Present); Ready: $($tpmInfo.Ready); SpecVersion: $($tpmInfo.SpecVersion)"
	if (-not $tpmInfo.Present) {
		$problems += "TPM not present"
	} else {
		if ($tpmInfo.SpecVersion -notmatch '^\s*2\.0') {
			$problems += "TPM 2.0 required (found spec version '$($tpmInfo.SpecVersion)')"
		}
		if (-not $tpmInfo.Ready) {
			Write-Log "TPM is present but not reported as ready; setup may still proceed." "WARN"
		}
	}

	$secureBoot = Test-SecureBoot
	Write-Log "Secure Boot detected: $secureBoot"
	if (-not $secureBoot) {
		$problems += "Secure Boot is not enabled or could not be verified"
	}

	return $problems
}

# --- Start script ---
# Use the requested fixed log directory so logs are always placed at the same location
$Global:LogDir = 'C:\temp\winupgradelogs'
New-Item -Path $Global:LogDir -ItemType Directory -Force | Out-Null
$Global:LogFile = Join-Path -Path $Global:LogDir -ChildPath "Win11Upgrade_$(Get-Date -Format yyyyMMdd_HHmmss).log"

try {
	Write-Log "Starting Windows 11 upgrade script"

	Assert-Elevated

	# Nothing to do on a device that is already on Windows 11 (build 22000 or newer)
	$osInfo = Get-OSVersionInfo
	if ($osInfo -and $osInfo.BuildNumber -ge 22000 -and -not $Force) {
		Write-Log "Device is already on Windows 11 (build $($osInfo.BuildNumber)). Nothing to do (use -Force to run anyway)."
		exit 0
	}

	# Run pre-upgrade hardware checks (OS build, TPM, Secure Boot) first so an ineligible
	# device fails fast, before the ZIP is validated and expanded.
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

	# Validate working directory and ZIP. The file copy step creates the working directory.
	Write-Log "Using working directory: $WorkDir"
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

	# Confirm setup.exe is at the top level of the ZIP without expanding it. This catches a ZIP
	# made from the containing folder (setup.exe one level down) before any extraction work.
	try {
		Add-Type -AssemblyName System.IO.Compression.FileSystem
		$zipArchive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
		try {
			$zipHasSetup = [bool]($zipArchive.Entries | Where-Object { $_.FullName -ieq 'setup.exe' })
		} finally {
			$zipArchive.Dispose()
		}
	} catch {
		Write-Log "Unable to read $zipPath as a ZIP archive: $_" "ERROR"
		throw "ZipInvalid"
	}
	if (-not $zipHasSetup) {
		Write-Log "setup.exe is not at the top level of $zipPath. Re-zip the files themselves, not the folder that contains them." "ERROR"
		throw "SetupMissing"
	}

	$setupExe = Join-Path -Path $WorkDir -ChildPath "setup.exe"
	$copyLogsPath = 'C:\Temp\Logs\WinSetup'
	$arguments = "/auto Upgrade /migratedrivers all /EULA accept /ShowOOBE none /dynamicupdate disable /quiet /compat ignorewarning /copylogs `"$copyLogsPath`""

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

	if ($DryRun) {
		Write-Log "DryRun enabled - would expand $zipPath to $WorkDir"
		Write-Log "DryRun enabled - would run: $setupExe $arguments"
		Write-Log "Finished (dry run)."
		exit 0
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

	# Confirm setup.exe landed in the working directory after expanding the ZIP
	if (-not (Test-Path -Path $setupExe)) {
		Write-Log "setup.exe not found in $WorkDir after expanding archive" "ERROR"
		throw "SetupMissing"
	}

	New-Item -Path $copyLogsPath -ItemType Directory -Force | Out-Null

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

	# Exit code 0 means setup accepted the job and handed off to the upgrade phases, not that
	# Windows 11 is installed yet. The device reboots to finish; confirm the result afterwards
	# (OS build 22000+ and the logs in the /copylogs folder and %windir%\Panther).
	if ($exitCode -eq 0) {
		Write-Log "setup.exe completed successfully. The upgrade continues after reboot; verify the OS build once the device is back up."
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
