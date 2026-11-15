# Desktop Info

A BGInfo replacement for Windows, deployed by an RMM as SYSTEM. It draws useful details onto each user's desktop wallpaper and onto the lock screen, and on shared PCs that wipe files it tells people to save their work somewhere else.

One script, `Deploy-DesktopInfo.ps1`, installs everything. It carries four smaller scripts inside it, writes them to disk, and registers scheduled tasks to run them. After the install, Windows Task Scheduler runs everything on its own, with no agent or service.

## What it does

**On the desktop** (per user), a block of text, by default on the right side:

```
Your Organization - Main Office - Lab
Files saved on this PC are deleted when you sign out.
Save your work to OneDrive or USB drive.
Contact your IT help desk
Host Name:        HQLAB-PC01
User Name:        jsmith
UWF State:        Unlocked
```

- **Location line:** picked from the computer name prefix (`$LocationRules`).
- **Data loss notice (gold):** shown only when the PC really deletes files, using the strongest true statement. Shared PC deleting at sign-out comes first, then the UWF filter being on, then Shared PC deleting profiles later.
- **Contact lines:** one set for user names matching `$StaffPattern`, another for everyone else.
- **Host Name, User Name and UWF State,** in a column like BGInfo. UWF State only shows on PCs with UWF installed.

**On the lock screen** (one image for everyone), a dark rounded panel with the location, the host name in large type, and the data loss notice when it applies.

**On laptops,** it redraws the desktop after the monitor layout changes (docking, undocking, closing the lid while docked), so the text fits the new primary screen.

## How it works

| Script (installed to `C:\Windows\Web\<OrgFolder>\DesktopInfo`) | Runs as | When |
| --- | --- | --- |
| `Write-DeviceStatus.ps1` | SYSTEM | Every startup. Writes `UWFStatus.txt` and `SharedPCStatus.txt` (Shared PC settings are only readable by SYSTEM). |
| `Update-LockScreen.ps1` | SYSTEM | 45 seconds after startup. Redraws only when the content, resolution or base image changed, then points the lock screen at the new image. |
| `Update-DesktopInfo.ps1` | Signed-in user, no admin rights | At sign-in, 60 seconds after sign-in, and at every unlock |
| `Watch-DesktopDisplay.ps1` | Signed-in user, no admin rights | Whole session, laptops only by default. It checks the monitor layout every 5 seconds and redraws after a change holds for 10 seconds. |

Design notes:

- **The lock screen only renders at startup.** Re-rendering it during a session swaps the file LogonUI is using, and the lock screen goes black after sign-out.
- **The desktop renders twice at sign-in.** On brand-new profiles (Shared PC guests), Windows applies its default theme after the first render.
- **The install folder is locked down.** SYSTEM and Administrators get full control, and Users can only read and run. SYSTEM runs scripts from that folder, so users must not be able to change them.
- **The install stops (exit 2) if the UWF filter is on,** because the changes would be discarded at restart.
- **The detection key is written last,** so a failed install is never reported as installed.
- **No console windows.** The user tasks start PowerShell through `conhost --headless`, so nothing flashes on screen.

## Requirements

- Windows 10 or Windows 11 (64-bit), Windows PowerShell 5.1.
- Runs as SYSTEM, from an RMM or any tool that runs a script as SYSTEM.
- PowerShell in FullLanguage mode for the user tasks. AppLocker or WDAC must allow the scripts in `C:\Windows\Web\<OrgFolder>\DesktopInfo`.
- Optional: your own two base images (JPEG, 1920x1080 or larger), shipped next to the script. Without them, the Windows default wallpaper (`img0.jpg`) and lock screen (`img100.jpg`) under `C:\Windows\Web` are used.
- Optional: UWF (Unified Write Filter), Shared PC mode.

## Settings

All settings are in the editable block at the top of `Deploy-DesktopInfo.ps1`. There are no parameters. Text settings are copied into `DesktopInfo.json`, so the desktop and lock screen always match. Fonts, sizes and colors are at the top of the embedded `Update-DesktopInfo.ps1` and `Update-LockScreen.ps1`.

| Name | Default | Purpose |
| --- | --- | --- |
| `$Mode` | `"Install"` | `"Install"` or `"Remove"` |
| `$OrgName` | `"Your Organization"` | Shown to people: detection key publisher, default package name, location labels |
| `$OrgFolder` | `"YourOrg"` | Builds the install folder, per-user folder, task names, mutex names and registry paths. Letters, numbers, hyphens and underscores only. The script stops with exit 1 before changing anything if it is blank or has other characters. |
| `$WallpaperFileName` | `"Wallpaper.jpg"` | Your wallpaper's file name in the package (optional). The image in use is installed under this name. |
| `$LockScreenFileName` | `"LockScreen.jpg"` | Your lock screen's file name in the package (optional). The image in use is installed under this name. |
| `$DefaultWallpaperPaths` | `img0.jpg`, then the 4K `img0_3840x2160.jpg` | Windows images to use when no wallpaper is packaged or installed. `@()` requires your own. |
| `$DefaultLockScreenPaths` | `Screen\img100.jpg`, then `img0.jpg` | Windows images to use when no lock screen is packaged or installed. `@()` requires your own. |
| `$PackageName` | `"$OrgName Desktop Info"` | Package name, written to the detection key. Match the name in your RMM if it detects by name. |
| `$PackageVersion` | `"1.0.0"` | Package version, written to the detection key. Match the version in your RMM or Intune detection rule. |
| `$DetectionKeyName` | `"$OrgFolder-DesktopInfo"` | Key name under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` |
| `$PackageFolder` | `""` | Folder holding the two images. Blank means the folder the script runs from. |
| `$TitleText` | `""` | Optional line above the location. Blank hides it. |
| `$LocationRules` | Three examples | Computer name prefix to location label. Checked top to bottom, first match wins. |
| `$DefaultLocation` | `""` | Label when no rule matches. Blank hides the line. |
| `$StaffPattern` | `""` | User names matching this regex get `$StaffContactLines`. Blank gives everyone `$OtherContactLines`. |
| `$StaffContactLines` | `"Contact your IT help desk"` | Contact lines for matching users. An empty string draws a spacer line. |
| `$OtherContactLines` | `"Contact your IT help desk"` | Contact lines for everyone else |
| `$HostnameLabel`, `$UsernameLabel`, `$UWFLabel` | `"Host Name:"`, `"User Name:"`, `"UWF State:"` | Desktop labels |
| `$NoticeSharedPC` | `"Files saved on this PC are deleted when you sign out."` | Notice when Shared PC deletes at sign-out |
| `$NoticeUWF` | `"Files saved on this PC are deleted when it restarts."` | Notice when the UWF filter is on |
| `$NoticeSharedPCKept` | `"Files saved on this PC can be deleted at any time."` | Notice when Shared PC deletes profiles later |
| `$NoticeAction` | `"Save your work to OneDrive or USB drive."` | Second notice line. Blank hides it. |
| `$UWFWarnStates` | `@("Locked")` | UWF states that show the notice |
| `$SharedPCWarnStates` | `@("DeleteAtSignOut", "DeleteByThreshold")` | Shared PC states that show the notice |
| `$DesktopCorner` | `"MiddleRight"` | MiddleRight, MiddleLeft, BottomRight, BottomLeft, TopRight, TopLeft |
| `$DesktopMiddlePercent` | `40` | For Middle placements, the block's center as a percent of the wallpaper picture's height |
| `$LockScreenCorner` | `"TopRight"` | TopRight, TopLeft, BottomRight, BottomLeft |
| `$DesktopMessage` | `""` | Optional extra desktop line, drawn last |
| `$CleanupOldBuilds` | `$true` | Remove BGInfo and the old builds listed below |
| `$OldLauncherPatterns` | `@("bginfo")` | Launchers whose command line contains these are removed |
| `$ProtectedProcessPatterns` | `@()` | Processes whose command line contains these are never stopped, such as your RMM agent's folder |
| `$OldTaskNames` | `@()` | Extra scheduled tasks to remove by name |
| `$OldFolders` | `@()` | Old folders deleted after a successful install |
| `$OldDetectionKeys` | `@()` | Retired package detection keys to delete |
| `$OldUwfFileExclusions` | `@()` | Old UWF file exclusions to remove |
| `$CleanOfflineProfiles` | `$true` | Also clean the registry of profiles that are not signed in |
| `$UnloadStaleHiveMounts` | `$true` | Unload user hives an older script left loaded |
| `$OwnHiveMountPrefixes` | `@("$($OrgFolder)_Hive_")` | Hive mount names never treated as stale |
| `$RenderOnUnlock` | `$true` | Redraw the desktop at unlock |
| `$RenderSecondPassDelaySeconds` | `60` | Second desktop render after sign-in. 0 turns it off. |
| `$UseHeadlessConsole` | `$true` | Start user tasks through `conhost --headless` |
| `$RedrawOnDisplayChange` | `"Laptops"` | Install the display watcher on `Laptops`, `All` PCs, or `Off` |
| `$LockScreenStartupDelaySeconds` | `45` | Delay before the lock screen renders after startup |
| `$LockScreenAtSignIn` | `$false` | Leave off (re-rendering in a session can black out the lock screen) |
| `$ApplyUwfExclusions` | `$true` | Add UWF exclusions so the lock screen survives restarts |
| `$RunNow` | `$true` | Run the status check, lock screen and desktop render during the install |
| `$RenderWaitSeconds` | `180` | How long the install waits for signed-in users' desktop renders |
| `$WarningExitCode` | `3` | Exit code for "installed with warnings". Set to 0 to report plain success. |
| `$CimRetries`, `$CimRetryDelaySeconds` | `3`, `5` | Retries for WMI queries |

## Deploy

The package can be `Deploy-DesktopInfo.ps1` alone, which uses the Windows default images. To brand it, put your two images in the same folder. Each image is picked in this order: the one in the package, then the copy already installed, then the Windows default. So adding your images in a later version replaces the defaults, and a later run without images keeps whatever is installed.

**RMM:** run `Deploy-DesktopInfo.ps1` as SYSTEM, from a folder that also holds your images if you use them. If your RMM deploys packages, zip the script and any images (the files, not a folder), and give the package the same name and version as `$PackageName` and `$PackageVersion`. Bump `$PackageVersion` and the package version for every change. For detection, check `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\<DetectionKeyName>`, value `DisplayVersion`. If your agent starts 32-bit PowerShell, run the script with `%windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe` so registry changes land in the 64-bit registry. The script also runs when the RMM pipes it to PowerShell through standard input.

**Intune (Win32 app):** package the folder with the Win32 Content Prep Tool. Use install command `%windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Deploy-DesktopInfo.ps1` with install behavior System. The `sysnative` path matters: Intune runs install commands as a 32-bit process, and 32-bit PowerShell writes the detection key under `WOW6432Node`, where a default registry detection rule never looks. For the uninstall command, ship a second copy of the script (for example `Remove-DesktopInfo.ps1`) with `$Mode = "Remove"` and run it the same way. For the detection rule, use the registry key above with `DisplayVersion` equal to `$PackageVersion`. Map exit code 3 to success if you keep `$WarningExitCode = 3`. Map exit code 2 (UWF filter on) to retry.

**Group Policy:** a computer startup script works, with the script (and any images) in the same folder on the share. It reinstalls at every startup. That's safe, because the install is idempotent, but it costs boot time, so an RMM or Intune is the better fit.

Always run it as its own process with `-File`. Never dot-source it: it ends with `exit`.

**For contributors:** the script follows rules that let RMMs feed it to PowerShell through standard input. There are no blank lines and no block comments. `} catch {`, `} else {` and `} finally {` stay on one line. There are no backtick line continuations, and there is exactly one `exit`, on the last line. In a double-quoted string, write `${name}:`, not `$name:`. The four embedded scripts sit between `@'` and `'@`, and their `__ORGFOLDER__`, `__WALLPAPERFILE__` and `__LOCKSCREENFILE__` placeholders are filled in when the deployer writes them to disk.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Installed (or removed) |
| 1 | Failed, or a setting such as `$OrgFolder` is invalid. Nothing is reported as installed. Rerunning is safe. |
| 2 | Skipped, because the UWF filter is on or its state can't be read. Run again with the filter off. |
| 3 | Installed with warnings. Search the output for `WARNING`. Set by `$WarningExitCode`. |

## Logs

- `C:\Windows\Web\<OrgFolder>\DesktopInfo\Logs\Deploy.log`: the last install (admins only)
- `C:\Windows\Web\<OrgFolder>\DesktopInfo\Logs\LockScreen.log`: lock screen renders (admins only)
- `%LOCALAPPDATA%\<OrgFolder>\DesktopInfo\DesktopInfo.log` and `DesktopInfo.prev.log`: the user's last two desktop renders
- `%LOCALAPPDATA%\<OrgFolder>\DesktopInfo\DisplayWatch.log`: monitor layout changes (laptops)

## Uninstall

Set `$Mode = "Remove"` and run the script as SYSTEM. It stops and removes the scheduled tasks, clears the lock screen policy values that point into its folder, and deletes `C:\Windows\Web\<OrgFolder>` and the detection key. A few things are left in place on purpose:

- Each user's current wallpaper, until something else sets one.
- UWF exclusions it added.
- The `DisableWindowsSpotlightFeatures` policy it set.

## Known limitations

- **One image for all monitors.** The desktop is one picture sized to the primary monitor, and Windows fits it to every monitor. With mixed monitor sizes, the text can look slightly off on secondary screens.
- **Per-session cost of the display watcher:** one hidden PowerShell process per signed-in laptop user.
- **Light default wallpaper on Windows 11.** The desktop text is white with a gold notice, made for a dark background. Windows 11's default `img0.jpg` is a light image, so the text can be hard to read on it. Ship your own darker wallpaper, or set `$BackdropPanel = $true` near the top of the embedded `Update-DesktopInfo.ps1` to draw a dark panel behind the text.
- **The default image is a copy.** The Windows default is copied in once. A later Windows change to its own default image isn't picked up.
- **First install while someone is signed in.** The lock screen is rendered mid-session, and it can show black after that user signs out until one restart.
- **Spotlight is turned off PC-wide.** The lock screen sets `DisableWindowsSpotlightFeatures`.
- **No Group Policy fights.** A Group Policy or MDM wallpaper policy will override the desktop render. The renderer logs a warning when it sees one.
- **Real startups only.** The status check and lock screen render depend on a real startup, so Fast Startup should be off.

## License

MIT. See the [LICENSE](../LICENSE) file in the root of this repository.
