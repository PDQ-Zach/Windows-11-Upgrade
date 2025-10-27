# Windows 11 Upgrade

PowerShell helper repository containing a script to expand a prepared Windows 11 setup ZIP and run setup.exe with robust logging, validation and error handling.

This repo was created from an existing local copy of `Win11Upgrade.ps1`.

## Contents

- `Win11Upgrade.ps1` — main upgrade script
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

3. Check logs under `C:\temp\winupgradelogs` (or the fallback path) for detailed output.

## Notes

- This repository contains a script intended to run on Windows; it was created locally and is not (yet) pushed to a remote.
- If you want a private GitHub repo created and pushed, tell me and I'll create it (requires GitHub CLI `gh` signed in or a token).
