# Deploy-RemoteSessionBadge.ps1
# Version: 1.0.0
# Author: Jeremy Green
# Copyright (c) 2026 Jeremy Green
# SPDX-License-Identifier: MIT
# Source: https://github.com/jeremydgreen/Action1-Tools
# Shared under the MIT License. Keep this header in any copy or modified version.
# Built with AI assistance; designed, tested and maintained by the author.
# Installs the remote session badge. Push it from Action1 (or another RMM tool) and run it as SYSTEM. It does not install Action1.
# Install: writes Watch-RemoteSession.ps1 and its settings file to $InstallFolder, registers a logon task that starts the watcher
# for every user who signs in, stops any watcher already running so new settings take effect, then starts it for whoever is signed in now.
# Remove: stops running watchers, unregisters the task, and deletes the install folder.
# To change the badge text or timing later, edit the settings below and run it again with $Action = "Install".
# The watcher script is embedded below as a here-string. Change behavior through the settings block, not the embedded copy.
# On UWF-protected machines, run this in the servicing window. With the filter on, the files and task would disappear at the next restart,
# so the script skips and returns exit code 2 unless $SkipWhenUWFEnabled is $false.
# Exit codes: 0 = success, 1 = failure, 2 = skipped because UWF is protecting the drive.
# Logging uses Write-Host on purpose. Write-Output inside the function becomes part of the return value that exit consumes.
function Invoke-DeployRemoteSessionBadge {
    # ===== Editable settings =====
    # Install or Remove
    $Action = "Install"
    # Short name for your organization, no spaces. Used for the install folder, the task folder and each user's log folder.
    $OrgFolder = "YourOrg"
    $InstallFolder = "C:\Windows\Web\$OrgFolder\RemoteSessionBadge"
    $TaskName = "Remote Session Badge"
    $TaskPath = "\$OrgFolder\"
    # Badge text. {elapsed} shows how long the session has been connected. Leave BadgeLine2 blank for a one-line badge.
    $BadgeLine1 = "IT Remote Desktop Session is Connected ({elapsed})"
    $BadgeLine2 = "Contact your IT help desk if this is not expected"
    # Seconds a session must be detected before the badge appears, and seconds after it ends before the badge disappears
    $StartDelaySeconds = 10
    $EndGraceSeconds = 8
    $PollSeconds = 2
    $BadgeBackColor = "#B00020"
    $BadgeTextColor = "#FFFFFF"
    $BadgeOpacity = 0.9
    # Fade the badge while the mouse pointer is over it, so a tech can see what is behind it. Clicks pass through either way.
    $HoverFade = $true
    # Opacity while faded, from 0.05 up to $BadgeOpacity. Lower is easier to see through.
    $HoverOpacity = 0.15
    $FontName = "Arial"
    $FontSize = 11
    $MarginTop = 6
    # Detailed process logging in each user's RemoteSession.log. Session start and end are always logged.
    $DiagnosticLogging = $false
    $SkipWhenUWFEnabled = $true
    # Launch through conhost --headless so no console window flashes at sign-in
    $UseHeadlessConhost = $true
    # =============================
    # ----- Embedded watcher script. Do not edit here; use the settings above. -----
    $WatcherScript = @'
# Watch-RemoteSession.ps1
# Part of Remote Session Badge 1.0.0 by Jeremy Green. MIT License. https://github.com/jeremydgreen/Action1-Tools
# Shows a small on-screen badge while an Action1 remote desktop session is connected, and removes it when the session ends.
# Runs as the signed-in user from a logon task and stays running for the whole session. Only one copy runs per session.
# Detection: Action1 keeps action1_remote.exe processes running in session 0 even when nobody is connected, so counting the
# process anywhere gives false alarms and never clears. Screen capture and input have to happen inside the user's own session,
# so during a real remote session an action1_remote.exe runs in that session. Session mode (the default) treats the remote
# session as active only while one is running in the same session as this script.
# The signal must stay on for $StartDelaySeconds before the badge appears, and stay off for $EndGraceSeconds before it disappears.
# A gap shorter than $EndGraceSeconds does not restart the start countdown, so a handoff between Action1 helper processes counts as one session.
# Test it with powershell.exe -File in a normal console, not the ISE. If the script is stopped mid-run, a guard ends the badge loop cleanly.
# Action1 shows an Accept/No prompt for up to 15 seconds by default. If that prompt runs in the user's session and someone takes longer than the start delay to answer No, the badge can appear briefly and then clear.
# The settings below are defaults. If RemoteSessionBadge.json sits next to this script (written by Deploy-RemoteSessionBadge.ps1), its values override them.
# The badge text avoids the word Action1, since users will not know what it is.
# Diagnostic logging records every change in the set of action1_remote processes and their sessions.
# The badge is always on top, click-through, never takes focus, and does not appear in the taskbar or Alt+Tab.
# Hover fade: while the badge is showing, the mouse pointer is checked 5 times a second. When it is over the badge, the badge fades to
# $HoverOpacity so a tech can see what is behind it, and it returns to normal when the pointer moves away. The tech and the user share
# one pointer during a session, so it works the same for both. Clicks pass through the badge whether it is faded or not.
# Click-through only works while the badge is a layered window, and WinForms only makes it layered below full opacity. That is why
# opacity is capped at 0.99. Do not remove that cap.
# This is an awareness indicator, not a security control. Anyone with SYSTEM-level access, including an Action1 script, can stop it.
# MUST run as the signed-in user, not SYSTEM, so the badge appears on the user's desktop.
# Logging uses Write-Host plus a log file, because a logon task has no visible console.
function Invoke-WatchRemoteSession {
    # ===== Editable settings =====
    $ProcessName = "action1_remote"
    # Session = an action1_remote process is running in this user's session. Process = running in any session (not recommended).
    $DetectMode = "Session"
    $PollSeconds = 2
    # The signal must stay on this long before the badge appears. Filters brief helper launches that are not sessions.
    $StartDelaySeconds = 10
    # The signal must stay off this long before the badge disappears.
    $EndGraceSeconds = 8
    # Logs every change in the set of action1_remote processes. Session start and end are always logged.
    $DiagnosticLogging = $false
    # Badge text. {elapsed} shows how long the session has been connected. Leave BadgeLine2 blank for a one-line badge.
    $BadgeLine1 = "IT Remote Desktop Session is Connected ({elapsed})"
    $BadgeLine2 = "Contact your IT help desk if this is not expected"
    $BadgeBackColor = "#B00020"
    $BadgeTextColor = "#FFFFFF"
    # 0.3 to 0.99. Anything higher is capped at 0.99 so the badge stays click-through.
    $BadgeOpacity = 0.9
    # Fade the badge while the mouse pointer is over it, so a tech can see what is behind it.
    $HoverFade = $true
    # Opacity while faded, from 0.05 up to $BadgeOpacity. Lower is easier to see through.
    $HoverOpacity = 0.15
    $FontName = "Arial"
    $FontSize = 11
    $MarginTop = 6
    # Short name for your organization, no spaces. The log goes to %LOCALAPPDATA%\<OrgFolder>\RemoteSessionBadge.
    $OrgFolder = "YourOrg"
    # =============================
    $configNote = "none found, using built-in settings"
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $configPath = Join-Path $PSScriptRoot "RemoteSessionBadge.json"
        if (Test-Path -LiteralPath $configPath) {
            try {
                $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $allowed = @("ProcessName", "DetectMode", "PollSeconds", "StartDelaySeconds", "EndGraceSeconds", "DiagnosticLogging", "BadgeLine1", "BadgeLine2", "BadgeBackColor", "BadgeTextColor", "BadgeOpacity", "HoverFade", "HoverOpacity", "FontName", "FontSize", "MarginTop", "OrgFolder")
                foreach ($prop in $cfg.PSObject.Properties) { if ($allowed -contains $prop.Name) { Set-Variable -Name $prop.Name -Value $prop.Value } }
                $configNote = $configPath
            } catch {
                $configNote = "could not be read ($($_.Exception.Message)), using built-in settings"
            }
        }
    }
    $LogFolder = Join-Path $env:LOCALAPPDATA (Join-Path $OrgFolder "RemoteSessionBadge")
    if ($ExecutionContext.SessionState.LanguageMode -ne "FullLanguage") {
        Write-Host "PowerShell is running in $($ExecutionContext.SessionState.LanguageMode) for this user. This script needs FullLanguage."
        return 1
    }
    if ([System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        Write-Host "This script must run as the signed-in user, not SYSTEM."
        return 1
    }
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, "Local\RemoteSessionBadge_Watcher", [ref]$createdNew)
    if (-not $createdNew) {
        Write-Host "Another copy is already running in this session. Exiting."
        $mutex.Dispose()
        return 0
    }
    if (-not (Test-Path $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
    $logPath = Join-Path $LogFolder "RemoteSession.log"
    Set-Content -Path $logPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Watch-RemoteSession started as $env:USERDOMAIN\$env:USERNAME" -Encoding UTF8 -ErrorAction SilentlyContinue
    function Write-Log { param([string]$Text) $stamped = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text"; Write-Host $stamped; Add-Content -Path $logPath -Value $stamped -Encoding UTF8 -ErrorAction SilentlyContinue }
    if (@("Session", "Process") -notcontains $DetectMode) {
        Write-Log "Unknown DetectMode '$DetectMode'. Using Session."
        $DetectMode = "Session"
    }
    $mySession = (Get-Process -Id $PID).SessionId
    Write-Log "Settings file: $configNote"
    Write-Log "Settings: DetectMode $DetectMode, this session $mySession, poll $PollSeconds s, start delay $StartDelaySeconds s, end grace $EndGraceSeconds s, hover fade $HoverFade at $HoverOpacity, diagnostics $DiagnosticLogging"
    $timer = $null
    $form = $null
    $badgeFont = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        if (-not ([System.Management.Automation.PSTypeName]"RemoteSessionBadgeForm").Type) {
            Add-Type -WarningAction SilentlyContinue -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition 'using System.Windows.Forms; public class RemoteSessionBadgeForm : Form { protected override bool ShowWithoutActivation { get { return true; } } protected override CreateParams CreateParams { get { CreateParams cp = base.CreateParams; cp.ExStyle = cp.ExStyle | 0x00000080 | 0x00000020 | 0x08000000 | 0x00000008; return cp; } } }'
        }
        if (-not ([System.Management.Automation.PSTypeName]"RemoteSessionBadgeGuard").Type) {
            Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition 'using System; using System.Threading; using System.Windows.Forms; public static class RemoteSessionBadgeGuard { private static ThreadExceptionEventHandler handler; public static void Attach(System.Windows.Forms.Timer timer) { Detach(); handler = delegate(object sender, ThreadExceptionEventArgs e) { try { timer.Stop(); } catch { } Application.ExitThread(); }; Application.ThreadException += handler; } public static void Detach() { if (handler != null) { Application.ThreadException -= handler; handler = null; } } }'
        }
        $normalOpacity = [Math]::Max(0.3, [Math]::Min(0.99, [double]$BadgeOpacity))
        $fadedOpacity = [Math]::Max(0.05, [Math]::Min($normalOpacity, [double]$HoverOpacity))
        $badgeFont = [System.Drawing.Font]::new($FontName, [float]$FontSize, [System.Drawing.FontStyle]::Bold)
        $form = [RemoteSessionBadgeForm]::new()
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $form.ShowInTaskbar = $false
        $form.TopMost = $true
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.BackColor = [System.Drawing.ColorTranslator]::FromHtml($BadgeBackColor)
        $form.AllowTransparency = $true
        $form.Opacity = $normalOpacity
        $label = [System.Windows.Forms.Label]::new()
        $label.AutoSize = $true
        $label.Font = $badgeFont
        $label.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($BadgeTextColor)
        $label.BackColor = $form.BackColor
        $label.Padding = [System.Windows.Forms.Padding]::new(14, 5, 14, 5)
        $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $label.Location = [System.Drawing.Point]::new(0, 0)
        $form.Controls.Add($label)
        # Timing: while the badge is hidden, the timer ticks once per poll. While it is showing (and hover fade is on), the timer ticks
        # every $hoverMs for the pointer check, and the process check still runs only once per poll. A stopwatch paces the process
        # check so a clock change cannot pause it.
        $pollMs = [int]([Math]::Max(1, $PollSeconds) * 1000)
        $hoverMs = 200
        # Pixels around the badge that also count as over it, so it starts fading just before the pointer arrives.
        $hoverMargin = 12
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $state = @{ Active = $false; Since = $null; FirstOn = $null; LastOn = $null; LastSignal = $false; LastProcKey = $null; Text = ""; LastCheckMs = $null; Faded = $false; HoverError = $false }
        $timer = [System.Windows.Forms.Timer]::new()
        $timer.Interval = $pollMs
        $timer.Add_Tick({
            try {
                $now = Get-Date
                $nowMs = $clock.ElapsedMilliseconds
                # 100 ms of slack absorbs normal timer jitter so a check is not skipped by a few milliseconds.
                if ($null -eq $state.LastCheckMs -or ($nowMs - $state.LastCheckMs) -ge ($pollMs - 100)) {
                    $state.LastCheckMs = $nowMs
                    $procs = [System.Diagnostics.Process]::GetProcessesByName($ProcessName)
                    $procInfo = @($procs | ForEach-Object { [pscustomobject]@{ Id = $_.Id; SessionId = $_.SessionId } } | Sort-Object Id)
                    foreach ($p in $procs) { $p.Dispose() }
                    $inMySession = @($procInfo | Where-Object { $_.SessionId -eq $mySession }).Count
                    if ($DetectMode -eq "Process") { $signal = ($procInfo.Count -gt 0) } else { $signal = ($inMySession -gt 0) }
                    if ($DiagnosticLogging) {
                        $procKey = ($procInfo | ForEach-Object { "PID $($_.Id) session $($_.SessionId)" }) -join ", "
                        if ([string]::IsNullOrWhiteSpace($procKey)) { $procKey = "none running" }
                        if ($procKey -ne $state.LastProcKey) {
                            Write-Log "Process set changed: $procKey"
                            $state.LastProcKey = $procKey
                        }
                    }
                    if ($signal -ne $state.LastSignal) {
                        if ($signal) { $signalWord = "ON" } else { $signalWord = "OFF" }
                        Write-Log ("Signal {0}: {1} in this session (session {2}), {3} total." -f $signalWord, $inMySession, $mySession, $procInfo.Count)
                        $state.LastSignal = $signal
                    }
                    if ($signal) {
                        $state.LastOn = $now
                        if (-not $state.Active) {
                            if ($null -eq $state.FirstOn) { $state.FirstOn = $now }
                            if (($now - $state.FirstOn).TotalSeconds -ge $StartDelaySeconds) {
                                $state.Active = $true
                                $state.Since = $state.FirstOn
                                Write-Log "Remote session confirmed after $StartDelaySeconds seconds. Showing badge."
                            }
                        }
                    } else {
                        if (-not $state.Active) {
                            if ($null -ne $state.FirstOn -and ($now - $state.LastOn).TotalSeconds -ge $EndGraceSeconds) {
                                Write-Log ("Signal stayed off for {0} seconds before the start delay was reached. Not treated as a session." -f $EndGraceSeconds)
                                $state.FirstOn = $null
                            }
                        } elseif (($now - $state.LastOn).TotalSeconds -ge $EndGraceSeconds) {
                            $state.Active = $false
                            $state.FirstOn = $null
                            $duration = $now - $state.Since
                            Write-Log ("Remote session ended after {0:00}:{1:00}:{2:00}. Hiding badge." -f [Math]::Floor($duration.TotalHours), $duration.Minutes, $duration.Seconds)
                            $state.Text = ""
                            $form.Hide()
                        }
                    }
                }
                if ($state.Active) {
                    $elapsed = $now - $state.Since
                    $elapsedText = "{0:00}:{1:00}:{2:00}" -f [Math]::Floor($elapsed.TotalHours), $elapsed.Minutes, $elapsed.Seconds
                    $badgeLines = @(@($BadgeLine1, $BadgeLine2) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Replace("{elapsed}", $elapsedText) })
                    if ($badgeLines.Count -eq 0) { $badgeLines = @("Remote desktop session connected ($elapsedText)") }
                    $text = $badgeLines -join [Environment]::NewLine
                    if ($text -ne $state.Text) {
                        $state.Text = $text
                        $label.Text = $text
                        $form.ClientSize = $label.PreferredSize
                        $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
                        $form.Location = [System.Drawing.Point]::new([int]($area.X + (($area.Width - $form.Width) / 2)), [int]($area.Y + $MarginTop))
                    }
                    if (-not $form.Visible) { $form.Show() }
                }
            } catch {
                Write-Log "Check failed: $($_.Exception.Message)"
            }
            try {
                $watchPointer = ($HoverFade -and $form.Visible)
                if ($watchPointer) { $wantMs = $hoverMs } else { $wantMs = $pollMs }
                if ($timer.Interval -ne $wantMs) { $timer.Interval = $wantMs }
                $over = $false
                if ($watchPointer) {
                    $hitArea = [System.Drawing.Rectangle]::Inflate($form.Bounds, $hoverMargin, $hoverMargin)
                    $over = $hitArea.Contains([System.Windows.Forms.Cursor]::Position)
                }
                if ($over -ne $state.Faded) {
                    $state.Faded = $over
                    if ($over) { $form.Opacity = $fadedOpacity } else { $form.Opacity = $normalOpacity }
                }
            } catch {
                if (-not $state.HoverError) {
                    $state.HoverError = $true
                    Write-Log "Hover check failed: $($_.Exception.Message)"
                }
                if ($state.Faded) {
                    $state.Faded = $false
                    try { $form.Opacity = $normalOpacity } catch { }
                }
            }
        })
        [RemoteSessionBadgeGuard]::Attach($timer)
        $timer.Start()
        Write-Log "Watching for $ProcessName every $PollSeconds second(s)."
        [System.Windows.Forms.Application]::Run([System.Windows.Forms.ApplicationContext]::new())
        Write-Log "Badge loop ended."
        return 0
    } catch {
        Write-Log "Watcher failed: $($_.Exception.Message)"
        return 1
    } finally {
        if (([System.Management.Automation.PSTypeName]"RemoteSessionBadgeGuard").Type) { try { [RemoteSessionBadgeGuard]::Detach() } catch { } }
        foreach ($obj in @($timer, $form, $badgeFont, $mutex)) { if ($null -ne $obj) { $obj.Dispose() } }
    }
}
exit (Invoke-WatchRemoteSession)
'@
    $watcherPath = Join-Path $InstallFolder "Watch-RemoteSession.ps1"
    $configPath = Join-Path $InstallFolder "RemoteSessionBadge.json"
    function Get-Watchers {
        return @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -ne $PID -and [string]$_.CommandLine -like "*Watch-RemoteSession.ps1*" })
    }
    function Stop-Watchers {
        $found = Get-Watchers
        foreach ($p in $found) {
            try {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
                Write-Host "Stopped running watcher PID $($p.ProcessId) in session $($p.SessionId)"
            } catch {
                Write-Host "Could not stop watcher PID $($p.ProcessId): $($_.Exception.Message)"
            }
        }
        if ($found.Count -eq 0) { Write-Host "No running watchers to stop." }
    }
    $principal = [System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "ERROR: this script must run as SYSTEM or an administrator."
        return 1
    }
    if (@("Install", "Remove") -notcontains $Action) {
        Write-Host "ERROR: Action must be Install or Remove. Current value: $Action"
        return 1
    }
    Write-Host "=== $Action ==="
    $uwfOn = $false
    try {
        $uwfFilter = Get-CimInstance -Namespace "root\standardcimv2\embedded" -ClassName "UWF_Filter" -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $uwfFilter -and $uwfFilter.CurrentEnabled -eq $true) { $uwfOn = $true }
    } catch {
        $uwfOn = $false
    }
    if ($uwfOn) {
        if ($SkipWhenUWFEnabled) {
            Write-Host "SKIPPED: UWF is protecting this drive, so changes would be lost at the next restart. Run this in the servicing window."
            return 2
        }
        Write-Host "WARNING: UWF is protecting this drive. Continuing because SkipWhenUWFEnabled is false, but changes will be lost at the next restart."
    }
    Stop-Watchers
    if ($Action -eq "Remove") {
        try {
            Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction Stop
            Write-Host "OK: task removed."
        } catch {
            Write-Host "Task not removed (it may not exist): $($_.Exception.Message)"
        }
        if (Test-Path -LiteralPath $InstallFolder) {
            try {
                Remove-Item -LiteralPath $InstallFolder -Recurse -Force -ErrorAction Stop
                Write-Host "OK: removed $InstallFolder"
            } catch {
                Write-Host "ERROR: could not remove ${InstallFolder}: $($_.Exception.Message)"
                return 1
            }
        }
        Write-Host "Remove complete."
        return 0
    }
    try {
        if (-not (Test-Path -LiteralPath $InstallFolder)) { New-Item -Path $InstallFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        Set-Content -LiteralPath $watcherPath -Value $WatcherScript -Encoding UTF8 -Force -ErrorAction Stop
        $config = [ordered]@{ BadgeLine1 = $BadgeLine1; BadgeLine2 = $BadgeLine2; StartDelaySeconds = $StartDelaySeconds; EndGraceSeconds = $EndGraceSeconds; PollSeconds = $PollSeconds; BadgeBackColor = $BadgeBackColor; BadgeTextColor = $BadgeTextColor; BadgeOpacity = $BadgeOpacity; HoverFade = $HoverFade; HoverOpacity = $HoverOpacity; FontName = $FontName; FontSize = $FontSize; MarginTop = $MarginTop; DiagnosticLogging = $DiagnosticLogging; OrgFolder = $OrgFolder }
        $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8 -Force -ErrorAction Stop
        Write-Host "OK: wrote $watcherPath"
        Write-Host "OK: wrote $configPath"
    } catch {
        Write-Host "ERROR: could not write the watcher files: $($_.Exception.Message)"
        return 1
    }
    $parseTokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($watcherPath, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        Write-Host "ERROR: the written watcher has syntax errors. First error: line $($parseErrors[0].Extent.StartLineNumber): $($parseErrors[0].Message)"
        return 1
    }
    Write-Host "OK: watcher script passes the PowerShell parser."
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $psArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $watcherPath + '"'
    if ($UseHeadlessConhost) {
        $taskCommand = Join-Path $env:SystemRoot "System32\conhost.exe"
        $taskArguments = "--headless " + $psExe + " " + $psArgs
    } else {
        $taskCommand = $psExe
        $taskArguments = $psArgs
    }
    $taskXml = "<Task version='1.2' xmlns='http://schemas.microsoft.com/windows/2004/02/mit/task'>"
    $taskXml += "<RegistrationInfo><Description>Shows an on-screen badge while an IT remote desktop session (Action1) is connected. Deployed by Deploy-RemoteSessionBadge.ps1.</Description></RegistrationInfo>"
    $taskXml += "<Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>"
    $taskXml += "<Principals><Principal id='Author'><GroupId>S-1-5-32-545</GroupId><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>"
    $taskXml += "<Settings><MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>false</StartWhenAvailable><RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings><AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>true</Hidden><RunOnlyIfIdle>false</RunOnlyIfIdle><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>7</Priority></Settings>"
    $taskXml += "<Actions Context='Author'><Exec><Command>" + [System.Security.SecurityElement]::Escape($taskCommand) + "</Command><Arguments>" + [System.Security.SecurityElement]::Escape($taskArguments) + "</Arguments></Exec></Actions>"
    $taskXml += "</Task>"
    try {
        Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Xml $taskXml -Force -ErrorAction Stop | Out-Null
        Write-Host "OK: task registered at $TaskPath$TaskName (runs at every sign-in as the signed-in user)."
    } catch {
        Write-Host "ERROR: task registration failed: $($_.Exception.Message)"
        return 1
    }
    try {
        Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
        Write-Host "Started the task for anyone signed in right now."
    } catch {
        Write-Host "Note: could not start the task now ($($_.Exception.Message)). It will start at the next sign-in."
    }
    Start-Sleep -Seconds 5
    $running = Get-Watchers
    if ($running.Count -gt 0) {
        foreach ($r in $running) { Write-Host "Watcher running: PID $($r.ProcessId) in session $($r.SessionId)" }
    } else {
        Write-Host "No watcher running yet. Expected if nobody is signed in; otherwise it starts at the next sign-in."
    }
    Write-Host "Install complete."
    return 0
}
exit (Invoke-DeployRemoteSessionBadge)
