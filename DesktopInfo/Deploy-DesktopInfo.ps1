# Deploy-DesktopInfo.ps1
# Version: 1.0.0
# Author: Jeremy Green
# Copyright (c) 2026 Jeremy Green
# SPDX-License-Identifier: MIT
# Source: https://github.com/jeremydgreen/Action1-Tools
# Shared under the MIT License. Keep this header in any copy or modified version.
# Built with AI assistance; designed, tested and maintained by the author.
#
# WHAT IT DOES
# Desktop Info, a BGInfo replacement. Draws the location, contact lines, host name, user name, UWF state and a data loss
# notice on each user's desktop wallpaper, and the location, host name and data loss notice on the lock screen.
# On laptops it also redraws the desktop when the monitor layout changes (docking, undocking, closing the lid while docked).
# Ships as one RMM package, with or without your own two base images ($WallpaperFileName and $LockScreenFileName).
# Without them it uses the Windows default wallpaper and lock screen images. Runs as SYSTEM.
# Removes BGInfo launchers and other old wallpaper builds it is told about in the cleanup settings.
#
# Install mode, in order:
#   1. Stops if the UWF filter is on, because anything written now would be thrown away at the next restart.
#   2. Picks each image (the package, then the copy already installed, then the Windows default), checks that it opens
#      and that all four embedded scripts are present. Nothing changes if any check fails.
#   3. Removes BGInfo and the old builds: processes, Run and RunOnce entries (machine, every user hive, the Default user),
#      Startup items, old scheduled tasks, old per-user policy wallpaper values and old UWF exclusions. Group Policy
#      scripts are reported only, because they can only be fixed in the GPO.
#   4. Builds C:\Windows\Web\<OrgFolder> and locks it down: SYSTEM and Administrators full control, Users read only, Logs
#      admins only.
#        C:\Windows\Web\<OrgFolder>                   the two base images
#        C:\Windows\Web\<OrgFolder>\DesktopInfo       the four scripts, DesktopInfo.json, UWFStatus.txt, SharedPCStatus.txt
#        C:\Windows\Web\<OrgFolder>\DesktopInfo\Logs  Deploy.log, LockScreen.log
#        C:\Windows\Web\<OrgFolder>\LockScreen        the two newest lock screen renders and LockScreen.sig
#   5. Writes DesktopInfo.json from the settings below, then the four scripts, each checked with the PowerShell parser.
#   6. Registers the tasks: <OrgFolder>-DesktopInfo-Status (SYSTEM, startup), <OrgFolder>-DesktopInfo-LockScreen (SYSTEM,
#      45 s after startup), <OrgFolder>-DesktopInfo-Render (signed-in user, at sign-in, 60 s after sign-in and at unlock)
#      and, on laptops, <OrgFolder>-DesktopInfo-DisplayWatch (signed-in user, whole session, redraws when the monitor
#      layout changes).
#   7. On UWF machines, adds the exclusions that let the lock screen carry over to the next boot.
#   8. Runs the status check and lock screen now, renders the desktop for anyone signed in, and relays their logs.
#   9. Deletes the old folders (only after the new lock screen rendered) and writes the RMM detection key.
# Remove mode ($Mode = "Remove") deletes the tasks, C:\Windows\Web\<OrgFolder>, the lock screen policy values that point
# into it, and the detection key. Each user's current wallpaper stays until something else sets one.
# It ends with exit code 0 (done), 1 (failed), 2 (skipped because the UWF filter is on or unreadable) or 3 (installed with
# warnings, set by $WarningExitCode).
#
# All the work happens inside this one function, so the run can stop early with return and still finish on the single
# exit at the bottom.
function Invoke-DeployDesktopInfo {
    # ===== Editable settings =====
    # Every value here is safe to change. Text values are copied into DesktopInfo.json so both screens match.
    # Install or Remove
    $Mode = "Install"
    # ----- Your organization -----
    # $OrgName is shown to people (detection key publisher, the default package name). $OrgFolder is used to build the folder
    # under C:\Windows\Web, the per-user folder, the scheduled task names, the mutex names and registry paths. Keep
    # $OrgFolder to letters, numbers, hyphens and underscores.
    $OrgName = "Your Organization"
    $OrgFolder = "YourOrg"
    # File names of your two base images, shipped next to this script in the package. Both are optional. The image in use
    # is always installed under these names in C:\Windows\Web\<OrgFolder>, and a packaged image replaces it on the next run.
    $WallpaperFileName = "Wallpaper.jpg"
    $LockScreenFileName = "LockScreen.jpg"
    # Used when an image is not in the package and no copy is installed yet: the first file here that exists is copied in.
    # These are the images Windows itself ships, so the package can be this script alone. Set a list to @() to require your own.
    $DefaultWallpaperPaths = @("$env:SystemRoot\Web\Wallpaper\Windows\img0.jpg", "$env:SystemRoot\Web\4K\Wallpaper\Windows\img0_3840x2160.jpg")
    $DefaultLockScreenPaths = @("$env:SystemRoot\Web\Screen\img100.jpg", "$env:SystemRoot\Web\Wallpaper\Windows\img0.jpg")
    # Must match the RMM package name and version exactly, or the RMM will not detect the install
    $PackageName = "$OrgName Desktop Info"
    $PackageVersion = "1.0.0"
    $DetectionKeyName = "$OrgFolder-DesktopInfo"
    # Folder holding the two jpg files. Blank means the folder this script runs from, which is the unzipped RMM package.
    $PackageFolder = ""
    # ----- Text shown on the desktop and the lock screen -----
    # Optional line above the location name on both screens. Blank hides it, so the location name is the top line.
    $TitleText = ""
    # Hostname prefix rules. Checked top to bottom, first match wins, not case sensitive. Specific prefixes must stay above general ones.
    $LocationRules = @(
        @{ Prefix = "HQLAB"; Label = "$OrgName - Main Office - Lab" },
        @{ Prefix = "HQ"; Label = "$OrgName - Main Office" },
        @{ Prefix = "BRANCH1"; Label = "$OrgName - Branch 1" }
    )
    # Shown when no rule matches. Leave blank to hide the location line.
    $DefaultLocation = ""
    # Desktop only. User names matching $StaffPattern get the staff lines, everyone else the other lines. A blank pattern
    # gives everyone the other lines.
    # An empty string in either list draws a blank spacer line.
    $StaffPattern = ""
    $StaffContactLines = @(
        "Contact your IT help desk"
    )
    $OtherContactLines = @(
        "Contact your IT help desk"
    )
    # Desktop labels for the label and value lines at the bottom of the block. A blank label shows the value on its own.
    $HostnameLabel = "Host Name:"
    $UsernameLabel = "User Name:"
    $UWFLabel = "UWF State:"
    # Data loss notice, shown on both screens only on PCs that really delete files (see the warn states below).
    # The first line says when files are deleted, the action line says what to do. A blank action line hides it.
    # Only one first line shows, the strongest one that is true: sign-out, then restart (UWF on), then "any time".
    # A restart always signs the user out first, so the sign-out wording wins when Shared PC and UWF both apply.
    # "Any time" is for Shared PC machines that keep profiles and delete them later (DeleteByThreshold, such as shared
    # workstations). It names no number of days on purpose, so files still being there tomorrow never makes it look wrong.
    $NoticeSharedPC = "Files saved on this PC are deleted when you sign out."
    $NoticeUWF = "Files saved on this PC are deleted when it restarts."
    $NoticeSharedPCKept = "Files saved on this PC can be deleted at any time."
    $NoticeAction = "Save your work to OneDrive or USB drive."
    # Status values that show the warning on both screens.
    # UWF values: Locked, Unlocked, NotInstalled, Unknown. Locked means the filter is on.
    # To warn whenever UWF is installed, even with the filter off, use @("Locked", "Unlocked").
    # Shared PC values: DeleteAtSignOut, DeleteByThreshold, NoDeletion, NotEnforced, NotEnabled, Unknown.
    # NotEnforced means the CSP still holds a deletion policy but the Shared PC Account Manager service is disabled, so nothing is deleted.
    $UWFWarnStates = @("Locked")
    $SharedPCWarnStates = @("DeleteAtSignOut", "DeleteByThreshold")
    # Desktop placement: MiddleRight, MiddleLeft, BottomRight, BottomLeft, TopRight, TopLeft
    $DesktopCorner = "MiddleRight"
    # For MiddleRight and MiddleLeft: where the center of the text block sits, as a percent of the wallpaper picture's height from the top.
    # Measured on the picture, not the screen, so it stays put on any monitor shape. Pick a value that lands in a clear area of
    # your wallpaper, away from other desktop windows. Lower numbers move the text up, higher numbers move it down.
    $DesktopMiddlePercent = 40
    # Lock screen placement: TopRight, TopLeft, BottomRight, BottomLeft
    $LockScreenCorner = "TopRight"
    # Optional extra desktop message, drawn last
    $DesktopMessage = ""
    # ----- Old builds to clean up -----
    # Leftovers from BGInfo and any older wallpaper or lock screen builds you list below. Any launcher left in place could
    # redraw over the new wallpaper, so the install finds and removes all of them.
    $CleanupOldBuilds = $true
    # Launchers whose command line contains any of these are removed. Not case sensitive.
    $OldLauncherPatterns = @("bginfo")
    # Processes whose command line contains any of these are never stopped, even when they match a launcher pattern. Add your
    # RMM agent's install folder here, for example @("\RMMAgent\"). This script and its parent process are always skipped.
    $ProtectedProcessPatterns = @()
    # Scheduled tasks removed by name, in addition to any task whose action matches the patterns above
    # Example: @("Old-LockScreen-Updater")
    $OldTaskNames = @()
    # Deleted after the new install succeeds. Never anything under C:\Windows\Web\<OrgFolder>. Example: @("C:\Tools\BGInfo")
    $OldFolders = @()
    # RMM detection keys from retired packages, under HKLM\SOFTWARE\...\Uninstall. Example: @("Old_Wallpaper_Package")
    $OldDetectionKeys = @()
    # UWF file exclusions from retired builds, removed from the next-session configuration. Example: @("\Tools\BGInfo")
    $OldUwfFileExclusions = @()
    # Also load and clean the registry of profiles that are not signed in. The Default user is always cleaned.
    $CleanOfflineProfiles = $true
    # Unload user hives that an older script loaded under a temporary name and never unloaded.
    # A Default user hive left loaded can stop Windows from building new profiles, which Shared PC machines do at every sign-in.
    $UnloadStaleHiveMounts = $true
    # Hive mount names this package uses. Never treated as stale, so another run working at the
    # same moment is left alone. Keep in step with the mount name the cleanup step builds from $OrgFolder.
    $OwnHiveMountPrefixes = @("$($OrgFolder)_Hive_")
    # ----- Tasks -----
    # Repaint the desktop when a user unlocks the PC
    $RenderOnUnlock = $true
    # Render the desktop again this many seconds after each sign-in. On a brand-new profile (every Shared PC Guest sign-in)
    # Windows applies its default theme after the first render and covers it; the second render puts the info back. 0 turns it off.
    $RenderSecondPassDelaySeconds = 60
    # $true launches the desktop renderer through conhost --headless so no window flashes. $false uses powershell -WindowStyle Hidden.
    $UseHeadlessConsole = $true
    # Redraw the desktop when the monitor layout changes: docking, undocking, or closing the lid of a docked laptop. Without
    # it the old picture is stretched or cropped onto the new primary monitor until the next unlock or sign-in.
    # Laptops: only PCs whose chassis is a laptop, notebook, convertible, detachable or tablet. All: every PC. Off: never.
    # A small watcher runs hidden in each user's session, reads the layout every 5 seconds and redraws once it settles.
    $RedrawOnDisplayChange = "Laptops"
    # The lock screen waits this long after startup so the display driver has reported a resolution
    $LockScreenStartupDelaySeconds = 45
    # Render the lock screen again 30 seconds after each sign-in. Keep this off: re-rendering during a session swaps the file
    # LogonUI is using and leaves the lock screen black after the sign-out. Nothing on the lock screen changes during a session.
    $LockScreenAtSignIn = $false
    # ----- UWF -----
    # Exclude the lock screen image folder and policy keys so the lock screen carries over to the next boot on protected machines
    $ApplyUwfExclusions = $true
    # ----- Test runs and exit codes -----
    # Run the status writer and lock screen now, and render the desktop for anyone signed in
    $RunNow = $true
    $RenderWaitSeconds = 180
    # Exit code for "installed, but some warnings need a look". Set it to 0 if your RMM should count that as a plain success.
    $WarningExitCode = 3
    $CimRetries = 3
    $CimRetryDelaySeconds = 5
    # =============================
    # ===== Embedded script 1 of 4: Write-DeviceStatus.ps1 (SYSTEM, at startup) =====
    # Each embedded script is stored as plain text between a line ending in @' and a line that is exactly '@ at the left
    # edge. Nothing in them runs here. The Scripts stage below writes them to disk, and the scheduled tasks run them.
    $StatusScript = @'
# Write-DeviceStatus.ps1
# Version: 1.0.0
# Author: Jeremy Green
# Copyright (c) 2026 Jeremy Green
# SPDX-License-Identifier: MIT
# Source: https://github.com/jeremydgreen/Action1-Tools
# Shared under the MIT License. Keep this header in any copy or modified version.
# Built with AI assistance; designed, tested and maintained by the author.
# Part of Desktop Info 1.0.0. Installed by Deploy-DesktopInfo.ps1, which holds the master copy. Edit it there.
#
# WHAT IT DOES
# Runs as SYSTEM from the DesktopInfo Status task at every startup, and once during the install. It records whether
# this PC deletes users' files, because the desktop renderer runs as a standard user and cannot ask Windows itself:
#   SharedPCStatus.txt: NotEnabled, NoDeletion, NotEnforced, DeleteAtSignOut, DeleteByThreshold, Unknown
#   UWFStatus.txt:      NotInstalled, Locked, Unlocked, Unknown
# UWF and Shared PC changes only take effect at restart, so one check at startup stays true for the whole session.
# Shared PC comes from the MDM_SharedPC WMI bridge, which only answers to SYSTEM. A deletion policy only counts when the
# Shared PC Account Manager service (shpamsvc), which does the deleting, is allowed to run. The SharedPC CSP leaves its
# values behind after Shared PC is turned off, so that case is written as NotEnforced and never shows the notice.
# UWF counts as Locked only when UWF_Filter says the filter is on in this session.
# Exit code 0 when both status files were written, 1 when one of them could not be written.
#
# Everything runs inside this function and logs with Write-Host only. Anything sent to the output stream inside it would
# become part of the exit code.
function Invoke-WriteDeviceStatus {
    # ===== Editable settings =====
    $StatusFolder = "C:\Windows\Web\__ORGFOLDER__\DesktopInfo"
    $UWFStatusFileName = "UWFStatus.txt"
    $SharedPCStatusFileName = "SharedPCStatus.txt"
    $CimRetries = 6
    $CimRetryDelaySeconds = 5
    # Require the Shared PC Account Manager service to be enabled before reporting a deletion policy
    $RequireAccountManagerService = $true
    # =============================
    # Start clean. A missing status folder is created here, because the renderers wait for these files.
    $exitCode = 0
    if (-not [System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { Write-Host "Note: not running as SYSTEM. The Shared PC check will likely report Unknown." }
    if (-not (Test-Path $StatusFolder)) {
        try { New-Item -Path $StatusFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null } catch { Write-Host "Failed to create ${StatusFolder}: $(([string]$_.Exception.Message).Trim())"; return 1 }
    }
    # ----- Shared PC -----
    # Retried because the WMI bridge can be slow to answer right after startup. Invalid class or namespace means Shared PC was
    # never set up on this PC, and Access denied means this is not SYSTEM. Both are final answers, so they are not retried.
    # An unset DeletionPolicy means 1 (disk space threshold), never 0, so it can never trigger the sign-out notice by accident.
    $sharedPC = "Unknown"
    $done = $false
    $attempt = 0
    while (-not $done -and $attempt -lt $CimRetries) {
        $attempt++
        try {
            $spc = Get-CimInstance -Namespace "root\cimv2\mdm\dmmap" -ClassName "MDM_SharedPC" -ErrorAction Stop | Select-Object -First 1
            if ($null -eq $spc) {
                $sharedPC = "NotEnabled"
                Write-Host "MDM_SharedPC returned no instance. Shared PC mode is not configured."
            } else {
                Write-Host "MDM_SharedPC EnableSharedPCMode: $($spc.EnableSharedPCMode)  EnableAccountManager: $($spc.EnableAccountManager)  DeletionPolicy: $($spc.DeletionPolicy)"
                if ($spc.EnableSharedPCMode -ne $true) {
                    $sharedPC = "NotEnabled"
                } elseif ($spc.EnableAccountManager -ne $true) {
                    $sharedPC = "NoDeletion"
                } elseif ($null -eq $spc.DeletionPolicy -or [string]$spc.DeletionPolicy -eq "") {
                    $sharedPC = "Unknown"
                    Write-Host "Account manager is on but DeletionPolicy is empty."
                } elseif ([int]$spc.DeletionPolicy -eq 0) {
                    $sharedPC = "DeleteAtSignOut"
                } else {
                    $sharedPC = "DeleteByThreshold"
                }
            }
            $done = $true
        } catch {
            $nativeCode = [string]$_.Exception.NativeErrorCode
            $message = ([string]$_.Exception.Message).Trim()
            if ($nativeCode -eq "InvalidClass" -or $nativeCode -eq "InvalidNamespace" -or $message -match "Invalid (class|namespace)") {
                $sharedPC = "NotEnabled"
                Write-Host "MDM_SharedPC is not available ($message). Treating Shared PC as not enabled."
                $done = $true
            } elseif ($nativeCode -eq "AccessDenied" -or $message -match "Access (is )?denied") {
                $sharedPC = "Unknown"
                Write-Host "Access denied reading MDM_SharedPC. This check must run as SYSTEM."
                $done = $true
            } else {
                Write-Host "Attempt $attempt of $CimRetries could not read MDM_SharedPC: $message"
            }
        }
        if (-not $done -and $attempt -lt $CimRetries) { Start-Sleep -Seconds $CimRetryDelaySeconds }
    }
    # The CSP says files are deleted. Only believe it when the service that deletes them can run.
    if (@("DeleteAtSignOut", "DeleteByThreshold") -contains $sharedPC) {
        $amProps = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\AccountManagement" -ErrorAction SilentlyContinue
        if ($null -ne $amProps) { Write-Host "SharedPC AccountManagement registry: $((@($amProps.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value })) -join '  ')" } else { Write-Host "SharedPC AccountManagement registry key is not present" }
        $accountManager = Get-CimInstance -ClassName Win32_Service -Filter "Name='shpamsvc'" -ErrorAction SilentlyContinue
        if ($null -eq $accountManager) {
            Write-Host "Shared PC Account Manager service (shpamsvc) was not found."
            if ($RequireAccountManagerService) { Write-Host "The CSP reports a deletion policy, but nothing on this machine can enforce it. Treating it as leftover settings."; $sharedPC = "NotEnforced" }
        } elseif ($accountManager.StartMode -eq "Disabled") {
            Write-Host "Shared PC Account Manager service (shpamsvc): StartMode Disabled, State $($accountManager.State)"
            if ($RequireAccountManagerService) { Write-Host "The CSP reports a deletion policy, but the service that deletes profiles is disabled. Treating it as leftover settings."; $sharedPC = "NotEnforced" }
        } else {
            Write-Host "Shared PC Account Manager service (shpamsvc): StartMode $($accountManager.StartMode), State $($accountManager.State). The deletion policy is in force."
        }
    }
    try {
        # Write the answer. ASCII, one word, read by both renderers.
        Set-Content -Path (Join-Path $StatusFolder $SharedPCStatusFileName) -Value $sharedPC -Encoding ASCII -Force -ErrorAction Stop
        Write-Host "Shared PC status written: $sharedPC"
    } catch {
        Write-Host "Failed to write Shared PC status file: $(([string]$_.Exception.Message).Trim())"
        $exitCode = 1
    }
    # ----- UWF -----
    # No uwfvol service key and no uwfmgr.exe means UWF is not installed. Otherwise UWF_Filter decides: CurrentEnabled is the
    # filter state for this session. A leftover service key with no WMI provider is treated as not installed.
    $status = "Unknown"
    $serviceKeyPresent = Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\uwfvol"
    $uwfmgrPresent = Test-Path (Join-Path $env:SystemRoot "System32\uwfmgr.exe")
    Write-Host "uwfvol service key present: $serviceKeyPresent"
    Write-Host "uwfmgr.exe present: $uwfmgrPresent"
    if (-not $serviceKeyPresent -and -not $uwfmgrPresent) {
        $status = "NotInstalled"
        Write-Host "No UWF components found."
    } else {
        $done = $false
        $attempt = 0
        while (-not $done -and $attempt -lt $CimRetries) {
            $attempt++
            try {
                $filter = Get-CimInstance -Namespace "root\standardcimv2\embedded" -ClassName "UWF_Filter" -ErrorAction Stop | Select-Object -First 1
                if ($null -ne $filter) {
                    Write-Host "UWF_Filter CurrentEnabled: $($filter.CurrentEnabled)  NextEnabled: $($filter.NextEnabled)"
                    if ($filter.CurrentEnabled -eq $true) { $status = "Locked" } else { $status = "Unlocked" }
                    $done = $true
                } else {
                    Write-Host "Attempt $attempt of $CimRetries returned no UWF_Filter instance"
                }
            } catch {
                $nativeCode = [string]$_.Exception.NativeErrorCode
                $message = ([string]$_.Exception.Message).Trim()
                if ($nativeCode -eq "InvalidClass" -or $nativeCode -eq "InvalidNamespace" -or $message -match "Invalid (class|namespace)") {
                    Write-Host "UWF WMI provider is not registered ($message). Not retrying."
                    if ($uwfmgrPresent) {
                        $status = "Unknown"
                        Write-Host "uwfmgr.exe exists but the WMI provider does not. UWF looks damaged on this machine."
                    } else {
                        $status = "NotInstalled"
                        Write-Host "uwfmgr.exe and the WMI provider are both missing. Treating UWF as not installed."
                    }
                    $done = $true
                } else {
                    Write-Host "Attempt $attempt of $CimRetries could not read UWF_Filter: $message"
                }
            }
            if (-not $done -and $attempt -lt $CimRetries) { Start-Sleep -Seconds $CimRetryDelaySeconds }
        }
    }
    # Only when the signals disagree: log the optional feature state so a damaged UWF install can be told apart from a leftover.
    if (($serviceKeyPresent -ne $uwfmgrPresent) -or ($status -eq "Unknown")) {
        try {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName "Client-UnifiedWriteFilter" -ErrorAction Stop
            if ($null -ne $feature) { $featureState = [string]$feature.State } else { $featureState = "feature not found" }
            Write-Host "Diagnostic: Client-UnifiedWriteFilter feature state: $featureState"
        } catch {
            Write-Host "Diagnostic: could not read the UWF optional feature state: $(([string]$_.Exception.Message).Trim())"
        }
    }
    try {
        # Write the answer.
        Set-Content -Path (Join-Path $StatusFolder $UWFStatusFileName) -Value $status -Encoding ASCII -Force -ErrorAction Stop
        Write-Host "UWF status written: $status"
    } catch {
        Write-Host "Failed to write UWF status file: $(([string]$_.Exception.Message).Trim())"
        $exitCode = 1
    }
    return $exitCode
}
# Pass the function's result to Task Scheduler as the exit code
exit (Invoke-WriteDeviceStatus)
'@
    # ===== Embedded script 2 of 4: Update-DesktopInfo.ps1 (signed-in user, at sign-in, 60 s later and at unlock) =====
    $RendererScript = @'
# Update-DesktopInfo.ps1
# Version: 1.0.0
# Author: Jeremy Green
# Copyright (c) 2026 Jeremy Green
# SPDX-License-Identifier: MIT
# Source: https://github.com/jeremydgreen/Action1-Tools
# Shared under the MIT License. Keep this header in any copy or modified version.
# Built with AI assistance; designed, tested and maintained by the author.
# Part of Desktop Info 1.0.0. Installed by Deploy-DesktopInfo.ps1, which holds the master copy. Edit it there.
#
# WHAT IT DOES
# Runs as the signed-in user from the DesktopInfo Render task at sign-in, again 60 seconds later and at every unlock.
# Draws a block of text over C:\Windows\Web\__ORGFOLDER__\__WALLPAPERFILE__ and sets it as that user's wallpaper. Top to bottom:
#   location (and an optional title)
#   gold notice: when files are deleted, then what to do (only when it applies)
#   contact lines (staff lines for user names matching the staff pattern, other lines for everyone else)
#   Host Name, User Name and UWF State as label and value pairs, values in a column like BGInfo
# Text, location rules and notice wording come from DesktopInfo.json, written by the deployer, so both screens match.
# The data loss notice uses UWFStatus.txt and SharedPCStatus.txt from this boot; a missing or stale file never shows it.
# MiddleRight places the block at a point on the wallpaper picture, not the screen, so
# it lands in the same place on any monitor shape. Fonts are points as on a 1080p screen and scale with the resolution.
# Contrast on a dark blue wallpaper (WCAG 2.1): white text 9.3:1, gold notice 6.6:1, both above the 4.5:1 AA minimum.
# Must run as the user, not SYSTEM: wallpaper is per user, so a SYSTEM run would paint SYSTEM's desktop.
# Exit code 0 when the wallpaper was drawn and applied, 1 when it could not be.
#
# The main function does the work. The lock at the bottom of this script wraps it, so two renders never run at once.
function Invoke-UpdateDesktopInfo {
    # ===== Editable settings =====
    # Shared text settings written by the deployer
    $ConfigPath = "C:\Windows\Web\__ORGFOLDER__\DesktopInfo\DesktopInfo.json"
    # Base wallpaper candidates, checked top to bottom. The first file that exists and loads is used.
    $BaseWallpaperPaths = @(
        "C:\Windows\Web\__ORGFOLDER__\__WALLPAPERFILE__"
    )
    $FallbackColor = "#1F2A44"
    $StatusFolder = "C:\Windows\Web\__ORGFOLDER__\DesktopInfo"
    $StatusWaitSeconds = 30
    $ExplorerWaitSeconds = 60
    $PostExplorerDelaySeconds = 5
    $OutputFolder = Join-Path $env:LOCALAPPDATA "__ORGFOLDER__\DesktopInfo"
    # Which lines to draw. The text itself comes from DesktopInfo.json.
    $ShowTitle = $true
    $ShowLocation = $true
    $ShowContacts = $true
    $ShowHostname = $true
    $ShowUsername = $true
    $ShowUWFStatus = $true
    $ShowWarning = $true
    $FontName = "Arial"
    $TitleFontSize = 18
    $LocationFontSize = 16
    $LocationBold = $true
    $DetailFontSize = 14
    $WarningFontSize = 14
    $TextColor = "#FFFFFF"
    # ----- Notice style -----
    # Gold measures 6.6:1 on a dark blue wallpaper, so it passes WCAG AA without an outline.
    $WarningColor = "#FFD54F"
    $WarningBold = $true
    $LineSpacing = 1.15
    # Extra space between sections, as a fraction of a detail line
    $SectionGap = 0.6
    $MarginSide = 24
    $MarginTop = 24
    # Gap between the text and the top of the taskbar for the bottom corners, in pixels at 1080p
    $MarginBottom = 24
    # Keep bottom-corner text above the taskbar
    $AvoidTaskbar = $true
    # The notice and the optional message wrap to the block's width, but never narrower than this percent of the screen width
    $WrapWidthPercent = 18
    # Center or Left. Left lines the notice up with the rest of the text.
    $WarningAlign = "Left"
    # Column left-aligns the values in a column whose longest value ends on the block's right edge, like BGInfo.
    # Right puts each value flush with the block's right edge instead.
    $DetailValueAlign = "Column"
    # Minimum space between a label and its value, in pixels at 1080p
    $PairGap = 24
    $DropShadow = $true
    # Optional outline around the notice text. Off by default because it made the letters hard to read at these sizes.
    $WarningOutline = $false
    $WarningOutlineColor = "#000000"
    # Visible outline width in pixels at 1080p
    $WarningOutlineWidth = 1
    # Optional badge: the notice sits in its own filled box spanning the block. Navy on gold measures about 12:1.
    $WarningBadge = $false
    $BadgeFillColor = "#FFD54F"
    $BadgeTextColor = "#0A1A3A"
    $BadgePadding = 10
    $BadgeCornerRadius = 8
    # Optional translucent panel behind the whole text block, like the lock screen. Keeps every line readable over any wallpaper.
    $BackdropPanel = $false
    $PanelFillColor = "#0A1A3A"
    # 0 is invisible, 255 is solid
    $PanelFillAlpha = 170
    $PanelPadding = 18
    $PanelCornerRadius = 12
    $JpegQuality = 95
    # Stop BGInfo in this session so it cannot overwrite the rendered wallpaper
    $KillBGInfo = $true
    $BGInfoProcessNames = @("Bginfo", "Bginfo64")
    # Seconds to watch after applying. If anything changes the wallpaper in that window it is reapplied, up to 3 times. 0 turns this off.
    $WallpaperGuardSeconds = 20
    # =============================
    # Stop early on the two conditions that make a render impossible: Constrained Language Mode blocks Add-Type and
    # System.Drawing, and a SYSTEM run would set SYSTEM's wallpaper instead of the user's.
    if ($ExecutionContext.SessionState.LanguageMode -ne "FullLanguage") {
        Write-Host "PowerShell is running in $($ExecutionContext.SessionState.LanguageMode) for this user. Add-Type and System.Drawing need FullLanguage."
        return 1
    }
    if ([System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        Write-Host "This script must run as the signed-in user, not SYSTEM. Wallpaper is a per-user setting."
        return 1
    }
    # Per-user output folder and log. This run's log starts fresh.
    if (-not (Test-Path $OutputFolder)) { New-Item -Path $OutputFolder -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
    $logPath = Join-Path $OutputFolder "DesktopInfo.log"
    # Keep the last run's log. The second pass 60 seconds after sign-in would otherwise erase the first render's log.
    if (Test-Path -LiteralPath $logPath) { Move-Item -LiteralPath $logPath -Destination (Join-Path $OutputFolder "DesktopInfo.prev.log") -Force -ErrorAction SilentlyContinue }
    Set-Content -Path $logPath -Value "Update-DesktopInfo run $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') as $env:USERDOMAIN\$env:USERNAME" -Encoding UTF8 -ErrorAction SilentlyContinue
    # Write-Log sends each line to the screen and DesktopInfo.log. A sign-in task has no visible console, so the log file is
    # the only record. Nothing may go to the output stream in this function, because it would become part of the exit code.
    function Write-Log { param([string]$Text) Write-Host $Text; Add-Content -Path $logPath -Value $Text -Encoding UTF8 -ErrorAction SilentlyContinue }
    # Read the shared settings. Without them there is nothing to draw, so a bad file stops the run.
    $config = $null
    try { $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { Write-Log "Could not read the shared settings file ${ConfigPath}: $($_.Exception.Message)"; return 1 }
    $TitleText = [string]$config.TitleText
    $LocationRules = @($config.LocationRules | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Prefix) })
    $DefaultLocation = [string]$config.DefaultLocation
    $StaffPattern = [string]$config.StaffPattern
    $StaffContactLines = @($config.StaffContactLines | Where-Object { $null -ne $_ })
    $OtherContactLines = @($config.OtherContactLines | Where-Object { $null -ne $_ })
    $NoticeSharedPC = [string]$config.NoticeSharedPC
    $NoticeUWF = [string]$config.NoticeUWF
    $NoticeSharedPCKept = [string]$config.NoticeSharedPCKept
    if ([string]::IsNullOrWhiteSpace($NoticeSharedPCKept)) { $NoticeSharedPCKept = $NoticeSharedPC }
    $NoticeAction = [string]$config.NoticeAction
    $UWFWarnStates = @($config.UWFWarnStates | Where-Object { $null -ne $_ })
    $SharedPCWarnStates = @($config.SharedPCWarnStates | Where-Object { $null -ne $_ })
    $Corner = [string]$config.DesktopCorner
    $HostnameLabel = "Host Name:"
    $UsernameLabel = "User Name:"
    $UWFLabel = "UWF State:"
    if ($null -ne $config.HostnameLabel) { $HostnameLabel = [string]$config.HostnameLabel }
    if ($null -ne $config.UsernameLabel) { $UsernameLabel = [string]$config.UsernameLabel }
    if ($null -ne $config.UWFLabel) { $UWFLabel = [string]$config.UWFLabel }
    # Fall back to safe values for anything mistyped, so a bad setting changes the look but never stops the render.
    if (@("Center", "Left") -notcontains $WarningAlign) { $WarningAlign = "Center" }
    if (@("Right", "Column") -notcontains $DetailValueAlign) { $DetailValueAlign = "Column" }
    $MiddlePercent = 40.0
    if ($null -ne $config.DesktopMiddlePercent) { try { $MiddlePercent = [double]$config.DesktopMiddlePercent } catch { $MiddlePercent = 40.0 } }
    if ($MiddlePercent -lt 5 -or $MiddlePercent -gt 95) { Write-Log "DesktopMiddlePercent $MiddlePercent is out of range. Using 40."; $MiddlePercent = 40.0 }
    $Message = [string]$config.DesktopMessage
    Write-Log "Shared settings loaded from $ConfigPath (version $($config.Version))"
    if ([string]::IsNullOrWhiteSpace($StaffPattern)) { $StaffPattern = "(?!)" }
    if (@("MiddleRight", "MiddleLeft", "BottomRight", "BottomLeft", "TopRight", "TopLeft") -notcontains $Corner) {
        Write-Log "Unknown corner '$Corner'. Using MiddleRight."
        $Corner = "MiddleRight"
    }
    # At sign-in the task can start before the desktop shell. A wallpaper set before explorer.exe runs may not stick, so wait.
    $mySession = (Get-Process -Id $PID).SessionId
    $explorer = Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $mySession }
    if ($null -eq $explorer) {
        Write-Log "Waiting up to $ExplorerWaitSeconds seconds for explorer.exe in session $mySession"
        $explorerDeadline = (Get-Date).AddSeconds($ExplorerWaitSeconds)
        do {
            Start-Sleep -Seconds 2
            $explorer = Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $mySession }
        } while ($null -eq $explorer -and (Get-Date) -lt $explorerDeadline)
        if ($null -eq $explorer) { Write-Log "explorer.exe never appeared. Continuing anyway." } else { Write-Log "explorer.exe found. Waiting $PostExplorerDelaySeconds seconds for the shell to settle."; Start-Sleep -Seconds $PostExplorerDelaySeconds }
    }
    # Log anything that can override this script's wallpaper, so a tech reading the log sees the cause right away.
    $policyWallpaper = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "Wallpaper" -ErrorAction SilentlyContinue).Wallpaper
    if (-not [string]::IsNullOrWhiteSpace($policyWallpaper)) { Write-Log "WARNING: A Group Policy desktop wallpaper is set ($policyWallpaper). It overrides this script at every policy refresh." }
    $cspWallpaper = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP" -Name "DesktopImagePath" -ErrorAction SilentlyContinue).DesktopImagePath
    if (-not [string]::IsNullOrWhiteSpace($cspWallpaper)) { Write-Log "WARNING: PersonalizationCSP DesktopImagePath is set ($cspWallpaper). It forces a machine-wide wallpaper over this script." }
    foreach ($policyRoot in @("HKCU:", "HKLM:")) {
        $noChange = (Get-ItemProperty -Path "$policyRoot\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" -Name "NoChangingWallPaper" -ErrorAction SilentlyContinue).NoChangingWallPaper
        if ($noChange -eq 1) { Write-Log "Note: the Prevent changing desktop background policy (NoChangingWallPaper) is set under $policyRoot." }
    }
    $spotlightState = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\DesktopSpotlight\Settings" -Name "EnabledState" -ErrorAction SilentlyContinue).EnabledState
    if ($spotlightState -eq 1) { Write-Log "WARNING: Windows Spotlight is turned on for this user's desktop. Spotlight can replace the wallpaper after this script sets it." }
    $backgroundType = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers" -Name "BackgroundType" -ErrorAction SilentlyContinue).BackgroundType
    if ($null -ne $backgroundType) { Write-Log "Desktop background type before applying: $backgroundType (0 is Picture)" }
    # BGInfo redraws the wallpaper whenever it runs. Stop it in this session and log any launcher left behind.
    function Stop-BGInfo {
        $bgProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $mySession -and ($BGInfoProcessNames -contains $_.ProcessName) }
        foreach ($proc in $bgProcs) {
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                Write-Log "Stopped BGInfo process $($proc.ProcessName) (PID $($proc.Id))"
            } catch {
                Write-Log "Could not stop $($proc.ProcessName) (PID $($proc.Id)): $($_.Exception.Message)"
            }
        }
    }
    if ($KillBGInfo) {
        $runKeys = @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Run", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run")
        foreach ($runKey in $runKeys) {
            $runProps = Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue
            if ($null -eq $runProps) { continue }
            foreach ($prop in $runProps.PSObject.Properties) {
                if ($prop.Name -notlike "PS*" -and [string]$prop.Value -match "bginfo") { Write-Log "BGInfo launcher found: $runKey [$($prop.Name)] $($prop.Value)" }
            }
        }
        $startupFolders = @([Environment]::GetFolderPath("Startup"), [Environment]::GetFolderPath("CommonStartup"))
        $shell = $null
        try { $shell = New-Object -ComObject WScript.Shell } catch { $shell = $null }
        foreach ($folder in $startupFolders) {
            if ([string]::IsNullOrWhiteSpace($folder) -or -not (Test-Path -LiteralPath $folder)) { continue }
            foreach ($item in (Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)) {
                $target = ""
                if ($item.Extension -eq ".lnk" -and $null -ne $shell) { try { $target = [string]$shell.CreateShortcut($item.FullName).TargetPath } catch { $target = "" } }
                if ($item.Name -match "bginfo" -or $target -match "bginfo") { Write-Log "BGInfo launcher found: $($item.FullName) $target" }
            }
        }
        Stop-BGInfo
    }
    # Location from the host name prefix (first match wins), then staff or other contact lines.
    $location = $DefaultLocation
    foreach ($rule in $LocationRules) {
        if ($env:COMPUTERNAME.StartsWith([string]$rule.Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $location = [string]$rule.Label
            break
        }
    }
    Write-Log "Hostname $env:COMPUTERNAME matched location: '$location'"
    $isStaff = ($env:USERNAME -match $StaffPattern)
    if ($isStaff) { Write-Log "User $env:USERNAME matches $StaffPattern. Using staff contact lines." } else { Write-Log "User $env:USERNAME does not match $StaffPattern. Using other contact lines." }
    # Read the status files written by the SYSTEM task at this startup. Files older than this boot are ignored, and the wait
    # covers a sign-in that happens before the status task has finished.
    $uwfStatusFile = Join-Path $StatusFolder "UWFStatus.txt"
    $sharedPCStatusFile = Join-Path $StatusFolder "SharedPCStatus.txt"
    $bootTime = $null
    try { $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { Write-Log "Could not read last boot time: $($_.Exception.Message)" }
    $statusDeadline = (Get-Date).AddSeconds($StatusWaitSeconds)
    # Read-StatusFile returns the first line of a status file once it has been written since this boot, or $null when the
    # wait runs out. A file from an earlier boot is never trusted.
    function Read-StatusFile {
        param([string]$Path)
        do {
            if (Test-Path $Path) {
                $item = Get-Item -Path $Path -ErrorAction SilentlyContinue
                if ($null -ne $item -and ($null -eq $bootTime -or $item.LastWriteTime -gt $bootTime)) { return ([string](Get-Content -Path $Path -TotalCount 1 -ErrorAction SilentlyContinue)).Trim() }
            }
            if ((Get-Date) -lt $statusDeadline) { Start-Sleep -Seconds 2 }
        } while ((Get-Date) -lt $statusDeadline)
        return $null
    }
    $uwfStatus = "Unknown"
    if ($ShowUWFStatus -or $ShowWarning) {
        $raw = Read-StatusFile -Path $uwfStatusFile
        if ($null -eq $raw) {
            if (Test-Path (Join-Path $env:SystemRoot "System32\uwfmgr.exe")) {
                $uwfStatus = "Unknown"
                Write-Log "No UWF status written since last boot and uwfmgr.exe exists. Showing Unknown."
            } else {
                $uwfStatus = "NotInstalled"
                Write-Log "No UWF status written since last boot and uwfmgr.exe is absent. Treating UWF as not installed."
            }
        } else {
            $uwfStatus = $raw
        }
        if (@("NotInstalled", "Locked", "Unlocked", "Unknown") -notcontains $uwfStatus) {
            Write-Log "Unexpected UWF status value '$uwfStatus'. Showing Unknown."
            $uwfStatus = "Unknown"
        }
        Write-Log "UWF status: $uwfStatus"
    }
    $sharedPCStatus = "Unknown"
    if ($ShowWarning) {
        $raw = Read-StatusFile -Path $sharedPCStatusFile
        if ($null -eq $raw) { Write-Log "No Shared PC status written since last boot. Treating it as Unknown." } else { $sharedPCStatus = $raw }
        Write-Log "Shared PC status: $sharedPCStatus"
    }
    # Pick the data loss line. The strongest true statement wins: sign-out, then restart (UWF), then "any time".
    $uwfWarn = $UWFWarnStates -contains $uwfStatus
    $sharedPCWarn = $SharedPCWarnStates -contains $sharedPCStatus
    $warningCause = ""
    if ($sharedPCWarn -and $sharedPCStatus -eq "DeleteAtSignOut") { $warningCause = $NoticeSharedPC } elseif ($uwfWarn) { $warningCause = $NoticeUWF } elseif ($sharedPCWarn) { $warningCause = $NoticeSharedPCKept }
    $warningActive = $ShowWarning -and ($uwfWarn -or $sharedPCWarn)
    Write-Log "Warning shown: $warningActive (UWF match: $uwfWarn, Shared PC match: $sharedPCWarn)"
    # Notice block: when files are deleted, then what to do.
    $noticeTexts = @()
    if ($warningActive) { $noticeTexts += $warningCause }
    if ($warningActive) { $noticeTexts += $NoticeAction }
    $lines = @()
    foreach ($warn in $noticeTexts) { if (-not [string]::IsNullOrWhiteSpace($warn)) { $lines += [pscustomobject]@{ Text = $warn.Trim(); Value = ""; Section = "Warning"; Style = "Warning"; Align = $WarningAlign } } }
    if ($ShowTitle -and -not [string]::IsNullOrWhiteSpace($TitleText)) { $lines += [pscustomobject]@{ Text = $TitleText.Trim(); Value = ""; Section = "Header"; Style = "Title"; Align = "Left" } }
    if ($ShowLocation -and -not [string]::IsNullOrWhiteSpace($location)) { $lines += [pscustomobject]@{ Text = $location.Trim(); Value = ""; Section = "Header"; Style = "Location"; Align = "Left" } }
    if ($ShowContacts) {
        if ($isStaff) { $contactLines = $StaffContactLines } else { $contactLines = $OtherContactLines }
        foreach ($contact in $contactLines) { $lines += [pscustomobject]@{ Text = [string]$contact; Value = ""; Section = "Contacts"; Style = "Detail"; Align = "Left" } }
    }
    $pairs = @()
    if ($ShowHostname) { $pairs += ,@($HostnameLabel, $env:COMPUTERNAME) }
    if ($ShowUsername) { $pairs += ,@($UsernameLabel, $env:USERNAME) }
    if ($ShowUWFStatus -and $uwfStatus -ne "NotInstalled") { $pairs += ,@($UWFLabel, $uwfStatus) }
    foreach ($pair in $pairs) {
        # A blank label shows the value on its own line
        if ([string]::IsNullOrWhiteSpace($pair[0])) { $lines += [pscustomobject]@{ Text = [string]$pair[1]; Value = ""; Section = "Details"; Style = "Detail"; Align = "Left" } } else { $lines += [pscustomobject]@{ Text = ([string]$pair[0]).Trim(); Value = [string]$pair[1]; Section = "Details"; Style = "Detail"; Align = "Pair" } }
    }
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $lines += [pscustomobject]@{ Text = $Message.Trim(); Value = ""; Section = "Message"; Style = "Message"; Align = "Left" } }
    Write-Log "Lines to draw: $($lines.Count), corner: $Corner"
    # Every drawing object starts as null so the finally block can dispose whatever was created, even after an error.
    $bitmap = $null
    $graphics = $null
    $baseImage = $null
    $baseStream = $null
    $titleFont = $null
    $locationFont = $null
    $detailFont = $null
    $warningFont = $null
    $textBrush = $null
    $warningBrush = $null
    $shadowBrush = $null
    $outlinePen = $null
    $badgeTextBrush = $null
    $badgeBrush = $null
    $panelBrush = $null
    $badgePath = $null
    $panelPath = $null
    $warnFormat = $null
    $nearFormat = $null
    $centerFormat = $null
    $farFormat = $null
    $messageFormat = $null
    $encParams = $null
    # New-RoundedRectPath builds a rectangle with rounded corners, used for the optional notice badge and backdrop panel.
    function New-RoundedRectPath {
        param([float]$X, [float]$Y, [float]$W, [float]$H, [float]$R)
        $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
        if ($R -le 0 -or $W -le ($R * 2) -or $H -le ($R * 2)) {
            $path.AddRectangle([System.Drawing.RectangleF]::new($X, $Y, $W, $H))
            return $path
        }
        $d = [float]($R * 2)
        $path.AddArc($X, $Y, $d, $d, [float]180, [float]90)
        $path.AddArc([float]($X + $W - $d), $Y, $d, $d, [float]270, [float]90)
        $path.AddArc([float]($X + $W - $d), [float]($Y + $H - $d), $d, $d, [float]0, [float]90)
        $path.AddArc($X, [float]($Y + $H - $d), $d, $d, [float]90, [float]90)
        $path.CloseFigure()
        return $path
    }
    try {
        # SystemParametersInfo applies the wallpaper. DPI awareness makes the screen size come back in real pixels.
        if (-not ([System.Management.Automation.PSTypeName]"DesktopInfoRenderNative").Type) {
            Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class DesktopInfoRenderNative { [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni); [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
        }
        [void][DesktopInfoRenderNative]::SetProcessDPIAware()
        Add-Type -AssemblyName System.Drawing
        Add-Type -AssemblyName System.Windows.Forms
        # Screen size: the primary screen first, then the video controller, then 1920x1080 as a last resort.
        $width = 0
        $height = 0
        $bounds = $null
        $workArea = $null
        try { $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds; $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea; $width = $bounds.Width; $height = $bounds.Height } catch { Write-Log "Screen query failed: $($_.Exception.Message)" }
        if ($width -lt 640 -or $height -lt 480) {
            $vc = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
            if ($null -ne $vc) { $width = [int]$vc.CurrentHorizontalResolution; $height = [int]$vc.CurrentVerticalResolution }
        }
        if ($width -lt 640 -or $height -lt 480) { $width = 1920; $height = 1080; Write-Log "Could not detect resolution. Using 1920x1080." }
        Write-Log "Render size: ${width}x${height}"
        $scale = $height / 1080.0
        $ptToPx = (96.0 / 72.0) * $scale
        $bitmap = [System.Drawing.Bitmap]::new($width, $height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        # Load the base picture through memory so the file is never locked, and log exactly why a picture could not be used.
        $usedWallpaper = ""
        foreach ($candidate in $BaseWallpaperPaths) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            $baseBytes = $null
            try { $baseBytes = [System.IO.File]::ReadAllBytes($candidate) } catch { Write-Log "Base wallpaper could not be read as ${env:USERNAME}: $candidate ($($_.Exception.Message))"; continue }
            if ($baseBytes.Length -eq 0) { Write-Log "Base wallpaper is an empty file: $candidate"; continue }
            try {
                $baseStream = [System.IO.MemoryStream]::new($baseBytes)
                $baseImage = [System.Drawing.Image]::FromStream($baseStream)
                $usedWallpaper = $candidate
                break
            } catch {
                $loadError = $_.Exception.Message
                $head = ($baseBytes[0..([Math]::Min(11, $baseBytes.Length - 1))] | ForEach-Object { $_.ToString("X2") }) -join ""
                if ($head.StartsWith("FFD8")) { $kind = "a JPEG" } elseif ($head.StartsWith("89504E47")) { $kind = "a PNG" } elseif ($head.Length -ge 24 -and $head.StartsWith("52494646") -and $head.Substring(16, 8) -eq "57454250") { $kind = "a WebP, which System.Drawing cannot open" } elseif ($head.Length -ge 16 -and $head.Substring(8, 8) -eq "66747970") { $kind = "a HEIC or AVIF, which System.Drawing cannot open" } else { $kind = "an unknown format (first bytes $head)" }
                Write-Log "Base wallpaper could not be decoded: $candidate. The file is $kind. ($loadError)"
                if ($null -ne $baseStream) { $baseStream.Dispose() }
                $baseStream = $null
                $baseImage = $null
            }
        }
        # Scale the picture to fill the screen, centered, like the Fill wallpaper style. No picture means a solid color.
        if ($null -ne $baseImage) {
            $fill = [Math]::Max($width / $baseImage.Width, $height / $baseImage.Height)
            $drawW = $baseImage.Width * $fill
            $drawH = $baseImage.Height * $fill
            $graphics.DrawImage($baseImage, [float](($width - $drawW) / 2), [float](($height - $drawH) / 2), [float]$drawW, [float]$drawH)
            Write-Log "Base wallpaper: $usedWallpaper ($($baseImage.Width)x$($baseImage.Height))"
        } else {
            $graphics.Clear([System.Drawing.ColorTranslator]::FromHtml($FallbackColor))
            Write-Log "No base wallpaper could be loaded. Using solid color $FallbackColor."
        }
        # Fonts and brushes, sized for this resolution.
        if ($LocationBold) { $locationStyle = [System.Drawing.FontStyle]::Bold } else { $locationStyle = [System.Drawing.FontStyle]::Regular }
        $titleFont = [System.Drawing.Font]::new($FontName, [float]($TitleFontSize * $ptToPx), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $locationFont = [System.Drawing.Font]::new($FontName, [float]($LocationFontSize * $ptToPx), $locationStyle, [System.Drawing.GraphicsUnit]::Pixel)
        $detailFont = [System.Drawing.Font]::new($FontName, [float]($DetailFontSize * $ptToPx), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        if ($WarningBold) { $warningStyle = [System.Drawing.FontStyle]::Bold } else { $warningStyle = [System.Drawing.FontStyle]::Regular }
        $warningFont = [System.Drawing.Font]::new($FontName, [float]($WarningFontSize * $ptToPx), $warningStyle, [System.Drawing.GraphicsUnit]::Pixel)
        $textBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml($TextColor))
        $warningBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml($WarningColor))
        $shadowBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(160, 0, 0, 0))
        $badgeTextBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml($BadgeTextColor))
        $shadowOffset = [float]([Math]::Max(1, [Math]::Round(2 * $scale)))
        # The pen straddles the letter edges and the fill covers the inner half, so the pen is twice the visible width
        $outlinePen = [System.Drawing.Pen]::new([System.Drawing.ColorTranslator]::FromHtml($WarningOutlineColor), [float]([Math]::Max(2, 2 * $WarningOutlineWidth * $scale)))
        $outlinePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        # Text formats: single lines never wrap, the notice and the message wrap to the block width.
        $rightAligned = ($Corner -like "*Right")
        $noWrapFlags = [System.Drawing.StringFormatFlags]::NoWrap -bor [System.Drawing.StringFormatFlags]::NoClip
        $nearFormat = [System.Drawing.StringFormat]::GenericTypographic.Clone()
        $nearFormat.FormatFlags = $nearFormat.FormatFlags -bor $noWrapFlags
        $nearFormat.Alignment = [System.Drawing.StringAlignment]::Near
        $centerFormat = [System.Drawing.StringFormat]::GenericTypographic.Clone()
        $centerFormat.FormatFlags = $centerFormat.FormatFlags -bor $noWrapFlags
        $centerFormat.Alignment = [System.Drawing.StringAlignment]::Center
        $farFormat = [System.Drawing.StringFormat]::GenericTypographic.Clone()
        $farFormat.FormatFlags = $farFormat.FormatFlags -bor $noWrapFlags
        $farFormat.Alignment = [System.Drawing.StringAlignment]::Far
        $messageFormat = [System.Drawing.StringFormat]::GenericTypographic.Clone()
        $messageFormat.Alignment = [System.Drawing.StringAlignment]::Near
        # With a backdrop panel the panel's padding sits inside the screen margins, so the text moves in by that much
        $edgePad = [float]0
        if ($BackdropPanel) { $edgePad = [float]($PanelPadding * $scale) }
        $marginX = [float](($MarginSide * $scale) + $edgePad)
        $pairGapPx = [float]($PairGap * $scale)
        $warnFormat = [System.Drawing.StringFormat]::GenericTypographic.Clone()
        $warnFormat.FormatFlags = $warnFormat.FormatFlags -bor [System.Drawing.StringFormatFlags]::NoClip
        if ($WarningAlign -eq "Center") { $warnFormat.Alignment = [System.Drawing.StringAlignment]::Center } else { $warnFormat.Alignment = [System.Drawing.StringAlignment]::Near }
        # Width pass: the block is as wide as its widest line, or the widest label plus the gap plus the widest value.
        # The notice and the message wrap to that width instead of setting it, so a long notice does not stretch the block.
        $maxLineW = [float]0
        $maxLabelW = [float]0
        $maxValueW = [float]0
        $wrapNaturalW = [float]0
        $origin = [System.Drawing.PointF]::new(0, 0)
        foreach ($line in $lines) {
            if ($line.Style -eq "Title") { $font = $titleFont } elseif ($line.Style -eq "Location") { $font = $locationFont } elseif ($line.Style -eq "Warning") { $font = $warningFont } else { $font = $detailFont }
            if ([string]::IsNullOrWhiteSpace($line.Text)) { continue }
            if ($line.Align -eq "Pair") {
                $maxLabelW = [float][Math]::Max($maxLabelW, $graphics.MeasureString($line.Text, $font, $origin, $nearFormat).Width)
                $maxValueW = [float][Math]::Max($maxValueW, $graphics.MeasureString([string]$line.Value, $font, $origin, $nearFormat).Width)
            } elseif ($line.Style -eq "Message" -or $line.Style -eq "Warning") {
                $wrapNaturalW = [float][Math]::Max($wrapNaturalW, $graphics.MeasureString($line.Text, $font, $origin, $nearFormat).Width)
            } else {
                $maxLineW = [float][Math]::Max($maxLineW, $graphics.MeasureString($line.Text, $font, $origin, $nearFormat).Width)
            }
        }
        $blockW = $maxLineW
        if ($maxLabelW -gt 0) { $blockW = [float][Math]::Max($blockW, ($maxLabelW + $pairGapPx + $maxValueW)) }
        # Wrapped lines never squeeze into a column narrower than $WrapWidthPercent of the screen
        if ($wrapNaturalW -gt 0) { $blockW = [float][Math]::Max($blockW, [Math]::Min($wrapNaturalW, ($width * $WrapWidthPercent / 100))) }
        $blockW = [float]($blockW + 2)
        if ($blockW -gt ($width - (2 * $marginX))) { $blockW = [float]($width - (2 * $marginX)) }
        if ($rightAligned) { $blockLeft = [float]($width - $marginX - $blockW) } else { $blockLeft = $marginX }
        # The value column ends on the block's right edge. The block is always at least label + gap + value wide,
        # so a value never overlaps its label.
        $valueColumnX = [float]($blockLeft + $blockW - $maxValueW)
        # Layout pass: position every line relative to the top of the block and find where the block ends
        $layout = @()
        $y = [float]0
        $blockBottom = [float]0
        $prevSection = ""
        $drawnLines = 0
        $badgeBottom = [float]0
        $badgeTop = [float]0
        # The location (and the optional title) sits on top. The notice follows one section gap below, then everything else.
        foreach ($line in @($lines | Where-Object { $_.Section -eq "Header" -and -not [string]::IsNullOrWhiteSpace($_.Text) })) {
            if ($line.Style -eq "Title") { $font = $titleFont } else { $font = $locationFont }
            $layout += [pscustomobject]@{ Style = $line.Style; Text = $line.Text; Font = $font; Brush = $textBrush; Y = $y; BoxX = $blockLeft; BoxWidth = $blockW; BoxHeight = [float]($font.GetHeight($graphics) * 1.5); Format = $nearFormat }
            $blockBottom = [float]($y + $font.GetHeight($graphics))
            $y = [float]($y + ($font.GetHeight($graphics) * $LineSpacing))
            $drawnLines++
            $prevSection = "Header"
        }
        # Each notice line wraps to the block's width. With a badge the notice sits inside a padded box spanning the block.
        $noticeLines = @($lines | Where-Object { $_.Section -eq "Warning" -and -not [string]::IsNullOrWhiteSpace($_.Text) })
        if ($noticeLines.Count -gt 0) {
            $badgePadPx = [float]0
            $noticeBrush = $warningBrush
            if ($WarningBadge) { $badgePadPx = [float]($BadgePadding * $scale); $noticeBrush = $badgeTextBrush }
            $noticeBoxX = [float]($blockLeft + $badgePadPx)
            $noticeBoxW = [float]($blockW - (2 * $badgePadPx))
            if ($prevSection -ne "") { $y = [float]($y + ($detailFont.GetHeight($graphics) * $SectionGap)) }
            $badgeTop = $y
            $y = [float]($y + $badgePadPx)
            for ($n = 0; $n -lt $noticeLines.Count; $n++) {
                if ($n -gt 0) { $y = [float]($y + ($warningFont.GetHeight($graphics) * ($LineSpacing - 1))) }
                $size = $graphics.MeasureString($noticeLines[$n].Text, $warningFont, [System.Drawing.SizeF]::new($noticeBoxW, [float]$height), $warnFormat)
                $layout += [pscustomobject]@{ Style = "Warning"; Text = $noticeLines[$n].Text; Font = $warningFont; Brush = $noticeBrush; Y = $y; BoxX = $noticeBoxX; BoxWidth = $noticeBoxW; BoxHeight = [float]($size.Height + 2); Format = $warnFormat }
                $y = [float]($y + $size.Height)
                $drawnLines++
            }
            $y = [float]($y + $badgePadPx)
            $badgeBottom = $y
            $blockBottom = $y
            $prevSection = "Warning"
        }
        foreach ($line in $lines) {
            if ($line.Section -eq "Warning" -or $line.Section -eq "Header") { continue }
            $brush = $textBrush
            if ($line.Style -eq "Title") { $font = $titleFont } elseif ($line.Style -eq "Location") { $font = $locationFont } else { $font = $detailFont }
            if ($prevSection -ne "" -and $line.Section -ne $prevSection) { $y = [float]($y + ($detailFont.GetHeight($graphics) * $SectionGap)) }
            $prevSection = $line.Section
            if ([string]::IsNullOrWhiteSpace($line.Text)) {
                $y = [float]($y + ($detailFont.GetHeight($graphics) * $LineSpacing))
                continue
            }
            $drawnLines++
            if ($line.Style -eq "Message") {
                $size = $graphics.MeasureString($line.Text, $font, [System.Drawing.SizeF]::new($blockW, [float]$height), $messageFormat)
                $layout += [pscustomobject]@{ Style = $line.Style; Text = $line.Text; Font = $font; Brush = $brush; Y = $y; BoxX = $blockLeft; BoxWidth = $blockW; BoxHeight = [float]($size.Height + 2); Format = $messageFormat }
                $blockBottom = [float]($y + $size.Height)
                $y = [float]($y + $size.Height)
                continue
            }
            $boxH = [float]($font.GetHeight($graphics) * 1.5)
            if ($line.Align -eq "Pair") {
                $layout += [pscustomobject]@{ Style = $line.Style; Text = $line.Text; Font = $font; Brush = $brush; Y = $y; BoxX = $blockLeft; BoxWidth = $blockW; BoxHeight = $boxH; Format = $nearFormat }
                if ($DetailValueAlign -eq "Column") { $layout += [pscustomobject]@{ Style = $line.Style; Text = [string]$line.Value; Font = $font; Brush = $brush; Y = $y; BoxX = $valueColumnX; BoxWidth = [float]($blockLeft + $blockW - $valueColumnX); BoxHeight = $boxH; Format = $nearFormat } } else { $layout += [pscustomobject]@{ Style = $line.Style; Text = [string]$line.Value; Font = $font; Brush = $brush; Y = $y; BoxX = $blockLeft; BoxWidth = $blockW; BoxHeight = $boxH; Format = $farFormat } }
            } else {
                $layout += [pscustomobject]@{ Style = $line.Style; Text = $line.Text; Font = $font; Brush = $brush; Y = $y; BoxX = $blockLeft; BoxWidth = $blockW; BoxHeight = $boxH; Format = $nearFormat }
            }
            $blockBottom = [float]($y + $font.GetHeight($graphics))
            $y = [float]($y + ($font.GetHeight($graphics) * $LineSpacing))
        }
        # Place the block. Bottom corners end the block above the taskbar. Middle corners center it on a point of the wallpaper picture.
        $placementNote = $Corner
        if ($Corner -like "Bottom*") {
            $taskbarReserve = 0
            if ($AvoidTaskbar) {
                $screenDpi = 96.0
                try { $screenGraphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $screenDpi = [double]$screenGraphics.DpiY; $screenGraphics.Dispose() } catch { $screenDpi = 96.0 }
                $estimatedTaskbar = [int][Math]::Round(48 * $screenDpi / 96.0)
                $reportedTaskbar = 0
                if ($null -ne $bounds -and $null -ne $workArea -and $bounds.Height -eq $height) { $reportedTaskbar = [int]($bounds.Bottom - $workArea.Bottom) }
                $taskbarReserve = [Math]::Max($estimatedTaskbar, $reportedTaskbar)
                Write-Log "Taskbar space kept clear: $taskbarReserve px (Windows reports $reportedTaskbar px, estimate at $screenDpi DPI is $estimatedTaskbar px)"
            }
            $originY = [float]($height - ($MarginBottom * $scale) - $edgePad - $taskbarReserve - $blockBottom)
            if ($originY -lt $edgePad) { $originY = $edgePad }
        } else {
            $originY = [float](($MarginTop * $scale) + $edgePad)
        }
        if ($Corner -like "Middle*") {
            if ($null -ne $baseImage) { $anchorY = [float]((($height - $drawH) / 2) + ($drawH * $MiddlePercent / 100)); $placementNote = "$Corner, centered at $MiddlePercent% of the wallpaper picture's height" } else { $anchorY = [float]($height * $MiddlePercent / 100); $placementNote = "$Corner, centered at $MiddlePercent% of the screen height (no wallpaper picture)" }
            $originY = [float]($anchorY - ($blockBottom / 2))
            $lowestTop = [float]($height - ($MarginBottom * $scale) - $edgePad - $blockBottom)
            if ($originY -gt $lowestTop) { $originY = $lowestTop }
            if ($originY -lt (($MarginTop * $scale) + $edgePad)) { $originY = [float](($MarginTop * $scale) + $edgePad) }
        }
        # Draw pass: backdrop panel first, then the notice badge, then the text
        if ($BackdropPanel -and $layout.Count -gt 0) {
            $panelPath = New-RoundedRectPath -X ([float]($blockLeft - $edgePad)) -Y ([float]($originY - $edgePad)) -W ([float]($blockW + (2 * $edgePad))) -H ([float]($blockBottom + (2 * $edgePad))) -R ([float]($PanelCornerRadius * $scale))
            $panelBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb([int]$PanelFillAlpha, [System.Drawing.ColorTranslator]::FromHtml($PanelFillColor)))
            $graphics.FillPath($panelBrush, $panelPath)
        }
        if ($WarningBadge -and $noticeLines.Count -gt 0) {
            $badgePath = New-RoundedRectPath -X $blockLeft -Y ([float]($originY + $badgeTop)) -W $blockW -H ([float]($badgeBottom - $badgeTop)) -R ([float]($BadgeCornerRadius * $scale))
            $badgeBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml($BadgeFillColor))
            $graphics.FillPath($badgeBrush, $badgePath)
        }
        foreach ($item in $layout) {
            $drawY = [float]($originY + $item.Y)
            if ($item.Style -eq "Warning" -and $WarningBadge) {
                # No shadow inside the badge, it only blurs dark text on a light fill
                $graphics.DrawString($item.Text, $item.Font, $item.Brush, [System.Drawing.RectangleF]::new($item.BoxX, $drawY, $item.BoxWidth, $item.BoxHeight), $item.Format)
            } elseif ($item.Style -eq "Warning" -and $WarningOutline) {
                $textPath = [System.Drawing.Drawing2D.GraphicsPath]::new()
                try {
                    $textPath.AddString($item.Text, $item.Font.FontFamily, [int]$item.Font.Style, [float]$item.Font.Size, [System.Drawing.RectangleF]::new($item.BoxX, $drawY, $item.BoxWidth, $item.BoxHeight), $item.Format)
                    $graphics.DrawPath($outlinePen, $textPath)
                    $graphics.FillPath($item.Brush, $textPath)
                } finally {
                    $textPath.Dispose()
                }
            } else {
                if ($DropShadow) { $graphics.DrawString($item.Text, $item.Font, $shadowBrush, [System.Drawing.RectangleF]::new([float]($item.BoxX + $shadowOffset), [float]($drawY + $shadowOffset), $item.BoxWidth, $item.BoxHeight), $item.Format) }
                $graphics.DrawString($item.Text, $item.Font, $item.Brush, [System.Drawing.RectangleF]::new($item.BoxX, $drawY, $item.BoxWidth, $item.BoxHeight), $item.Format)
            }
        }
        $styleNote = "notice $WarningColor"
        if ($WarningBadge) { $styleNote = "notice badge" } elseif ($WarningOutline) { $styleNote = "notice $WarningColor with outline" }
        if ($BackdropPanel) { $styleNote = "$styleNote, backdrop panel" }
        Write-Log ("Text block: {0} lines, {1:N0} x {2:N0} px, left edge at {3:N0} px, from {4:N0} to {5:N0} px of {6} ({7}, values {8}, {9})" -f $drawnLines, $blockW, $blockBottom, $blockLeft, $originY, ($originY + $blockBottom), $height, $placementNote, $DetailValueAlign, $styleNote)
        # Save under a new name each run, because Windows can keep showing a cached copy of a file with the same name.
        $outFile = Join-Path $OutputFolder ("DesktopInfo_{0}.jpg" -f (Get-Date -Format "yyyyMMddHHmmss"))
        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" } | Select-Object -First 1
        $encParams = [System.Drawing.Imaging.EncoderParameters]::new(1)
        $encParams.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)
        $bitmap.Save($outFile, $codec, $encParams)
        Write-Log "Rendered image saved: $outFile"
        if ($KillBGInfo) { Stop-BGInfo }
        # Fill style, no tiling, then apply. SystemParametersInfo with update and broadcast makes Explorer redraw now.
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WallpaperStyle" -Value "10"
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "TileWallpaper" -Value "0"
        $applied = [DesktopInfoRenderNative]::SystemParametersInfo(20, 0, $outFile, 3)
        if (-not $applied) {
            Write-Log "SystemParametersInfo failed. Win32 error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            return 1
        }
        Write-Log "Wallpaper applied."
        $recordedWallpaper = [string](Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "Wallpaper" -ErrorAction SilentlyContinue).Wallpaper
        if ($recordedWallpaper -eq $outFile) { Write-Log "Windows recorded the new wallpaper path." } else { Write-Log "WARNING: Windows recorded the wallpaper as '$recordedWallpaper' instead of $outFile." }
        # Guard window: if BGInfo or a late theme step replaces the wallpaper in the next few seconds, put it back (up to 3 times).
        if ($WallpaperGuardSeconds -gt 0) {
            Write-Log "Guarding the wallpaper for $WallpaperGuardSeconds seconds."
            $guardEnd = (Get-Date).AddSeconds($WallpaperGuardSeconds)
            $reapplyCount = 0
            while ((Get-Date) -lt $guardEnd) {
                Start-Sleep -Seconds 1
                if ($KillBGInfo) { Stop-BGInfo }
                $currentWallpaper = [string](Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "Wallpaper" -ErrorAction SilentlyContinue).Wallpaper
                if ($currentWallpaper -ne $outFile -and $reapplyCount -lt 3) {
                    $reapplyCount++
                    Write-Log "Wallpaper was changed to '$currentWallpaper' by something else. Reapplying (attempt $reapplyCount of 3)."
                    [void][DesktopInfoRenderNative]::SystemParametersInfo(20, 0, $outFile, 3)
                }
            }
            if ($reapplyCount -eq 0) { Write-Log "Nothing changed the wallpaper during the guard window." }
        }
        # Delete older renders. Only the one now on screen is kept.
        Get-ChildItem -Path $OutputFolder -Filter "DesktopInfo_*.jpg" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $outFile } | Remove-Item -Force -ErrorAction SilentlyContinue
        return 0
    } catch {
        Write-Log "Render failed: $($_.Exception.Message)"
        return 1
    } finally {
        foreach ($obj in @($encParams, $warnFormat, $messageFormat, $farFormat, $centerFormat, $nearFormat, $badgePath, $panelPath, $badgeBrush, $panelBrush, $badgeTextBrush, $outlinePen, $shadowBrush, $warningBrush, $textBrush, $warningFont, $detailFont, $locationFont, $titleFont, $baseImage, $baseStream, $graphics, $bitmap)) { if ($null -ne $obj) { $obj.Dispose() } }
    }
}
# Only one render at a time in a session. The display watcher and the scheduled task can each start one, for example
# when a docked laptop is unlocked as its monitors change. Two runs at once could delete each other's image. A run
# waits up to 3 minutes for the other to finish, then draws anyway.
$renderMutex = $null
$renderExit = 1
try {
    $renderMutex = New-Object System.Threading.Mutex($false, "Local\__ORGFOLDER__-DesktopInfo-Render")
    try { [void]$renderMutex.WaitOne(180000) } catch [System.Threading.AbandonedMutexException] { }
    $renderExit = Invoke-UpdateDesktopInfo
} finally {
    if ($null -ne $renderMutex) { try { $renderMutex.ReleaseMutex() } catch { }; $renderMutex.Dispose() }
}
exit $renderExit
'@
    # ===== Embedded script 3 of 4: Update-LockScreen.ps1 (SYSTEM, 45 s after startup) =====
    $LockScreenScript = @'
# Update-LockScreen.ps1
# Version: 1.0.0
# Author: Jeremy Green
# Copyright (c) 2026 Jeremy Green
# SPDX-License-Identifier: MIT
# Source: https://github.com/jeremydgreen/Action1-Tools
# Shared under the MIT License. Keep this header in any copy or modified version.
# Built with AI assistance; designed, tested and maintained by the author.
# Part of Desktop Info 1.0.0. Installed by Deploy-DesktopInfo.ps1, which holds the master copy. Edit it there.
#
# WHAT IT DOES
# Runs as SYSTEM from the DesktopInfo LockScreen task 45 seconds after each startup. Draws the location, host name and,
# when it applies, the two-line data loss notice in a bordered panel over the lock screen base image, then points the lock screen
# at the result through PersonalizationCSP and the Personalization policy. Text and placement come from DesktopInfo.json,
# so the lock screen always matches the desktop.
# A run whose content, screen size and base image match the last render (LockScreen.sig) changes nothing, and the two
# newest renders are kept, so LogonUI never points at a missing file. Also turns off Windows Spotlight features.
# Font sizes are points as on a 1080p screen and scale with the real resolution. Margins and padding are pixels at 1080p.
# Exit code 0 when the lock screen was rendered and applied (or nothing changed), 1 when something failed.
#
# Everything runs inside this function and logs with Write-Log, which writes to the screen and LockScreen.log.
function Invoke-UpdateLockScreen {
    # ===== Editable settings =====
    $ConfigPath = "C:\Windows\Web\__ORGFOLDER__\DesktopInfo\DesktopInfo.json"
    $BaseImagePath = "C:\Windows\Web\__ORGFOLDER__\__LOCKSCREENFILE__"
    $OutputFolder = "C:\Windows\Web\__ORGFOLDER__\LockScreen"
    $StatusFolder = "C:\Windows\Web\__ORGFOLDER__\DesktopInfo"
    $LogPath = "C:\Windows\Web\__ORGFOLDER__\DesktopInfo\Logs\LockScreen.log"
    # The log is trimmed to half this many lines when it grows past it
    $LogMaxLines = 400
    # How long to wait for status files written since the last boot
    $StatusWaitSeconds = 90
    $FontName = "Segoe UI"
    $TitleFontSize = 16
    # The location is the top line when there is no title, so it uses the title size
    $LocationFontSize = 16
    $HostFontSize = 22
    # The notice lines are plain white text. White on the panel measures about 15:1, well above the 4.5:1 minimum.
    $WarningFontSize = 12
    $WarningBold = $false
    $TextColor = "#FFFFFF"
    $WarningColor = "#FFFFFF"
    $PanelFillColor = "#000000"
    # 0 turns the panel fill off, 255 is solid
    $PanelFillAlpha = 120
    $BorderColor = "#143778"
    # 0 turns the border off
    $BorderThickness = 3
    # 0 gives square corners
    $CornerRadius = 12
    $PanelPadding = 18
    $LineGap = 6
    $DropShadow = $true
    # Distance from the screen edges to the panel
    $MarginX = 60
    # 40 keeps the panel clear of the lock screen clock. A taller panel needs a recheck.
    $MarginY = 40
    $JpegQuality = 92
    # Take ownership of a policy key if SYSTEM is denied write access to it
    $RepairRegistryAcl = $true
    # =============================
    # Keep LockScreen.log short. It is appended at every startup, so it is cut to the newest half when it passes $LogMaxLines.
    $logFolder = Split-Path -Path $LogPath -Parent
    if (-not (Test-Path -LiteralPath $logFolder)) { New-Item -Path $logFolder -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
    try {
        if ((Test-Path -LiteralPath $LogPath) -and $LogMaxLines -gt 0) {
            $existingLog = @(Get-Content -LiteralPath $LogPath -ErrorAction Stop)
            if ($existingLog.Count -gt $LogMaxLines) { $existingLog | Select-Object -Last ([int]($LogMaxLines / 2)) | Set-Content -LiteralPath $LogPath -Encoding UTF8 -ErrorAction Stop }
        }
    } catch {
        Write-Host "Could not trim ${LogPath}: $($_.Exception.Message)"
    }
    # Write-Log sends each line to the screen and LockScreen.log with a time stamp. Nothing may go to the output stream in
    # this function, because it would become part of the exit code.
    function Write-Log { param([string]$Text) Write-Host $Text; Add-Content -LiteralPath $LogPath -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text) -Encoding UTF8 -ErrorAction SilentlyContinue }
    Write-Log "Update-LockScreen run as $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME"
    # The lock screen policy is machine-wide, so this must run as SYSTEM or an administrator.
    $principal = [System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Log "This script must run as SYSTEM or an administrator, because it writes machine-wide lock screen policy."; return 1 }
    # ----- Shared settings -----
    # Location, title, notice wording and placement come from the file the deployer wrote, so both screens say the same thing.
    $config = $null
    try { $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { Write-Log "Could not read the shared settings file ${ConfigPath}: $($_.Exception.Message)"; return 1 }
    Write-Log "Shared settings loaded from $ConfigPath (version $($config.Version))"
    $titleText = [string]$config.TitleText
    $location = [string]$config.DefaultLocation
    foreach ($rule in @($config.LocationRules | Where-Object { $null -ne $_ })) {
        if ([string]::IsNullOrWhiteSpace([string]$rule.Prefix)) { continue }
        if ($env:COMPUTERNAME.StartsWith([string]$rule.Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $location = [string]$rule.Label
            break
        }
    }
    Write-Log "Hostname $env:COMPUTERNAME matched location: '$location'"
    $corner = [string]$config.LockScreenCorner
    if (@("TopRight", "TopLeft", "BottomRight", "BottomLeft") -notcontains $corner) {
        Write-Log "Unknown lock screen corner '$corner'. Using TopRight."
        $corner = "TopRight"
    }
    # ----- Device status -----
    # Only trust status files written since this boot, so a stale file from an earlier session can never show the wrong notice.
    # The status task runs at the same startup, so this waits up to $StatusWaitSeconds for it.
    $bootTime = $null
    try { $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { Write-Log "Could not read last boot time: $($_.Exception.Message)" }
    $statusDeadline = (Get-Date).AddSeconds($StatusWaitSeconds)
    # Read-StatusFile returns the first line of a status file once it has been written since this boot, or $null when the
    # wait runs out. A file from an earlier boot is never trusted.
    function Read-StatusFile {
        param([string]$Path)
        do {
            if (Test-Path -LiteralPath $Path) {
                $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
                if ($null -ne $item -and ($null -eq $bootTime -or $item.LastWriteTime -gt $bootTime)) { return ([string](Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction SilentlyContinue)).Trim() }
            }
            if ((Get-Date) -lt $statusDeadline) { Start-Sleep -Seconds 2 }
        } while ((Get-Date) -lt $statusDeadline)
        return $null
    }
    $uwfStatus = Read-StatusFile -Path (Join-Path $StatusFolder "UWFStatus.txt")
    if ($null -eq $uwfStatus) { $uwfStatus = "Unknown"; Write-Log "No UWF status written since last boot. Treating it as Unknown." }
    $sharedPCStatus = Read-StatusFile -Path (Join-Path $StatusFolder "SharedPCStatus.txt")
    if ($null -eq $sharedPCStatus) { $sharedPCStatus = "Unknown"; Write-Log "No Shared PC status written since last boot. Treating it as Unknown." }
    $uwfWarn = @($config.UWFWarnStates) -contains $uwfStatus
    $sharedPCWarn = @($config.SharedPCWarnStates) -contains $sharedPCStatus
    # Two lines: when files are deleted, then what to do. The strongest true statement wins: sign-out, then restart (UWF),
    # then "any time" (Shared PC keeps profiles and deletes them later). A restart always signs the user out first.
    $noticeKept = [string]$config.NoticeSharedPCKept
    if ([string]::IsNullOrWhiteSpace($noticeKept)) { $noticeKept = [string]$config.NoticeSharedPC }
    $noticeCause = ""
    if ($sharedPCWarn -and $sharedPCStatus -eq "DeleteAtSignOut") { $noticeCause = [string]$config.NoticeSharedPC } elseif ($uwfWarn) { $noticeCause = [string]$config.NoticeUWF } elseif ($sharedPCWarn) { $noticeCause = $noticeKept }
    $lockWarningLines = @(@($noticeCause, [string]$config.NoticeAction) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    Write-Log "UWF: $uwfStatus  Shared PC: $sharedPCStatus  Warning shown: $($uwfWarn -or $sharedPCWarn)"
    # ----- Lines -----
    # Location (and optional title), host name, then the notice.
    $lines = @()
    if (-not [string]::IsNullOrWhiteSpace($titleText)) { $lines += [pscustomobject]@{ Text = $titleText.Trim(); Style = "Title" } }
    if (-not [string]::IsNullOrWhiteSpace($location)) { $lines += [pscustomobject]@{ Text = $location.Trim(); Style = "Location" } }
    $lines += [pscustomobject]@{ Text = $env:COMPUTERNAME; Style = "Host" }
    if ($uwfWarn -or $sharedPCWarn) {
        foreach ($warnLine in $lockWarningLines) { $lines += [pscustomobject]@{ Text = $warnLine; Style = "Warning" } }
    }
    # ----- Skip when nothing changed -----
    # Re-rendering swaps the file the lock screen points at and clears LogonUI's cache. Doing that while a session is open
    # leaves the lock screen black after the user signs out, so a run with the same content, screen size and base image
    # changes nothing. The fingerprint lives in the lock screen folder, which UWF keeps across restarts.
    $sigFile = Join-Path $OutputFolder "LockScreen.sig"
    $baseInfo = Get-Item -LiteralPath $BaseImagePath -ErrorAction SilentlyContinue
    $resSig = ""
    try { $vcSig = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Sort-Object { [int64]$_.CurrentHorizontalResolution * [int64]$_.CurrentVerticalResolution } -Descending | Select-Object -First 1; if ($null -ne $vcSig) { $resSig = "{0}x{1}" -f $vcSig.CurrentHorizontalResolution, $vcSig.CurrentVerticalResolution } } catch { $resSig = "" }
    $baseSig = "nobase"
    if ($null -ne $baseInfo) { $baseSig = "{0}|{1}" -f $baseInfo.Length, $baseInfo.LastWriteTimeUtc.Ticks }
    $sigParts = @("render 1.0.0", $corner, $resSig, $baseSig) + @($lines | ForEach-Object { "{0}={1}" -f $_.Style, $_.Text })
    $sigHasher = [System.Security.Cryptography.SHA256]::Create()
    $sigHash = [System.BitConverter]::ToString($sigHasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($sigParts -join "|")))).Replace("-", "")
    $sigHasher.Dispose()
    $prevSig = $null
    if (Test-Path -LiteralPath $sigFile) { try { $prevSig = Get-Content -LiteralPath $sigFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $prevSig = $null } }
    $cspNow = [string](Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP" -Name "LockScreenImagePath" -ErrorAction SilentlyContinue).LockScreenImagePath
    if ($null -ne $prevSig -and [string]$prevSig.Hash -eq $sigHash -and -not [string]::IsNullOrWhiteSpace([string]$prevSig.Path) -and (Test-Path -LiteralPath ([string]$prevSig.Path)) -and $cspNow -eq [string]$prevSig.Path) {
        Write-Log "Nothing changed since the last render. The lock screen stays on $($prevSig.Path)."
        return 0
    }
    if ($null -ne $prevSig) { Write-Log "Content, screen size, base image or pointer changed since the last render. Rendering again." } else { Write-Log "No earlier render recorded. Rendering." }
    # ----- Render -----
    # Draw at the real display resolution so nothing is cropped or stretched. Every drawing object is disposed in finally.
    function New-RoundedRectPath {
        param([float]$X, [float]$Y, [float]$W, [float]$H, [float]$R)
        $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
        if ($R -le 0 -or $W -le ($R * 2) -or $H -le ($R * 2)) {
            $path.AddRectangle([System.Drawing.RectangleF]::new($X, $Y, $W, $H))
            return $path
        }
        $d = [float]($R * 2)
        $path.AddArc($X, $Y, $d, $d, [float]180, [float]90)
        $path.AddArc([float]($X + $W - $d), $Y, $d, $d, [float]270, [float]90)
        $path.AddArc([float]($X + $W - $d), [float]($Y + $H - $d), $d, $d, [float]0, [float]90)
        $path.AddArc($X, [float]($Y + $H - $d), $d, $d, [float]90, [float]90)
        $path.CloseFigure()
        return $path
    }
    $outputPath = $null
    $baseStream = $null
    $baseImage = $null
    $image = $null
    $graphics = $null
    $titleFont = $null
    $locationFont = $null
    $hostFont = $null
    $warningFont = $null
    $textBrush = $null
    $warningBrush = $null
    $shadowBrush = $null
    $fillBrush = $null
    $borderPen = $null
    $format = $null
    $panelPath = $null
    $encParams = $null
    try {
        Add-Type -AssemblyName System.Drawing
        $baseBytes = [System.IO.File]::ReadAllBytes($BaseImagePath)
        $baseStream = [System.IO.MemoryStream]::new($baseBytes)
        $baseImage = [System.Drawing.Image]::FromStream($baseStream)
        Write-Log "Base image $BaseImagePath is $($baseImage.Width)x$($baseImage.Height)"
        # Resolution: the video controller first, then the last mode the graphics stack recorded, then the image size.
        $canvasW = $baseImage.Width
        $canvasH = $baseImage.Height
        $sizeSource = "base image"
        $res = $null
        try {
            $vc = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | Where-Object { $_.CurrentHorizontalResolution -gt 0 -and $_.CurrentVerticalResolution -gt 0 } | Sort-Object { [int64]$_.CurrentHorizontalResolution * [int64]$_.CurrentVerticalResolution } -Descending | Select-Object -First 1
            if ($null -ne $vc) { $res = [pscustomobject]@{ Width = [int]$vc.CurrentHorizontalResolution; Height = [int]$vc.CurrentVerticalResolution; Source = "Win32_VideoController" } }
        } catch {
            Write-Log "Win32_VideoController query failed: $($_.Exception.Message)"
        }
        if ($null -eq $res) {
            # Last mode recorded by the graphics stack. Covers an early boot where the driver has not reported a mode yet.
            foreach ($gdKey in @(Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration" -Recurse -ErrorAction SilentlyContinue)) {
                $gdProps = Get-ItemProperty -Path $gdKey.PSPath -ErrorAction SilentlyContinue
                if ($null -eq $gdProps) { continue }
                $cx = $gdProps.'PrimSurfSize.cx'
                $cy = $gdProps.'PrimSurfSize.cy'
                if ($cx -gt 0 -and $cy -gt 0 -and ($null -eq $res -or ([int64]$cx * [int64]$cy) -gt ([int64]$res.Width * [int64]$res.Height))) { $res = [pscustomobject]@{ Width = [int]$cx; Height = [int]$cy; Source = "GraphicsDrivers registry" } }
            }
        }
        if ($null -ne $res -and $res.Width -ge 640 -and $res.Height -ge 480 -and $res.Width -le 16384 -and $res.Height -le 16384) {
            $canvasW = $res.Width
            $canvasH = $res.Height
            $sizeSource = $res.Source
        } else {
            Write-Log "Could not read a usable display resolution. Using the base image size."
        }
        Write-Log "Rendering at ${canvasW}x${canvasH} (size from $sizeSource), panel in the $corner corner"
        # Scale the base image to fill the screen, centered, then size the fonts for this resolution.
        $image = [System.Drawing.Bitmap]::new($canvasW, $canvasH)
        $graphics = [System.Drawing.Graphics]::FromImage($image)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $fill = [Math]::Max($canvasW / $baseImage.Width, $canvasH / $baseImage.Height)
        $drawW = $baseImage.Width * $fill
        $drawH = $baseImage.Height * $fill
        $graphics.DrawImage($baseImage, [float](($canvasW - $drawW) / 2), [float](($canvasH - $drawH) / 2), [float]$drawW, [float]$drawH)
        $sf = $canvasH / 1080.0
        $ptToPx = (96.0 / 72.0) * $sf
        $titleFont = [System.Drawing.Font]::new($FontName, [float]($TitleFontSize * $ptToPx), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $locationFont = [System.Drawing.Font]::new($FontName, [float]($LocationFontSize * $ptToPx), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $hostFont = [System.Drawing.Font]::new($FontName, [float]($HostFontSize * $ptToPx), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        if ($WarningBold) { $warningStyle = [System.Drawing.FontStyle]::Bold } else { $warningStyle = [System.Drawing.FontStyle]::Regular }
        $warningFont = [System.Drawing.Font]::new($FontName, [float]($WarningFontSize * $ptToPx), $warningStyle, [System.Drawing.GraphicsUnit]::Pixel)
        $textBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml($TextColor))
        $warningBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml($WarningColor))
        $shadowBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(160, 0, 0, 0))
        $shadowOffset = [float]([Math]::Max(1, [Math]::Round(2 * $sf)))
        $rightAligned = ($corner -like "*Right")
        $format = [System.Drawing.StringFormat]::GenericTypographic.Clone()
        $format.FormatFlags = $format.FormatFlags -bor [System.Drawing.StringFormatFlags]::NoWrap -bor [System.Drawing.StringFormatFlags]::NoClip
        if ($rightAligned) { $format.Alignment = [System.Drawing.StringAlignment]::Far } else { $format.Alignment = [System.Drawing.StringAlignment]::Near }
        # Measure every line so the panel fits the text
        $gap = [float]([Math]::Max(2, [Math]::Round($LineGap * $sf)))
        $measured = @()
        $maxTextW = [float]0
        $totalTextH = [float]0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $brush = $textBrush
            if ($lines[$i].Style -eq "Title") { $font = $titleFont } elseif ($lines[$i].Style -eq "Location") { $font = $locationFont } elseif ($lines[$i].Style -eq "Host") { $font = $hostFont } else { $font = $warningFont; $brush = $warningBrush }
            $size = $graphics.MeasureString($lines[$i].Text, $font, [System.Drawing.PointF]::new(0, 0), $format)
            $lineH = [float]$font.GetHeight($graphics)
            $measured += [pscustomobject]@{ Text = $lines[$i].Text; Font = $font; Brush = $brush; Height = $lineH }
            if ($size.Width -gt $maxTextW) { $maxTextW = [float]$size.Width }
            $totalTextH = [float]($totalTextH + $lineH)
            if ($i -lt ($lines.Count - 1)) { $totalTextH = [float]($totalTextH + $gap) }
        }
        $maxTextW = [float]($maxTextW + 2)
        # Size and place the panel in the chosen corner, then draw its fill and border.
        $pad = [float]([Math]::Round($PanelPadding * $sf))
        $marginXpx = [float]([Math]::Round($MarginX * $sf))
        $marginYpx = [float]([Math]::Round($MarginY * $sf))
        $radius = [float]([Math]::Max(0, [Math]::Round($CornerRadius * $sf)))
        $panelW = [float]($maxTextW + ($pad * 2))
        $panelH = [float]($totalTextH + ($pad * 2))
        if ($rightAligned) { $panelLeft = [float]($canvasW - $marginXpx - $panelW) } else { $panelLeft = $marginXpx }
        if ($corner -like "Bottom*") { $panelTop = [float]($canvasH - $marginYpx - $panelH) } else { $panelTop = $marginYpx }
        if ($panelLeft -lt 0) { Write-Log "WARNING: the text is wider than the screen allows. Shorten the text or reduce the font sizes."; $panelLeft = [float]0 }
        if ($panelTop -lt 0) { $panelTop = [float]0 }
        $panelPath = New-RoundedRectPath -X $panelLeft -Y $panelTop -W $panelW -H $panelH -R $radius
        if ($PanelFillAlpha -gt 0) {
            $fillBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb([int]$PanelFillAlpha, [System.Drawing.ColorTranslator]::FromHtml($PanelFillColor)))
            $graphics.FillPath($fillBrush, $panelPath)
        }
        if ($BorderThickness -gt 0) {
            $borderPen = [System.Drawing.Pen]::new([System.Drawing.ColorTranslator]::FromHtml($BorderColor), [float]([Math]::Max(1, [Math]::Round($BorderThickness * $sf))))
            $borderPen.Alignment = [System.Drawing.Drawing2D.PenAlignment]::Inset
            $graphics.DrawPath($borderPen, $panelPath)
        }
        # Draw each line with a drop shadow for contrast against any picture.
        $textLeft = [float]($panelLeft + $pad)
        $y = [float]($panelTop + $pad)
        foreach ($item in $measured) {
            $rectH = [float]($item.Height * 1.5)
            if ($DropShadow) { $graphics.DrawString($item.Text, $item.Font, $shadowBrush, [System.Drawing.RectangleF]::new([float]($textLeft + $shadowOffset), [float]($y + $shadowOffset), $maxTextW, $rectH), $format) }
            $graphics.DrawString($item.Text, $item.Font, $item.Brush, [System.Drawing.RectangleF]::new($textLeft, $y, $maxTextW, $rectH), $format)
            $y = [float]($y + $item.Height + $gap)
        }
        if (-not (Test-Path -LiteralPath $OutputFolder)) { New-Item -Path $OutputFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        # A fresh file name each time, so Windows cannot keep serving a cached render
        $candidatePath = Join-Path $OutputFolder ("Active_Lockscreen_{0}.jpg" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" } | Select-Object -First 1
        $encParams = [System.Drawing.Imaging.EncoderParameters]::new(1)
        $encParams.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)
        $image.Save($candidatePath, $codec, $encParams)
        $outputPath = $candidatePath
        Write-Log "Rendered lock screen image: $outputPath"
    } catch {
        Write-Log "Render failed: $($_.Exception.Message)"
    } finally {
        foreach ($obj in @($encParams, $panelPath, $format, $borderPen, $fillBrush, $shadowBrush, $warningBrush, $textBrush, $warningFont, $hostFont, $locationFont, $titleFont, $graphics, $image, $baseImage, $baseStream)) { if ($null -ne $obj) { $obj.Dispose() } }
    }
    # No new image means nothing to point at. The previous lock screen stays as it was.
    if ($null -eq $outputPath) { return 1 }
    # ----- Point the lock screen at the new image -----
    # Each value is written on its own, so one denied key does not stop the rest. A denied key can be repaired by taking
    # ownership for SYSTEM ($RepairRegistryAcl). The ACL repair does not remove explicit Deny entries.
    function Repair-RegistryKeyAcl {
        param([string]$KeyPath)
        try {
            $sub = $KeyPath -replace '^HKLM:\\', ''
            $systemSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18")
            $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
            if ($null -eq $key) { Write-Log "ACL repair: could not open $KeyPath to take ownership"; return $false }
            $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::None)
            $acl.SetOwner($systemSid)
            $key.SetAccessControl($acl)
            $key.Close()
            $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::ChangePermissions)
            if ($null -eq $key) { Write-Log "ACL repair: took ownership of $KeyPath but could not reopen it to set permissions"; return $false }
            $acl = $key.GetAccessControl()
            $rule = [System.Security.AccessControl.RegistryAccessRule]::new($systemSid, [System.Security.AccessControl.RegistryRights]::FullControl, [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit", [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
            $acl.SetAccessRule($rule)
            $key.SetAccessControl($acl)
            $key.Close()
            Write-Log "ACL repair: SYSTEM now owns $KeyPath and has full control"
            return $true
        } catch {
            Write-Log "ACL repair failed on ${KeyPath}: $($_.Exception.Message)"
            return $false
        }
    }
    # Set-PolicyValue writes one registry value. If SYSTEM is denied, it repairs the key's permissions once and tries again.
    function Set-PolicyValue {
        param([string]$KeyPath, [string]$Name, $Value, [string]$ValueType)
        try {
            if (-not (Test-Path -Path $KeyPath)) { New-Item -Path $KeyPath -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $KeyPath -Name $Name -Value $Value -Type $ValueType -ErrorAction Stop
            return $true
        } catch {
            $firstError = $_.Exception.Message
            if (-not $RepairRegistryAcl) { Write-Log "Policy write failed: $KeyPath [$Name]: $firstError"; return $false }
            Write-Log "Policy write failed: $KeyPath [$Name]: $firstError. Trying an ACL repair."
            if (Repair-RegistryKeyAcl -KeyPath $KeyPath) {
                try {
                    if (-not (Test-Path -Path $KeyPath)) { New-Item -Path $KeyPath -Force -ErrorAction Stop | Out-Null }
                    Set-ItemProperty -Path $KeyPath -Name $Name -Value $Value -Type $ValueType -ErrorAction Stop
                    Write-Log "Recovered after ACL repair: $KeyPath [$Name]"
                    return $true
                } catch {
                    Write-Log "Still failing after ACL repair: $KeyPath [$Name]: $($_.Exception.Message)"
                    return $false
                }
            }
            return $false
        }
    }
    $cspPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
    $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
    $cloudPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
    $cspStatusOk = Set-PolicyValue -KeyPath $cspPath -Name "LockScreenImageStatus" -Value 1 -ValueType "DWord"
    $cspPathOk = Set-PolicyValue -KeyPath $cspPath -Name "LockScreenImagePath" -Value $outputPath -ValueType "String"
    $cspUrlOk = Set-PolicyValue -KeyPath $cspPath -Name "LockScreenImageUrl" -Value $outputPath -ValueType "String"
    $policyOk = Set-PolicyValue -KeyPath $policyPath -Name "LockScreenImage" -Value $outputPath -ValueType "String"
    $spotlightOk = Set-PolicyValue -KeyPath $cloudPath -Name "DisableWindowsSpotlightFeatures" -Value 1 -ValueType "DWord"
    $results = @($cspStatusOk, $cspPathOk, $cspUrlOk, $policyOk, $spotlightOk)
    $okCount = @($results | Where-Object { $_ -eq $true }).Count
    Write-Log "Policy writes: $okCount of $($results.Count) succeeded"
    # Clear LogonUI's cached copies so the new image is picked up
    $cacheRoot = "C:\ProgramData\Microsoft\Windows\SystemData\S-1-5-18\ReadOnly"
    if (Test-Path -LiteralPath $cacheRoot) {
        $cleared = 0
        $clearFailed = 0
        foreach ($cacheDir in @(Get-ChildItem -LiteralPath $cacheRoot -Directory -Filter "LockScreen_*" -ErrorAction SilentlyContinue)) {
            foreach ($cacheFile in @(Get-ChildItem -LiteralPath $cacheDir.FullName -File -Recurse -ErrorAction SilentlyContinue)) {
                try { Remove-Item -LiteralPath $cacheFile.FullName -Force -ErrorAction Stop; $cleared++ } catch { $clearFailed++ }
            }
        }
        Write-Log "Cached lock screen renders: $cleared removed, $clearFailed could not be removed"
        if ($clearFailed -gt 0) { Write-Log "A failed cache clear means the lock screen may show the previous image until the next restart." }
    }
    # The three PersonalizationCSP values are the ones that actually change the lock screen
    if (-not ($cspStatusOk -and $cspPathOk -and $cspUrlOk)) {
        Write-Log "CRITICAL: PersonalizationCSP could not be written. The new image exists but nothing points at it, so Windows keeps showing the previous lock screen. Previous renders were kept."
        return 1
    }
    # Only now that the lock screen points at the new image is it safe to tidy up. The newest two renders stay (this one and
    # the previous one), so LogonUI always has a file to fall back on until it picks up the new pointer.
    Get-ChildItem -LiteralPath $OutputFolder -Filter "Active_Lockscreen_*.jpg" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 2 | Remove-Item -Force -ErrorAction SilentlyContinue
    # Record this render so the next startup can skip it when nothing changed.
    try { [ordered]@{ Hash = $sigHash; Path = $outputPath; WrittenUtc = (Get-Date).ToUniversalTime().ToString("o") } | ConvertTo-Json | Set-Content -LiteralPath $sigFile -Encoding ASCII -Force -ErrorAction Stop } catch { Write-Log "Could not write ${sigFile}: $($_.Exception.Message). The next startup renders again." }
    Write-Log "Lock screen policy applied: $outputPath"
    return 0
}
# Pass the function's result to Task Scheduler as the exit code
exit (Invoke-UpdateLockScreen)
'@
    # ===== Embedded script 4 of 4: Watch-DesktopDisplay.ps1 (signed-in user, whole session, laptops by default) =====
    $WatchScript = @'
# Watch-DesktopDisplay.ps1
# Version: 1.0.0
# Author: Jeremy Green
# Copyright (c) 2026 Jeremy Green
# SPDX-License-Identifier: MIT
# Source: https://github.com/jeremydgreen/Action1-Tools
# Shared under the MIT License. Keep this header in any copy or modified version.
# Built with AI assistance; designed, tested and maintained by the author.
# Part of Desktop Info 1.0.0. Installed by Deploy-DesktopInfo.ps1, which holds the master copy. Edit it there.
#
# WHAT IT DOES
# Runs hidden as the signed-in user for the whole session, from the DesktopInfo DisplayWatch task (laptops only by
# default, see $RedrawOnDisplayChange in the deployer). Every few seconds it reads the monitor layout: how many monitors,
# the primary monitor's size, and the size and position of the whole desktop. When the layout changes, for example the
# lid of a docked laptop is closed or the laptop is docked or undocked, it waits until the layout holds steady and then
# runs Update-DesktopInfo.ps1 once, so the wallpaper is redrawn at the new primary monitor's size.
# It reads the layout directly instead of waiting for a Windows event, because which events fire on a lid close or dock
# change differs between models and drivers. Reading the layout costs almost nothing and works the same everywhere.
# A layout that changes and then changes back, such as a dock that flickers, does not cause a redraw.
# It runs until sign-out. It exits 0 when another copy is already running in this session, 1 when it cannot start.
#
# Everything runs inside this function and logs with Write-Log, which writes to the screen and DisplayWatch.log.
function Invoke-WatchDesktopDisplay {
    # ===== Editable settings =====
    $RendererPath = "C:\Windows\Web\__ORGFOLDER__\DesktopInfo\Update-DesktopInfo.ps1"
    $OutputFolder = Join-Path $env:LOCALAPPDATA "__ORGFOLDER__\DesktopInfo"
    # How often to read the monitor layout
    $PollSeconds = 5
    # How long a new layout must stay the same before redrawing. Docking can switch monitors on one at a time.
    $SettleSeconds = 10
    # The log is cut to the newest half when it grows past this many lines
    $LogMaxLines = 200
    # =============================
    # Same two checks as the renderer: it needs Add-Type, and it must run as the user whose desktop it redraws.
    if ($ExecutionContext.SessionState.LanguageMode -ne "FullLanguage") { Write-Host "PowerShell is running in $($ExecutionContext.SessionState.LanguageMode). The display watcher needs FullLanguage."; return 1 }
    if ([System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { Write-Host "The display watcher must run as the signed-in user, not SYSTEM."; return 1 }
    if (-not (Test-Path -LiteralPath $OutputFolder)) { New-Item -Path $OutputFolder -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
    $logPath = Join-Path $OutputFolder "DisplayWatch.log"
    # Write-Log sends each line to the screen and DisplayWatch.log with a time stamp, and keeps the log short. A sign-in task
    # has no visible console, so the log file is the only record.
    function Write-Log {
        param([string]$Text)
        Write-Host $Text
        Add-Content -LiteralPath $logPath -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text) -Encoding UTF8 -ErrorAction SilentlyContinue
        try { $current = @(Get-Content -LiteralPath $logPath -ErrorAction Stop); if ($current.Count -gt $LogMaxLines) { $current | Select-Object -Last ([int]($LogMaxLines / 2)) | Set-Content -LiteralPath $logPath -Encoding UTF8 -ErrorAction Stop } } catch { }
    }
    # One watcher per session. The task can start a second copy, for example when the install starts it for someone who
    # is already signed in. The second copy finds the first one holding this name and exits.
    $single = New-Object System.Threading.Mutex($false, "Local\__ORGFOLDER__-DesktopInfo-DisplayWatch")
    $owned = $false
    try { $owned = $single.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { Write-Log "Another display watcher is already running in this session. Exiting."; $single.Dispose(); return 0 }
    try {
        # GetSystemMetrics reads the live layout every time. The .NET Screen class caches it and can miss changes in a
        # process without a window. DPI awareness makes the numbers real pixels, the same way the renderer measures.
        if (-not ([System.Management.Automation.PSTypeName]"DesktopInfoDisplayWatchNative").Type) {
            Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class DesktopInfoDisplayWatchNative { [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex); [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
        }
        [void][DesktopInfoDisplayWatchNative]::SetProcessDPIAware()
        # Monitor count (80), primary width and height (0, 1), and the whole desktop's left, top, width and height (76 to 79)
        $readLayout = { "{0} monitor(s), primary {1}x{2}, desktop {5}x{6} at {3},{4}" -f [DesktopInfoDisplayWatchNative]::GetSystemMetrics(80), [DesktopInfoDisplayWatchNative]::GetSystemMetrics(0), [DesktopInfoDisplayWatchNative]::GetSystemMetrics(1), [DesktopInfoDisplayWatchNative]::GetSystemMetrics(76), [DesktopInfoDisplayWatchNative]::GetSystemMetrics(77), [DesktopInfoDisplayWatchNative]::GetSystemMetrics(78), [DesktopInfoDisplayWatchNative]::GetSystemMetrics(79) }
        $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $drawnLayout = & $readLayout
        Write-Log "Display watcher started for $env:USERDOMAIN\$env:USERNAME. Layout: $drawnLayout"
        while ($true) {
            Start-Sleep -Seconds $PollSeconds
            $seen = & $readLayout
            if ($seen -eq $drawnLayout) { continue }
            # Wait until the layout stops changing. Every change restarts the wait.
            $steadySince = Get-Date
            while (((Get-Date) - $steadySince).TotalSeconds -lt $SettleSeconds) {
                Start-Sleep -Seconds 1
                $check = & $readLayout
                if ($check -ne $seen) { $seen = $check; $steadySince = Get-Date }
            }
            if ($seen -eq $drawnLayout) { Write-Log "Layout changed and changed back to [$drawnLayout]. No redraw needed."; continue }
            Write-Log "Layout changed from [$drawnLayout] to [$seen]. Redrawing the desktop."
            # Run the renderer inside this hidden console, so no window appears. The renderer takes the render lock, so it
            # waits if the scheduled task is drawing at the same moment (for example a docked laptop being unlocked).
            $null = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File $RendererPath 2>&1
            $renderCode = $LASTEXITCODE
            Write-Log "Redraw finished with exit code $renderCode. Details are in DesktopInfo.log."
            $drawnLayout = $seen
        }
    } finally {
        try { $single.ReleaseMutex() } catch { }
        $single.Dispose()
    }
    return 0
}
# Pass the function's result to Task Scheduler as the exit code
exit (Invoke-WatchDesktopDisplay)
'@
    # ===== End of embedded scripts =====
    # Fixed layout, built from $OrgFolder. The embedded scripts get the same values when they are written to disk (the
    # Scripts stage swaps their __ORGFOLDER__, __WALLPAPERFILE__ and __LOCKSCREENFILE__ placeholders for the settings).
    $RootFolder = "C:\Windows\Web\$OrgFolder"
    $ScriptFolder = "C:\Windows\Web\$OrgFolder\DesktopInfo"
    $LockScreenFolder = "C:\Windows\Web\$OrgFolder\LockScreen"
    $LogFolder = "C:\Windows\Web\$OrgFolder\DesktopInfo\Logs"
    $ConfigPath = "C:\Windows\Web\$OrgFolder\DesktopInfo\DesktopInfo.json"
    $TaskPath = "\"
    $StatusTaskName = "$OrgFolder-DesktopInfo-Status"
    $LockTaskName = "$OrgFolder-DesktopInfo-LockScreen"
    $RenderTaskName = "$OrgFolder-DesktopInfo-Render"
    $WatchTaskName = "$OrgFolder-DesktopInfo-DisplayWatch"
    $UninstallRoots = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall")
    # Say writes each line to the console (the RMM's output) and keeps a copy for Deploy.log. Warnings are counted so the run can end
    # with exit 3 when it installed but something needs a look.
    $deployLines = New-Object System.Collections.Generic.List[string]
    function Say { param([string]$Text = "") Write-Host $Text; $deployLines.Add($Text) }
    $warnings = 0
    try {
        # Must be elevated: the install writes machine-wide policy, tasks and a locked folder.
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = ([System.Security.Principal.WindowsPrincipal]$identity).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) { Say "This script needs SYSTEM or administrator rights. It is running as $($identity.Name)."; return 1 }
        if (-not $identity.IsSystem) { Say "Note: running as $($identity.Name), not SYSTEM. That works, but RMM tools normally run this as SYSTEM." }
        if (@("Install", "Remove") -notcontains $Mode) { Say "Unknown mode '$Mode'. Use Install or Remove."; return 1 }
        # $OrgFolder names the folder under C:\Windows\Web that Install locks down and Remove deletes, and $DetectionKeyName
        # names the Uninstall key Remove deletes. A blank or odd value (such as "..") could point at C:\Windows\Web itself or
        # the whole Uninstall key, so stop here before anything changes.
        if ([string]$OrgFolder -notmatch '^[A-Za-z0-9_-]+\z') { Say "OrgFolder '$OrgFolder' is not valid. Use only letters, numbers, hyphens and underscores. Nothing was changed."; return 1 }
        if ([string]$DetectionKeyName -notmatch '^(?!\.+\z)[A-Za-z0-9_.-]+\z') { Say "DetectionKeyName '$DetectionKeyName' is not valid. Use only letters, numbers, dots, hyphens and underscores. Nothing was changed."; return 1 }
        # If the RMM agent started a 32-bit PowerShell, Sysnative reaches the real System32, so uwfmgr, conhost and 64-bit PowerShell
        # are found. The tasks always use the real 64-bit paths.
        $realSystem32 = Join-Path $env:SystemRoot "System32"
        $localSystem32 = $realSystem32
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $localSystem32 = Join-Path $env:SystemRoot "Sysnative" }
        $psTaskExe = Join-Path $realSystem32 "WindowsPowerShell\v1.0\powershell.exe"
        $psLocalExe = Join-Path $localSystem32 "WindowsPowerShell\v1.0\powershell.exe"
        $statusPath = Join-Path $ScriptFolder "Write-DeviceStatus.ps1"
        $rendererPath = Join-Path $ScriptFolder "Update-DesktopInfo.ps1"
        $lockPath = Join-Path $ScriptFolder "Update-LockScreen.ps1"
        $watchPath = Join-Path $ScriptFolder "Watch-DesktopDisplay.ps1"
        $osBuild = [string](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).BuildNumber
        Say "Deploy-DesktopInfo $PackageVersion  Mode: $Mode  Computer: $env:COMPUTERNAME  OS build: $osBuild  Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        # ----- UWF gate -----
        # Anything written while the filter is on is thrown away at restart, including the scheduled tasks. Stop before changing
        # anything. A UWF install whose state cannot be read is treated the same way, because nothing written could be trusted to stay.
        $uwfState = "NotInstalled"
        $uwfmgrPresent = Test-Path -LiteralPath (Join-Path $localSystem32 "uwfmgr.exe")
        $serviceKeyPresent = Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\uwfvol"
        if ($uwfmgrPresent -or $serviceKeyPresent) {
            $uwfState = "Unknown"
            $done = $false
            $attempt = 0
            while (-not $done -and $attempt -lt $CimRetries) {
                $attempt++
                try {
                    $filter = Get-CimInstance -Namespace "root\standardcimv2\embedded" -ClassName "UWF_Filter" -ErrorAction Stop | Select-Object -First 1
                    if ($null -ne $filter) {
                        Say "UWF_Filter CurrentEnabled: $($filter.CurrentEnabled)  NextEnabled: $($filter.NextEnabled)"
                        if ($filter.CurrentEnabled -eq $true) { $uwfState = "On" } else { $uwfState = "Off" }
                        $done = $true
                    } else {
                        Say "Attempt $attempt of $CimRetries returned no UWF_Filter instance"
                    }
                } catch {
                    $nativeCode = [string]$_.Exception.NativeErrorCode
                    $message = ([string]$_.Exception.Message).Trim()
                    if ($nativeCode -eq "InvalidClass" -or $nativeCode -eq "InvalidNamespace" -or $message -match "Invalid (class|namespace)") {
                        if ($uwfmgrPresent) { Say "uwfmgr.exe exists but the UWF WMI provider does not ($message). UWF looks damaged on this machine." } else { $uwfState = "NotInstalled"; Say "Only a leftover uwfvol key was found and the UWF WMI provider is missing. Treating UWF as not installed." }
                        $done = $true
                    } else {
                        Say "Attempt $attempt of $CimRetries could not read UWF_Filter: $message"
                    }
                }
                if (-not $done -and $attempt -lt $CimRetries) { Start-Sleep -Seconds $CimRetryDelaySeconds }
            }
        }
        Say "UWF: $uwfState"
        if ($uwfState -eq "On") { Say "Skipped. The UWF filter is on, so anything written now would be discarded at restart. Run this again with the filter off."; return 2 }
        if ($uwfState -eq "Unknown") { Say "Skipped. UWF components are present but the filter state could not be read, so there is no guarantee these changes would survive a restart."; return 2 }
        # ----- Helpers -----
        # Native tools (reg.exe, icacls.exe) are reduced to one readable line for the log. UWF exclusions are changed for the
        # next session only, which is the only kind UWF allows while it is installed.
        function Format-NativeOutput { param($Output) return ((@($Output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne "" })) -join " ") }
        # Set-UwfExclusion adds or removes one UWF file or registry exclusion for the next session, only when it needs changing.
        function Set-UwfExclusion {
            param([string]$Kind, [string]$Target, [bool]$Add)
            try {
                if ($Kind -eq "File") {
                    $relative = $Target
                    if ($relative -match '^[A-Za-z]:') { $relative = $relative.Substring(2) }
                    $uwfObject = Get-CimInstance -Namespace "root\standardcimv2\embedded" -ClassName "UWF_Volume" -ErrorAction Stop | Where-Object { $_.CurrentSession -eq $false -and $_.DriveLetter -eq "C:" } | Select-Object -First 1
                    $arguments = @{ FileName = $relative }
                    $label = "file exclusion $relative"
                } else {
                    $uwfObject = Get-CimInstance -Namespace "root\standardcimv2\embedded" -ClassName "UWF_RegistryFilter" -ErrorAction Stop | Where-Object { $_.CurrentSession -eq $false } | Select-Object -First 1
                    $arguments = @{ RegistryKey = $Target }
                    $label = "registry exclusion $Target"
                }
                if ($null -eq $uwfObject) { Say "  Could not find the UWF next-session object for the $label"; return }
                $found = [bool](Invoke-CimMethod -InputObject $uwfObject -MethodName FindExclusion -Arguments $arguments -ErrorAction Stop).bFound
                if ($Add -and -not $found) {
                    $null = Invoke-CimMethod -InputObject $uwfObject -MethodName AddExclusion -Arguments $arguments -ErrorAction Stop
                    Say "  Added UWF $label (next session)"
                } elseif (-not $Add -and $found) {
                    $null = Invoke-CimMethod -InputObject $uwfObject -MethodName RemoveExclusion -Arguments $arguments -ErrorAction Stop
                    Say "  Removed UWF $label (next session)"
                } elseif ($Add) {
                    Say "  UWF $label already present"
                }
            } catch {
                Say "  WARNING: could not change the UWF exclusion for ${Target}: $($_.Exception.Message)"
                $script:uwfExclusionProblem = $true
            }
        }
        # Deletes a tree without following junctions or symbolic links. Remove-Item -Recurse in Windows PowerShell 5.1 follows
        # them, and the old folders live under paths standard users may be able to write to. A link inside the tree is deleted
        # as a link, so whatever it points at is never touched by SYSTEM.
        function Clear-TreeSafely {
            param([string]$Path)
            foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
                $isLink = [bool]($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
                if ($child.PSIsContainer) {
                    if (-not $isLink) { Clear-TreeSafely -Path $child.FullName }
                    [System.IO.Directory]::Delete($child.FullName)
                } else {
                    if (-not $isLink) { $child.Attributes = [System.IO.FileAttributes]::Normal }
                    [System.IO.File]::Delete($child.FullName)
                }
            }
        }
        # Remove-Tree deletes a folder with Clear-TreeSafely. If the folder itself is a link, only the link is removed.
        function Remove-Tree {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) { return }
            try {
                $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                if ($root.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    [System.IO.Directory]::Delete($root.FullName)
                    Say "  Removed $Path (it was a link, the target was left alone)"
                } else {
                    Clear-TreeSafely -Path $root.FullName
                    [System.IO.Directory]::Delete($root.FullName)
                    Say "  Removed $Path"
                }
            } catch {
                Say "  WARNING: could not fully remove ${Path}: $($_.Exception.Message)"
                $script:treeProblem = $true
            }
        }
        $script:uwfExclusionProblem = $false
        $script:treeProblem = $false
        # ----- Remove mode -----
        # Undo the install: tasks first so nothing runs mid-removal, then the lock screen values that point into the folder (so
        # the lock screen falls back to the Windows default instead of a missing file), then the folder and the detection key.
        if ($Mode -eq "Remove") {
            foreach ($name in @($StatusTaskName, $LockTaskName, $RenderTaskName, $WatchTaskName)) {
                if ($null -eq (Get-ScheduledTask -TaskName $name -TaskPath $TaskPath -ErrorAction SilentlyContinue)) { Say "Task not present: $TaskPath$name"; continue }
                # Stop running copies first. The display watcher runs for the whole session and would otherwise keep going.
                Stop-ScheduledTask -TaskName $name -TaskPath $TaskPath -ErrorAction SilentlyContinue
                try { Unregister-ScheduledTask -TaskName $name -TaskPath $TaskPath -Confirm:$false -ErrorAction Stop; Say "Removed task: $TaskPath$name" } catch { $warnings++; Say "Could not remove task $TaskPath${name}: $($_.Exception.Message)" }
            }
            $cspKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
            $cspProps = Get-ItemProperty -Path $cspKey -ErrorAction SilentlyContinue
            if ($null -ne $cspProps -and ([string]$cspProps.LockScreenImagePath).StartsWith($RootFolder, [System.StringComparison]::OrdinalIgnoreCase)) {
                foreach ($valueName in @("LockScreenImagePath", "LockScreenImageUrl", "LockScreenImageStatus")) { Remove-ItemProperty -Path $cspKey -Name $valueName -ErrorAction SilentlyContinue }
                Say "Cleared the PersonalizationCSP lock screen values that pointed into $RootFolder"
            }
            $policyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
            $lockPolicy = [string](Get-ItemProperty -Path $policyKey -Name "LockScreenImage" -ErrorAction SilentlyContinue).LockScreenImage
            if ($lockPolicy.StartsWith($RootFolder, [System.StringComparison]::OrdinalIgnoreCase)) { Remove-ItemProperty -Path $policyKey -Name "LockScreenImage" -ErrorAction SilentlyContinue; Say "Cleared the LockScreenImage policy that pointed into $RootFolder" }
            Remove-Tree -Path $RootFolder
            foreach ($uninstallRoot in $UninstallRoots) { $detectKey = Join-Path $uninstallRoot $DetectionKeyName; if (Test-Path $detectKey) { Remove-Item -Path $detectKey -Recurse -Force -ErrorAction SilentlyContinue; Say "Removed detection key $detectKey" } }
            if ($uwfState -ne "NotInstalled") { Say "Note: the UWF exclusions this package added are left in place. They point at paths that no longer exist." }
            Say "Left in place: each user's current wallpaper. The rendered image stays on screen until something else sets the wallpaper."
            if ($warnings -gt 0 -or $script:treeProblem) { return 1 }
            return 0
        }
        # ----- Check the package before changing anything -----
        # Both images must open and all four embedded scripts must be present before anything changes, so a bad package fails
        # with nothing half done. An image missing from the package is fine when the copy installed earlier is still there,
        # or when one of the Windows default images exists.
        $packageDir = $PackageFolder
        if ([string]::IsNullOrWhiteSpace($packageDir)) { $packageDir = $PSScriptRoot }
        if ([string]::IsNullOrWhiteSpace($packageDir)) { $packageDir = (Get-Location).Path }
        Say "Package folder: $packageDir"
        try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch { Say "Could not load System.Drawing to check the images: $($_.Exception.Message)"; return 1 }
        $images = @()
        $imageSpecs = @([pscustomobject]@{ Name = $WallpaperFileName; Defaults = $DefaultWallpaperPaths }, [pscustomobject]@{ Name = $LockScreenFileName; Defaults = $DefaultLockScreenPaths })
        foreach ($imageSpec in $imageSpecs) {
            $imageName = $imageSpec.Name
            $packaged = Join-Path $packageDir $imageName
            $installed = Join-Path $RootFolder $imageName
            $source = $null
            if (Test-Path -LiteralPath $packaged) {
                $source = $packaged
            } elseif (Test-Path -LiteralPath $installed) {
                $source = $installed
                Say "$imageName is not in the package folder. Keeping the copy already installed at $installed."
            } else {
                # Neither yours nor an earlier copy, so fall back to the first Windows default image that exists
                foreach ($defaultPath in @($imageSpec.Defaults)) { if ($null -eq $source -and -not [string]::IsNullOrWhiteSpace([string]$defaultPath) -and (Test-Path -LiteralPath $defaultPath)) { $source = [string]$defaultPath } }
                if ($null -eq $source) { Say "$imageName was not found in $packageDir or $RootFolder, and none of the Windows default images exist. Nothing was changed."; return 1 }
                Say "$imageName is not in the package folder and is not installed yet. Using the Windows default image $source."
            }
            $bytes = $null
            $checkStream = $null
            $checkImage = $null
            try {
                $bytes = [System.IO.File]::ReadAllBytes($source)
                $checkStream = [System.IO.MemoryStream]::new($bytes)
                $checkImage = [System.Drawing.Image]::FromStream($checkStream)
                $images += [pscustomobject]@{ Name = $imageName; Source = $source; Target = $installed; Bytes = $bytes; Size = "$($checkImage.Width)x$($checkImage.Height)" }
                Say "Image OK: $source ($($checkImage.Width)x$($checkImage.Height), $($bytes.Length) bytes)"
            } catch {
                $head = ""
                if ($null -ne $bytes -and $bytes.Length -gt 0) { $head = ($bytes[0..([Math]::Min(11, $bytes.Length - 1))] | ForEach-Object { $_.ToString("X2") }) -join "" }
                if ($head.StartsWith("FFD8")) { $kind = "a JPEG" } elseif ($head.StartsWith("89504E47")) { $kind = "a PNG" } elseif ($head.Length -ge 24 -and $head.StartsWith("52494646") -and $head.Substring(16, 8) -eq "57454250") { $kind = "a WebP, which System.Drawing cannot open" } elseif ($head.Length -ge 16 -and $head.Substring(8, 8) -eq "66747970") { $kind = "a HEIC or AVIF, which System.Drawing cannot open" } else { $kind = "an unknown format (first bytes $head)" }
                Say "$source could not be opened as an image. The file is $kind. ($($_.Exception.Message)) Nothing was changed."
                return 1
            } finally {
                if ($null -ne $checkImage) { $checkImage.Dispose() }
                if ($null -ne $checkStream) { $checkStream.Dispose() }
            }
        }
        $payloads = @(
            [pscustomobject]@{ Label = "status writer"; Path = $statusPath; Content = $StatusScript; Marker = "function Invoke-WriteDeviceStatus" },
            [pscustomobject]@{ Label = "desktop renderer"; Path = $rendererPath; Content = $RendererScript; Marker = "function Invoke-UpdateDesktopInfo" },
            [pscustomobject]@{ Label = "lock screen generator"; Path = $lockPath; Content = $LockScreenScript; Marker = "function Invoke-UpdateLockScreen" },
            [pscustomobject]@{ Label = "display watcher"; Path = $watchPath; Content = $WatchScript; Marker = "function Invoke-WatchDesktopDisplay" }
        )
        foreach ($payload in $payloads) {
            if ([string]::IsNullOrWhiteSpace($payload.Content) -or -not $payload.Content.Contains($payload.Marker)) { Say "The embedded $($payload.Label) is empty or is not the expected script (looked for '$($payload.Marker)'). Nothing was changed."; return 1 }
        }
        # ----- Clean up old builds -----
        # BGInfo and the old builds launched from many places. Each one left behind could redraw over the new wallpaper or put
        # the old lock screen back, so all of them are removed. Only Group Policy scripts are left, because only the GPO can fix them.
        if ($CleanupOldBuilds) {
            Say "Cleaning up old builds"
            $patternList = @($OldLauncherPatterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [regex]::Escape($_) })
            if ($patternList.Count -gt 0) { $launcherRegex = $patternList -join "|" } else { $launcherRegex = "(?!)" }
            $protectedList = @($ProtectedProcessPatterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [regex]::Escape($_) })
            if ($protectedList.Count -gt 0) { $protectedRegex = $protectedList -join "|" } else { $protectedRegex = "(?!)" }
            $counts = @{ Found = 0; Removed = 0; Failed = 0 }
            $ownTasks = @($StatusTaskName, $LockTaskName, $RenderTaskName, $WatchTaskName)
            # Processes. Never this script, its parent (the RMM agent's PowerShell) or anything matching $ProtectedProcessPatterns.
            $parentPid = [int](Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).ParentProcessId
            foreach ($proc in @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -ne $PID -and $_.ProcessId -ne $parentPid -and [string]$_.CommandLine -notmatch $protectedRegex -and ((@("bginfo.exe", "bginfo64.exe") -contains ([string]$_.Name).ToLower()) -or ((@("powershell.exe", "wscript.exe", "cscript.exe", "cmd.exe") -contains ([string]$_.Name).ToLower()) -and [string]$_.CommandLine -match $launcherRegex)) })) {
                try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop; Say "  Stopped process $($proc.Name) PID $($proc.ProcessId)" } catch { Say "  Could not stop $($proc.Name) PID $($proc.ProcessId): $($_.Exception.Message)" }
            }
            # Machine Run and RunOnce keys
            foreach ($runKey in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce")) {
                $runProps = Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue
                if ($null -eq $runProps) { continue }
                foreach ($prop in $runProps.PSObject.Properties) {
                    if ($prop.Name -like "PS*" -or [string]$prop.Value -notmatch $launcherRegex) { continue }
                    $counts.Found++
                    try { Remove-ItemProperty -Path $runKey -Name $prop.Name -ErrorAction Stop; $counts.Removed++; Say "  Removed $runKey [$($prop.Name)] $($prop.Value)" } catch { $counts.Failed++; Say "  Could not remove $runKey [$($prop.Name)]: $($_.Exception.Message)" }
                }
            }
            # User hives: Run and RunOnce launchers, plus the old package's policy wallpaper values, for every profile.
            function Clear-OldUserHive {
                param([string]$Root, [string]$Label)
                foreach ($sub in @("Software\Microsoft\Windows\CurrentVersion\Run", "Software\Microsoft\Windows\CurrentVersion\RunOnce")) {
                    $keyPath = "$Root\$sub"
                    $hiveProps = Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue
                    if ($null -eq $hiveProps) { continue }
                    foreach ($prop in $hiveProps.PSObject.Properties) {
                        if ($prop.Name -like "PS*" -or [string]$prop.Value -notmatch $launcherRegex) { continue }
                        $counts.Found++
                        try { Remove-ItemProperty -Path $keyPath -Name $prop.Name -ErrorAction Stop; $counts.Removed++; Say "  Removed [$Label] $sub [$($prop.Name)] $($prop.Value)" } catch { $counts.Failed++; Say "  Could not remove [$Label] $sub [$($prop.Name)]: $($_.Exception.Message)" }
                    }
                }
                # Policy wallpaper values from the old wallpaper package. They override the desktop renderer.
                $policySub = "Software\Microsoft\Windows\CurrentVersion\Policies\System"
                $policyProps = Get-ItemProperty -Path "$Root\$policySub" -ErrorAction SilentlyContinue
                if ($null -ne $policyProps) {
                    foreach ($valueName in @("Wallpaper", "WallpaperStyle")) {
                        if ($null -eq $policyProps.$valueName) { continue }
                        $counts.Found++
                        try { Remove-ItemProperty -Path "$Root\$policySub" -Name $valueName -ErrorAction Stop; $counts.Removed++; Say "  Removed [$Label] policy $valueName = $($policyProps.$valueName)" } catch { $counts.Failed++; Say "  Could not remove [$Label] policy ${valueName}: $($_.Exception.Message)" }
                    }
                }
                $policyProps = $null
                $hiveProps = $null
            }
            # Dismount-Hive unloads a hive this run loaded. It retries, because .NET can keep a registry handle open for a moment.
            function Dismount-Hive {
                param([string]$MountName)
                $unloaded = $false
                $tries = 0
                $unloadOut = ""
                while (-not $unloaded -and $tries -lt 5) {
                    $tries++
                    [gc]::Collect()
                    [gc]::WaitForPendingFinalizers()
                    $unloadOut = & reg.exe unload "HKU\$MountName" 2>&1
                    if ($LASTEXITCODE -eq 0) { $unloaded = $true } else { Start-Sleep -Seconds 1 }
                }
                if (-not $unloaded) { $counts.Failed++; Say "  WARNING: could not unload HKU\${MountName}: $(Format-NativeOutput $unloadOut)" }
            }
            # Get-HiveTail turns a hive file path into a comparable form, so the same file is recognized under any drive prefix.
            function Get-HiveTail { param([string]$Path) return ((($Path -replace '^\\Device\\[^\\]+', '') -replace '^[A-Za-z]:', '').ToLower()) }
            # Map every loaded user hive to the file behind it, so a file loaded under an unexpected name is found instead of failing
            # to load. Signed-in users are cleaned in place. A hive an older script loaded and never unloaded is cleaned, then unloaded,
            # because a Default user hive left loaded can stop Windows from building new profiles.
            $mountedFiles = @{}
            $hiveList = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\hivelist" -ErrorAction SilentlyContinue
            if ($null -ne $hiveList) {
                foreach ($prop in $hiveList.PSObject.Properties) { if ($prop.Name -like "\REGISTRY\USER\*" -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) { $mountedFiles[$prop.Name.Substring(15)] = [string]$prop.Value } }
            }
            $loadedTails = @($mountedFiles.Values | ForEach-Object { Get-HiveTail $_ })
            $loadedSids = @($mountedFiles.Keys)
            $signedInCount = 0
            $staleCount = 0
            $staleUnloaded = 0
            foreach ($mount in @($mountedFiles.Keys | Sort-Object)) {
                $mountFile = $mountedFiles[$mount]
                if ($mount -match "^S-1-5-21-[\d-]+$") {
                    Clear-OldUserHive -Root "Registry::HKEY_USERS\$mount" -Label $mount
                    $signedInCount++
                } elseif ($mount -notmatch "^S-1-5-" -and $mount -ne ".DEFAULT" -and $mountFile -match "\\NTUSER\.DAT$") {
                    $isOwnMount = $false
                    foreach ($ownPrefix in $OwnHiveMountPrefixes) { if (-not [string]::IsNullOrWhiteSpace($ownPrefix) -and $mount.StartsWith($ownPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { $isOwnMount = $true } }
                    if ($isOwnMount) { Say "  Skipping HKU\${mount}: another run of this package has it loaded right now"; continue }
                    $staleCount++
                    Say "  Found a user hive left loaded by an older script: HKU\$mount -> $mountFile"
                    Clear-OldUserHive -Root "Registry::HKEY_USERS\$mount" -Label $mount
                    if ($UnloadStaleHiveMounts) {
                        $failedBefore = $counts.Failed
                        Dismount-Hive -MountName $mount
                        if ($counts.Failed -eq $failedBefore) { $staleUnloaded++; Say "  Unloaded HKU\$mount" }
                    }
                }
            }
            # Profiles that are not signed in, and the Default user that every new profile is copied from, are loaded, cleaned and unloaded.
            $offlineHives = @([pscustomobject]@{ Label = "Default user"; File = (Join-Path $env:SystemDrive "Users\Default\NTUSER.DAT") })
            if ($CleanOfflineProfiles) {
                foreach ($profileKey in @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "^S-1-5-21-[\d-]+$" })) {
                    if ($loadedSids -contains $profileKey.PSChildName) { continue }
                    $profilePath = [string]$profileKey.GetValue("ProfileImagePath")
                    if ([string]::IsNullOrWhiteSpace($profilePath)) { continue }
                    $offlineHives += [pscustomobject]@{ Label = $profileKey.PSChildName; File = (Join-Path $profilePath "NTUSER.DAT") }
                }
            }
            $mountIndex = 0
            $offlineCount = 0
            foreach ($hiveEntry in $offlineHives) {
                if (-not (Test-Path -LiteralPath $hiveEntry.File)) { continue }
                # Already cleaned above while it was loaded under another name
                if ($loadedTails -contains (Get-HiveTail $hiveEntry.File)) { continue }
                $mountIndex++
                $mountName = "$($OrgFolder)_Hive_$mountIndex"
                $loadOut = & reg.exe load "HKU\$mountName" $hiveEntry.File 2>&1
                if ($LASTEXITCODE -ne 0) { $counts.Failed++; Say "  Could not load the hive for $($hiveEntry.Label): $(Format-NativeOutput $loadOut)"; continue }
                $offlineCount++
                try { Clear-OldUserHive -Root "Registry::HKEY_USERS\$mountName" -Label $hiveEntry.Label } finally { Dismount-Hive -MountName $mountName }
            }
            Say "  User hives checked: $signedInCount signed in, $staleCount left loaded by an older script ($staleUnloaded unloaded), $offlineCount loaded from disk"
            # Startup folders: shortcuts and small scripts that start BGInfo, in All Users and every profile.
            $startupFolders = @(Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\StartUp")
            foreach ($profileDir in @(Get-ChildItem -Path (Join-Path $env:SystemDrive "Users") -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) })) { $startupFolders += Join-Path $profileDir.FullName "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup" }
            $shell = $null
            try { $shell = New-Object -ComObject WScript.Shell } catch { $shell = $null }
            foreach ($folder in $startupFolders) {
                if (-not (Test-Path -LiteralPath $folder)) { continue }
                foreach ($item in @(Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction SilentlyContinue)) {
                    $hit = ($item.Name -match $launcherRegex)
                    if (-not $hit -and $item.Extension -eq ".lnk" -and $null -ne $shell) {
                        try { $shortcut = $shell.CreateShortcut($item.FullName); if ((("{0} {1}" -f $shortcut.TargetPath, $shortcut.Arguments)) -match $launcherRegex) { $hit = $true } } catch { $hit = $false }
                    } elseif (-not $hit -and @(".bat", ".cmd", ".vbs", ".ps1", ".js") -contains $item.Extension.ToLower()) {
                        if (Select-String -LiteralPath $item.FullName -Pattern $launcherRegex -Quiet -ErrorAction SilentlyContinue) { $hit = $true }
                    }
                    if (-not $hit) { continue }
                    $counts.Found++
                    try { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop; $counts.Removed++; Say "  Removed startup item $($item.FullName)" } catch { $counts.Failed++; Say "  Could not remove startup item $($item.FullName): $($_.Exception.Message)" }
                }
            }
            if ($null -ne $shell) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
            # Scheduled tasks that launch BGInfo or the old status and lock screen scripts. This package's own tasks are skipped.
            foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
                if ($ownTasks -contains $task.TaskName) { continue }
                $actionText = (($task.Actions | ForEach-Object { "{0} {1}" -f $_.Execute, $_.Arguments }) -join " ").Trim()
                if (-not (($OldTaskNames -contains $task.TaskName) -or ($actionText -match $launcherRegex))) { continue }
                $counts.Found++
                try { Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop; $counts.Removed++; Say "  Removed task $($task.TaskPath)$($task.TaskName) -> $actionText" } catch { $counts.Failed++; Say "  Could not remove task $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)" }
            }
            # Group Policy scripts can only be fixed in the GPO
            $gpoFound = 0
            foreach ($gpKey in @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSPath -match "\\Scripts\\" })) {
                $scriptText = "{0} {1}" -f [string]$gpKey.GetValue("Script"), [string]$gpKey.GetValue("Parameters")
                if ($scriptText -notmatch $launcherRegex) { continue }
                $gpoFound++
                $gpoName = [string](Get-ItemProperty -Path $gpKey.PSParentPath -ErrorAction SilentlyContinue).DisplayName
                Say "  WARNING: Group Policy script [$gpoName] $scriptText. Not removed. Fix it in the GPO or it will bring BGInfo back."
            }
            if ($uwfState -ne "NotInstalled") { foreach ($oldExclusion in $OldUwfFileExclusions) { if (-not [string]::IsNullOrWhiteSpace($oldExclusion)) { Set-UwfExclusion -Kind "File" -Target $oldExclusion -Add $false } } }
            Say "Cleanup: $($counts.Found) old item(s) found, $($counts.Removed) removed, $($counts.Failed) failed, $gpoFound Group Policy script(s) to fix by hand"
            if ($counts.Failed -gt 0 -or $gpoFound -gt 0) { $warnings++ }
        } else {
            Say "Cleanup of old builds is turned off"
        }
        # ----- Storage layout and permissions -----
        # SYSTEM runs the scripts in this folder at every startup. If standard users could change them, they could run code as
        # SYSTEM, so the folder is reset to: SYSTEM and Administrators full control, Users and app packages read only. App packages
        # need read access because the lock screen is drawn by a sandboxed app and shows black if it cannot read the image.
        foreach ($folder in @($RootFolder, $ScriptFolder, $LockScreenFolder, $LogFolder)) {
            if (-not (Test-Path -LiteralPath $folder)) {
                try { New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop | Out-Null; Say "Created folder: $folder" } catch { Say "Could not create ${folder}: $($_.Exception.Message)"; return 1 }
            }
        }
        $aclOut = & icacls.exe $RootFolder /reset 2>&1
        if ($LASTEXITCODE -ne 0) { Say "Could not reset permissions on ${RootFolder}: $(Format-NativeOutput $aclOut)"; return 1 }
        $aclOut = & icacls.exe $RootFolder /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" "*S-1-15-2-1:(OI)(CI)RX" "*S-1-15-2-2:(OI)(CI)RX" 2>&1
        if ($LASTEXITCODE -ne 0) { Say "Could not set permissions on ${RootFolder}: $(Format-NativeOutput $aclOut)"; return 1 }
        $aclOut = & icacls.exe (Join-Path $RootFolder "*") /reset /T /C /Q 2>&1
        if ($LASTEXITCODE -ne 0) { $warnings++; Say "WARNING: could not reset permissions on everything under ${RootFolder}: $(Format-NativeOutput $aclOut)" }
        Say "Locked down ${RootFolder}: SYSTEM and Administrators full control, Users and app packages read only, applied to everything inside"
        # The logs name signed-in users and no user process needs them. The renderer logs to the user's own profile instead.
        $aclOut = & icacls.exe $LogFolder /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" 2>&1
        if ($LASTEXITCODE -ne 0) { $warnings++; Say "WARNING: could not restrict ${LogFolder}: $(Format-NativeOutput $aclOut)" } else { Say "Restricted ${LogFolder} to SYSTEM and Administrators" }
        $aclView = & icacls.exe $RootFolder 2>&1
        foreach ($aclLine in @($aclView | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and [string]$_ -notmatch "Successfully processed" })) { Say "  $(([string]$aclLine).Trim())" }
        # ----- Base images -----
        # Copy the two checked images into place. An image already installed and unchanged is left alone.
        foreach ($imageInfo in $images) {
            if ($imageInfo.Source -eq $imageInfo.Target) { continue }
            try {
                if (Test-Path -LiteralPath $imageInfo.Target) { Remove-Item -LiteralPath $imageInfo.Target -Force -ErrorAction Stop }
                [System.IO.File]::WriteAllBytes($imageInfo.Target, $imageInfo.Bytes)
                Say "Installed $($imageInfo.Target) ($($imageInfo.Size))"
            } catch {
                Say "Could not write $($imageInfo.Target): $($_.Exception.Message)"
                return 1
            }
        }
        # Only one copy of the wallpaper should exist. A copy in the scripts folder is a leftover, so it is removed.
        $staleCopy = Join-Path $ScriptFolder $WallpaperFileName
        if (Test-Path -LiteralPath $staleCopy) { Remove-Item -LiteralPath $staleCopy -Force -ErrorAction SilentlyContinue; Say "Removed the stale wallpaper copy from an earlier build: $staleCopy" }
        # ----- Shared settings -----
        # Both renderers read this one file, so the desktop and lock screen always say the same thing. It is read back right away
        # to catch a bad write before the tasks depend on it.
        $sharedSettings = [ordered]@{
            Version = $PackageVersion
            TitleText = $TitleText
            LocationRules = @($LocationRules | ForEach-Object { [ordered]@{ Prefix = [string]$_.Prefix; Label = [string]$_.Label } })
            DefaultLocation = $DefaultLocation
            StaffPattern = $StaffPattern
            StaffContactLines = @($StaffContactLines | ForEach-Object { [string]$_ })
            OtherContactLines = @($OtherContactLines | ForEach-Object { [string]$_ })
            NoticeSharedPC = $NoticeSharedPC
            NoticeUWF = $NoticeUWF
            NoticeSharedPCKept = $NoticeSharedPCKept
            NoticeAction = $NoticeAction
            UWFWarnStates = @($UWFWarnStates | ForEach-Object { [string]$_ })
            SharedPCWarnStates = @($SharedPCWarnStates | ForEach-Object { [string]$_ })
            DesktopCorner = $DesktopCorner
            DesktopMiddlePercent = $DesktopMiddlePercent
            LockScreenCorner = $LockScreenCorner
            DesktopMessage = $DesktopMessage
            HostnameLabel = $HostnameLabel
            UsernameLabel = $UsernameLabel
            UWFLabel = $UWFLabel
        }
        try {
            # Windows PowerShell 5.1 can write arrays as {"value": [...], "Count": n} unless this type data is removed first
            Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue
            $json = $sharedSettings | ConvertTo-Json -Depth 5
            [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
            $readBack = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $ruleCheck = @($readBack.LocationRules | Where-Object { $null -ne $_.Prefix })
            if ($ruleCheck.Count -ne @($LocationRules).Count) { throw "the location rules did not read back correctly ($($ruleCheck.Count) of $(@($LocationRules).Count))" }
            Say "Wrote shared settings: $ConfigPath"
        } catch {
            Say "Could not write or read back ${ConfigPath}: $($_.Exception.Message)"
            return 1
        }
        # ----- Scripts -----
        # Write each embedded script to disk with a byte order mark and Windows line endings, which Windows PowerShell 5.1 reads
        # reliably, and check it with the PowerShell parser before it replaces the running copy.
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        foreach ($payload in $payloads) {
            $text = [regex]::Replace($payload.Content.Trim(), '\r?\n', [Environment]::NewLine) + [Environment]::NewLine
            # Fill in the organization settings the embedded scripts cannot read on their own
            $text = $text.Replace("__ORGFOLDER__", $OrgFolder).Replace("__WALLPAPERFILE__", $WallpaperFileName).Replace("__LOCKSCREENFILE__", $LockScreenFileName)
            # Write to a temporary name, parse it, then swap it in. The scheduled tasks never see a missing or half-written script,
            # and a script that fails the parser leaves the previous version in place.
            $tempPath = $payload.Path + ".new"
            try {
                if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction Stop }
                [System.IO.File]::WriteAllText($tempPath, $text, $utf8Bom)
            } catch {
                Say "Could not write $($tempPath): $($_.Exception.Message)"
                return 1
            }
            $parseTokens = $null
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($tempPath, [ref]$parseTokens, [ref]$parseErrors)
            if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) { Say "The $($payload.Label) failed the PowerShell parser at line $($parseErrors[0].Extent.StartLineNumber): $($parseErrors[0].Message). The previous copy was left in place."; Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue; return 1 }
            try { Move-Item -LiteralPath $tempPath -Destination $payload.Path -Force -ErrorAction Stop } catch { Say "Could not replace $($payload.Path): $($_.Exception.Message)"; Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue; return 1 }
            $hash = (Get-FileHash -LiteralPath $payload.Path -Algorithm SHA256).Hash
            Say "Wrote $($payload.Path) (SHA256 $($hash.Substring(0, 12)), parser OK)"
        }
        # An AllSigned policy from Group Policy overrides -ExecutionPolicy Bypass and would block every task, so warn about it.
        $machinePolicy = [string](Get-ExecutionPolicy -Scope MachinePolicy)
        if ($machinePolicy -eq "AllSigned") { $warnings++; Say "WARNING: Group Policy sets the PowerShell execution policy to AllSigned. That overrides -ExecutionPolicy Bypass and will block these unsigned scripts." }
        # ----- Scheduled tasks -----
        # Three tasks, plus the display watcher on laptops, each with the least privilege that works. -Force replaces an older copy.
        $systemArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"'
        try {
            # Status: SYSTEM at startup, because the Shared PC check only answers to SYSTEM.
            $statusAction = New-ScheduledTaskAction -Execute $psTaskExe -Argument ($systemArgs -f $statusPath)
            $statusPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
            $statusSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
            Register-ScheduledTask -TaskName $StatusTaskName -TaskPath $TaskPath -Action $statusAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $statusPrincipal -Settings $statusSettings -Description "$OrgName desktop info. Writes the UWF and Shared PC status files at startup." -Force -ErrorAction Stop | Out-Null
            Say "Registered task: $TaskPath$StatusTaskName (SYSTEM, at startup)"
            # Lock screen: SYSTEM, once after startup. The delay lets the display driver report a resolution first. A sign-in
            # trigger is only added if $LockScreenAtSignIn is turned on, which is not recommended.
            $lockAction = New-ScheduledTaskAction -Execute $psTaskExe -Argument ($systemArgs -f $lockPath)
            $lockStartup = New-ScheduledTaskTrigger -AtStartup
            if ($LockScreenStartupDelaySeconds -gt 0) { $lockStartup.Delay = "PT{0}S" -f [int]$LockScreenStartupDelaySeconds }
            $lockTriggers = @($lockStartup)
            $lockNote = "at startup + $LockScreenStartupDelaySeconds s"
            if ($LockScreenAtSignIn) {
                $lockLogon = New-ScheduledTaskTrigger -AtLogOn
                $lockLogon.Delay = "PT30S"
                $lockTriggers += $lockLogon
                $lockNote = "$lockNote and 30 s after each sign-in"
            }
            $lockPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
            $lockSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
            Register-ScheduledTask -TaskName $LockTaskName -TaskPath $TaskPath -Action $lockAction -Trigger $lockTriggers -Principal $lockPrincipal -Settings $lockSettings -Description "$OrgName desktop info. Renders the lock screen image." -Force -ErrorAction Stop | Out-Null
            Say "Registered task: $TaskPath$LockTaskName (SYSTEM, $lockNote)"
            # Desktop: runs as whoever signs in (the Users group, limited rights), launched through conhost --headless so no window
            # flashes. Triggers: sign-in, sign-in plus the second-pass delay, and unlock. Runs queue so a slow first run is not skipped.
            $renderArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $rendererPath
            if ($UseHeadlessConsole -and (Test-Path -LiteralPath (Join-Path $localSystem32 "conhost.exe"))) {
                $renderAction = New-ScheduledTaskAction -Execute (Join-Path $realSystem32 "conhost.exe") -Argument ('--headless "{0}" {1}' -f $psTaskExe, $renderArgs)
                $launchNote = "conhost --headless"
            } else {
                $renderAction = New-ScheduledTaskAction -Execute $psTaskExe -Argument $renderArgs
                $launchNote = "powershell -WindowStyle Hidden"
            }
            $renderTriggers = @(New-ScheduledTaskTrigger -AtLogOn)
            $triggerNote = "at sign-in"
            if ($RenderSecondPassDelaySeconds -gt 0) {
                $secondPass = New-ScheduledTaskTrigger -AtLogOn
                $secondPass.Delay = "PT{0}S" -f [int]$RenderSecondPassDelaySeconds
                $renderTriggers += $secondPass
                $triggerNote = "at sign-in and again $([int]$RenderSecondPassDelaySeconds) s later"
            }
            if ($RenderOnUnlock) {
                $stateClass = Get-CimClass -Namespace "Root/Microsoft/Windows/TaskScheduler" -ClassName "MSFT_TaskSessionStateChangeTrigger" -ErrorAction Stop
                $renderTriggers += New-CimInstance -CimClass $stateClass -Property @{ StateChange = 8 } -ClientOnly
                $triggerNote += ", and at unlock"
            }
            $renderPrincipal = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited
            $renderSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances Queue
            Register-ScheduledTask -TaskName $RenderTaskName -TaskPath $TaskPath -Action $renderAction -Trigger $renderTriggers -Principal $renderPrincipal -Settings $renderSettings -Description "$OrgName desktop info. Draws device details onto the signed-in user's wallpaper." -Force -ErrorAction Stop | Out-Null
            Say "Registered task: $TaskPath$RenderTaskName (signed-in user, $triggerNote, launched with $launchNote)"
            # Display watcher: runs as whoever signs in, hidden, for the whole session (no time limit), and keeps running on
            # battery. Parallel lets each signed-in user have their own copy. Running copies are stopped first so an update
            # takes effect, and the task is removed again if the setting or the chassis no longer calls for it.
            $watchRegistered = $false
            $watchMode = [string]$RedrawOnDisplayChange
            if (@("Laptops", "All", "Off") -notcontains $watchMode) { Say "Unknown RedrawOnDisplayChange '$watchMode'. Using Laptops."; $watchMode = "Laptops" }
            $chassisTypes = @((Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
            $isPortable = (@($chassisTypes | Where-Object { @(8, 9, 10, 14, 30, 31, 32) -contains $_ }).Count -gt 0)
            $existingWatch = Get-ScheduledTask -TaskName $WatchTaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
            if ($null -ne $existingWatch) { Stop-ScheduledTask -TaskName $WatchTaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue }
            if ($watchMode -eq "All" -or ($watchMode -eq "Laptops" -and $isPortable)) {
                $watchArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $watchPath
                if ($UseHeadlessConsole -and (Test-Path -LiteralPath (Join-Path $localSystem32 "conhost.exe"))) { $watchAction = New-ScheduledTaskAction -Execute (Join-Path $realSystem32 "conhost.exe") -Argument ('--headless "{0}" {1}' -f $psTaskExe, $watchArgs) } else { $watchAction = New-ScheduledTaskAction -Execute $psTaskExe -Argument $watchArgs }
                $watchPrincipal = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited
                $watchSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel
                Register-ScheduledTask -TaskName $WatchTaskName -TaskPath $TaskPath -Action $watchAction -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Principal $watchPrincipal -Settings $watchSettings -Description "$OrgName desktop info. Redraws the wallpaper when the monitor layout changes (docking, lid close)." -Force -ErrorAction Stop | Out-Null
                $watchRegistered = $true
                Say "Registered task: $TaskPath$WatchTaskName (signed-in user, whole session; setting $watchMode, chassis type $($chassisTypes -join ','))"
            } elseif ($null -ne $existingWatch) {
                Unregister-ScheduledTask -TaskName $WatchTaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue
                Say "Removed task $TaskPath$WatchTaskName (setting $watchMode, chassis type $($chassisTypes -join ','))"
            } else {
                Say "Display watcher not registered (setting $watchMode, chassis type $($chassisTypes -join ','))"
            }
        } catch {
            Say "Could not register the scheduled tasks: $($_.Exception.Message)"
            return 1
        }
        # ----- UWF exclusions for the lock screen -----
        # On a protected PC the lock screen render and its policy values would be thrown away at every restart. Excluding them
        # lets the render from one boot carry into the next.
        if ($uwfState -ne "NotInstalled") {
            if ($ApplyUwfExclusions) {
                Say "Adding UWF exclusions so the lock screen carries over to the next boot"
                Set-UwfExclusion -Kind "File" -Target $LockScreenFolder -Add $true
                foreach ($exclusionKey in @("HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP", "HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization", "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent")) { Set-UwfExclusion -Kind "Registry" -Target $exclusionKey -Add $true }
            } else {
                Say "UWF exclusions are turned off. On protected machines the lock screen will show the image from the last unprotected boot."
            }
            if ($script:uwfExclusionProblem) { $warnings++ }
        }
        # ----- Run now -----
        # Run everything once so the result shows in this run's output instead of waiting for a restart. The child output
        # is relayed line by line. Anyone signed in gets their desktop redrawn, and their render log is copied in.
        $lockRendered = $false
        if ($RunNow) {
            Say "Running the status writer now:"
            $childOut = & $psLocalExe -NoProfile -NonInteractive -InputFormat None -ExecutionPolicy Bypass -File $statusPath 2>&1
            $childExit = $LASTEXITCODE
            foreach ($childLine in $childOut) { Say "  [status] $childLine" }
            if ($childExit -ne 0) { $warnings++; Say "WARNING: the status writer exited with $childExit." }
            Say "Running the lock screen generator now:"
            $childOut = & $psLocalExe -NoProfile -NonInteractive -InputFormat None -ExecutionPolicy Bypass -File $lockPath 2>&1
            $childExit = $LASTEXITCODE
            foreach ($childLine in $childOut) { Say "  [lock] $childLine" }
            if ($childExit -ne 0) { $warnings++; Say "WARNING: the lock screen generator exited with $childExit." } else { $lockRendered = $true }
            $sessionUsers = @()
            foreach ($proc in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)) {
                try {
                    $sidResult = Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid -ErrorAction Stop
                    $ownerResult = Invoke-CimMethod -InputObject $proc -MethodName GetOwner -ErrorAction Stop
                    if (-not [string]::IsNullOrWhiteSpace($sidResult.Sid) -and ($sessionUsers.Sid -notcontains $sidResult.Sid)) { $sessionUsers += [pscustomobject]@{ Sid = [string]$sidResult.Sid; Name = "$($ownerResult.Domain)\$($ownerResult.User)"; Session = $proc.SessionId } }
                } catch {
                    Say "Could not read the owner of explorer.exe PID $($proc.ProcessId): $($_.Exception.Message)"
                }
            }
            if ($sessionUsers.Count -eq 0) {
                Say "Nobody is signed in, so the desktop will be drawn at the next sign-in."
            } else {
                foreach ($sessionUser in $sessionUsers) { Say "Signed in: $($sessionUser.Name) (session $($sessionUser.Session))" }
                $renderStart = Get-Date
                try {
                    Start-ScheduledTask -TaskName $RenderTaskName -TaskPath $TaskPath -ErrorAction Stop
                    Say "Started $TaskPath$RenderTaskName. Waiting up to $RenderWaitSeconds seconds for it to finish."
                    $deadline = $renderStart.AddSeconds($RenderWaitSeconds)
                    $sawRunning = $false
                    $state = ""
                    do {
                        Start-Sleep -Seconds 3
                        $state = [string](Get-ScheduledTask -TaskName $RenderTaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue).State
                        if ($state -eq "Running") { $sawRunning = $true }
                    } while ((Get-Date) -lt $deadline -and ($state -eq "Running" -or (-not $sawRunning -and (Get-Date) -lt $renderStart.AddSeconds(20))))
                    $taskInfo = Get-ScheduledTaskInfo -TaskName $RenderTaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
                    if ($state -eq "Running") { $warnings++; Say "WARNING: the renderer was still running after $RenderWaitSeconds seconds." } elseif ($null -ne $taskInfo) { Say ("Render task last result: 0x{0:X}" -f $taskInfo.LastTaskResult) }
                } catch {
                    $warnings++
                    Say "Could not start ${RenderTaskName}: $($_.Exception.Message)"
                }
                # Start the display watcher for whoever is signed in now, instead of waiting for their next sign-in
                if ($watchRegistered) {
                    try { Start-ScheduledTask -TaskName $WatchTaskName -TaskPath $TaskPath -ErrorAction Stop; Say "Started $TaskPath$WatchTaskName for the signed-in user(s)." } catch { $warnings++; Say "Could not start ${WatchTaskName}: $($_.Exception.Message)" }
                }
                foreach ($sessionUser in $sessionUsers) {
                    $profilePath = [string](Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$($sessionUser.Sid)'" -ErrorAction SilentlyContinue).LocalPath
                    if ([string]::IsNullOrWhiteSpace($profilePath)) { $warnings++; Say "Could not find the profile folder for $($sessionUser.Name)."; continue }
                    $userLog = Join-Path $profilePath "AppData\Local\$OrgFolder\DesktopInfo\DesktopInfo.log"
                    $logItem = Get-Item -LiteralPath $userLog -ErrorAction SilentlyContinue
                    if ($null -eq $logItem -or $logItem.LastWriteTime -lt $renderStart.AddSeconds(-5)) { $warnings++; Say "No new render log for $($sessionUser.Name) at $userLog"; continue }
                    Say "Render log for $($sessionUser.Name):"
                    $logLines = @(Get-Content -LiteralPath $userLog -ErrorAction SilentlyContinue)
                    foreach ($logLine in $logLines) { Say "  [render] $logLine" }
                    if ($logLines -notcontains "Wallpaper applied.") { $warnings++; Say "WARNING: the render log for $($sessionUser.Name) does not show the wallpaper being applied." }
                }
            }
        }
        # ----- Retire old folders and packages -----
        # Only after the new lock screen rendered in this run: until then the current lock screen may still point into the old folders.
        if ($CleanupOldBuilds -and -not $lockRendered) {
            $warnings++
            Say "WARNING: the old folders were not removed because the new lock screen has not been rendered in this run, and the current lock screen may still point into them. Rerun once the lock screen renders."
        } elseif ($CleanupOldBuilds) {
            Say "Removing old folders"
            foreach ($oldFolder in $OldFolders) {
                if ([string]::IsNullOrWhiteSpace($oldFolder) -or $oldFolder.Length -le 3) { continue }
                if ($oldFolder.TrimEnd("\").StartsWith($RootFolder, [System.StringComparison]::OrdinalIgnoreCase)) { Say "  Skipping $oldFolder because it is inside $RootFolder"; continue }
                Remove-Tree -Path $oldFolder
            }
            if ($script:treeProblem) { $warnings++ }
            foreach ($oldKeyName in $OldDetectionKeys) {
                if ([string]::IsNullOrWhiteSpace($oldKeyName)) { continue }
                foreach ($uninstallRoot in $UninstallRoots) { $oldKey = Join-Path $uninstallRoot $oldKeyName; if (Test-Path $oldKey) { Remove-Item -Path $oldKey -Recurse -Force -ErrorAction SilentlyContinue; Say "  Removed old detection key $oldKey" } }
            }
        }
        # ----- Detection key -----
        # RMM tools and Intune can read DisplayName and DisplayVersion from this Uninstall key to tell whether this version is installed.
        # SystemComponent hides it from Apps and Features. Written last, so a failed install is never reported as installed.
        try {
            foreach ($uninstallRoot in $UninstallRoots) {
                $detectKey = Join-Path $uninstallRoot $DetectionKeyName
                if (-not (Test-Path $detectKey)) { New-Item -Path $detectKey -Force -ErrorAction Stop | Out-Null }
                Set-ItemProperty -Path $detectKey -Name "DisplayName" -Value $PackageName -Type String -ErrorAction Stop
                Set-ItemProperty -Path $detectKey -Name "DisplayVersion" -Value $PackageVersion -Type String -ErrorAction Stop
                Set-ItemProperty -Path $detectKey -Name "Publisher" -Value $OrgName -Type String -ErrorAction Stop
                Set-ItemProperty -Path $detectKey -Name "InstallLocation" -Value $RootFolder -Type String -ErrorAction Stop
                Set-ItemProperty -Path $detectKey -Name "InstallDate" -Value (Get-Date -Format "yyyyMMdd") -Type String -ErrorAction Stop
                Set-ItemProperty -Path $detectKey -Name "NoRemove" -Value 1 -Type DWord -ErrorAction Stop
                Set-ItemProperty -Path $detectKey -Name "NoModify" -Value 1 -Type DWord -ErrorAction Stop
                Set-ItemProperty -Path $detectKey -Name "SystemComponent" -Value 1 -Type DWord -ErrorAction Stop
            }
            Say "Wrote the detection key: $PackageName $PackageVersion"
        } catch {
            Say "Could not write the detection key: $($_.Exception.Message)"
            return 1
        }
        if ($warnings -gt 0) { Say "Installed with $warnings warning(s). See the WARNING lines above. Exit code $WarningExitCode."; return $WarningExitCode }
        Say "Done. Desktop and lock screen info are installed."
        return 0
    } catch {
        # Anything not handled above. Without this an unexpected error could end with no return value, which would be read as exit 0.
        Say "FAILED: $($_.Exception.Message) (master line $($_.InvocationInfo.ScriptLineNumber)). The install did not finish. Check the lines above for what was already changed."
        return 1
    } finally {
        # Always save Deploy.log, even after a failure, so the run can be read on the PC later.
        if (Test-Path -LiteralPath $LogFolder) {
            try { [System.IO.File]::WriteAllLines((Join-Path $LogFolder "Deploy.log"), [string[]]$deployLines, (New-Object System.Text.UTF8Encoding($false))) } catch { Write-Host "Could not write Deploy.log: $($_.Exception.Message)" }
        }
    }
}
# The only exit, and it must stay the last line. RMM tools often feed scripts to PowerShell through stdin, and an exit anywhere
# else closes the pipe early. Check the script with the PowerShell parser after every edit.
exit (Invoke-DeployDesktopInfo)
