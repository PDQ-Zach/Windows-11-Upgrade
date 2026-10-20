# Windows 11 Upgrade

PowerShell helper repository containing a script to expand a prepared Windows 11 setup ZIP and run setup.exe with robust logging, validation and error handling.

This repo was created from an existing local copy of `Win11Upgrade.ps1`.

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

## Notes

- This repository contains a script intended to run on Windows; it was created locally and is not (yet) pushed to a remote.
- If you want a private GitHub repo created and pushed, tell me and I'll create it (requires GitHub CLI `gh` signed in or a token).
