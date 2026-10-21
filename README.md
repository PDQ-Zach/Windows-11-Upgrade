# Windows 11 Upgrade

PowerShell scripts to upgrade devices to Windows 11 and clean up afterwards: `Win11Upgrade.ps1` expands a prepared Windows 11 setup ZIP and runs setup.exe with logging, validation and error handling, and `Win11Cleanup.ps1` removes the leftover files once the upgrade has finished. See `PDQ-Connect-Guide.md` for deploying them with PDQ Connect.

## Contents

- `Win11Upgrade.ps1` — main upgrade script
- `Win11Cleanup.ps1` — post-upgrade cleanup script
- `PDQ-Connect-Guide.md` — step-by-step guide to building the upgrade and cleanup packages in PDQ Connect
- `LICENSE` — MIT License
- `.gitignore` — common ignores for PowerShell/Windows/macOS

## Usage

1. Copy `setup.zip` into the working folder configured by the script (default: `C:\win_11_upgrade\`).
2. Run the script elevated on a target machine:

   PowerShell (run as Administrator):

   ```powershell
   .\Win11Upgrade.ps1 -ZipName "setup.zip" -WorkDir "C:\win_11_upgrade\"  
   # Add -DryRun switch to validate steps without executing setup.exe
   ```

   The script exits without doing anything on devices already on Windows 11 (add `-Force` to run anyway). `-DryRun` validates the hardware, ZIP contents and free space without expanding the ZIP or running setup.

   The script stops before launching setup if the TPM is missing, not ready or not 2.0, or if Secure Boot is not enabled. Add `-SkipHardwareChecks` to log those problems and continue anyway.

3. Check logs under `C:\temp\winupgradelogs` (or the fallback path) for detailed output.

## Post-upgrade cleanup

After the machine has rebooted into Windows 11, run `Win11Cleanup.ps1` elevated:

```powershell
.\Win11Cleanup.ps1 -DryRun   # preview what would be removed
.\Win11Cleanup.ps1           # remove the working folder and setup staging folders
```

It refuses to run unless the machine is on Windows 11 (build 22000+), so a failed upgrade keeps its files for a retry (`-Force` overrides this). Opt-in switches:

- `-RemoveWindowsOld` — also delete `C:\Windows.old` (disables rollback; Windows removes it on its own after about 10 days)
- `-RemoveSetupLogs` — also delete the copied setup logs in `C:\Temp\Logs\WinSetup`

Exit codes: `0` success, `1` error or not on Windows 11, `2` some items could not be removed. Logs go to `C:\temp\winupgradelogs`.

## Disclaimer

These scripts start an in-place Windows 11 upgrade and can delete folders (including, optionally, `C:\Windows.old`). They are provided as-is, without warranty (see `LICENSE`).

- Test on a pilot device first, using `-DryRun` before a real run.
- The upgrade runs setup with `/compat ignorewarning`, so compatibility warnings will not stop it. Check application and driver compatibility, and back up important data, before deploying widely.
- The scripts check the TPM and Secure Boot but not the CPU. Confirm CPU eligibility yourself.

## Tests

`tests/Run-Tests.ps1` runs smoke tests for both scripts (no real upgrade is performed). They run automatically on GitHub Actions on every push and pull request, and can be run locally on a Windows machine from an elevated PowerShell:

```powershell
.\tests\Run-Tests.ps1
```
