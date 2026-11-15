# Changelog

All notable changes to this project are listed here. Versions follow [Semantic Versioning](https://semver.org/).

## 1.0.0 (2026-11-14)

First public release.

- `Deploy-DesktopInfo.ps1` installs Desktop Info as SYSTEM from any RMM, Intune or a startup script, and removes it with `$Mode = "Remove"`.
- The desktop shows the location (from computer name prefix rules), a data loss notice when the PC deletes files (Shared PC or UWF), contact lines, host name, user name and UWF state.
- The lock screen shows the location, host name and data loss notice on a dark panel. It renders once at startup, and only when something changed.
- On laptops, the desktop redraws after the monitor layout changes (docking, undocking).
- Cleans up BGInfo launchers and any older builds listed in the cleanup settings, including in profiles that are not signed in.
- Your own wallpaper and lock screen images are optional. Without them, the Windows default images (`img0.jpg` and `img100.jpg`) are used, so the package can be the script alone.
- All settings are in one editable block. `$OrgName` and `$OrgFolder` build the folder, task, mutex and registry names.
- Stops before changing anything if `$OrgFolder` or `$DetectionKeyName` is blank or has unsafe characters, so a typo can never point Install or Remove at `C:\Windows\Web` itself.
- Exit codes: 0 success, 1 failed, 2 skipped because the UWF filter is on, 3 installed with warnings.
- Safe to feed to PowerShell through standard input: no blank lines, no block comments, one `exit` on the last line.
