# Get-RemoteSessionBadgeStatus.ps1
# Version: 1.0.0
# Author: Jeremy Green
# Copyright (c) 2026 Jeremy Green
# SPDX-License-Identifier: MIT
# Source: https://github.com/jeremydgreen/Action1-Tools
# Shared under the MIT License. Keep this header in any copy or modified version.
# Built with AI assistance; designed, tested and maintained by the author.
# Read-only diagnostic for the remote session badge. It changes nothing on the machine.
# Run it from Action1 (as SYSTEM) while a badge is stuck on screen, BEFORE anyone signs out, restarts, or redeploys.
# Each watcher overwrites its log when it starts, so a sign-out, restart, or redeploy erases the evidence.
# Reports: signed-in users and their session numbers, every action1_remote.exe with its session and start time, every PowerShell
# process (so a leftover test copy of the watcher shows up), the installed watcher and settings, and each user's badge log.
# Command lines of action1_remote.exe are not printed, since they can carry Action1 connection details.
# Logging uses Write-Host on purpose. Write-Output inside the function becomes part of the return value that exit consumes.
# Exit codes: 0 = report complete, 1 = report failed.
function Invoke-RemoteSessionBadgeStatus {
    # ===== Editable settings =====
    # Must match the OrgFolder, TaskName and InstallFolder settings used in Deploy-RemoteSessionBadge.ps1.
    $OrgFolder = "YourOrg"
    $ProcessName = "action1_remote.exe"
    $InstallFolder = "C:\Windows\Web\$OrgFolder\RemoteSessionBadge"
    $TaskName = "Remote Session Badge"
    $TaskPath = "\$OrgFolder\"
    $LogRelativePath = "AppData\Local\$OrgFolder\RemoteSessionBadge\RemoteSession.log"
    # Lines shown from the start and the end of each log. Shorter logs are shown in full.
    $LogHeadLines = 6
    $LogTailLines = 40
    # =============================
    try {
        $now = Get-Date
        Write-Host "=== Remote session badge status on $env:COMPUTERNAME at $($now.ToString('yyyy-MM-dd HH:mm:ss')) ==="
        Write-Host "--- Signed-in users ---"
        $shells = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction Stop | Sort-Object SessionId -Unique)
        if ($shells.Count -eq 0) { Write-Host "Nobody is signed in." }
        foreach ($s in $shells) {
            $owner = Invoke-CimMethod -InputObject $s -MethodName GetOwner -ErrorAction SilentlyContinue
            Write-Host ("Session {0}: {1}\{2}" -f $s.SessionId, $owner.Domain, $owner.User)
        }
        Write-Host "--- $ProcessName ---"
        $remote = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = '$ProcessName'" -ErrorAction Stop | Sort-Object SessionId, ProcessId)
        if ($remote.Count -eq 0) { Write-Host "None running." }
        foreach ($r in $remote) {
            $parent = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($r.ParentProcessId)" -ErrorAction SilentlyContinue
            if ($null -ne $parent) { $parentText = "$($parent.Name) PID $($parent.ProcessId)" } else { $parentText = "PID $($r.ParentProcessId), no longer running" }
            if ($null -ne $r.CreationDate) { $startText = "{0} ({1:0} min ago)" -f $r.CreationDate.ToString('yyyy-MM-dd HH:mm:ss'), ($now - $r.CreationDate).TotalMinutes } else { $startText = "unknown" }
            Write-Host ("PID {0}, session {1}, started {2}, threads {3}, parent {4}" -f $r.ProcessId, $r.SessionId, $startText, $r.ThreadCount, $parentText)
        }
        Write-Host "--- PowerShell processes (WATCHER = running the badge script) ---"
        $shellsPs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop | Where-Object { $_.ProcessId -ne $PID } | Sort-Object SessionId, ProcessId)
        if ($shellsPs.Count -eq 0) { Write-Host "None running." }
        foreach ($p in $shellsPs) {
            $cmd = [string]$p.CommandLine
            if ($cmd -like "*Watch-RemoteSession*") { $tag = "WATCHER" } else { $tag = "other" }
            if ($cmd.Length -gt 220) { $cmd = $cmd.Substring(0, 220) + "..." }
            if ($null -ne $p.CreationDate) { $startText = $p.CreationDate.ToString('yyyy-MM-dd HH:mm:ss') } else { $startText = "unknown" }
            Write-Host ("{0}: PID {1}, session {2}, started {3}, command: {4}" -f $tag, $p.ProcessId, $p.SessionId, $startText, $cmd)
        }
        Write-Host "--- Installed files and task ---"
        $watcherPath = Join-Path $InstallFolder "Watch-RemoteSession.ps1"
        $configPath = Join-Path $InstallFolder "RemoteSessionBadge.json"
        if (Test-Path -LiteralPath $watcherPath) {
            $wItem = Get-Item -LiteralPath $watcherPath
            $hoverBuild = [bool](Select-String -LiteralPath $watcherPath -Pattern "HoverFade" -SimpleMatch -Quiet)
            Write-Host ("Watcher written {0}, hover fade build: {1}" -f $wItem.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), $hoverBuild)
        } else {
            Write-Host "Watcher not found at $watcherPath"
        }
        if (Test-Path -LiteralPath $configPath) {
            Write-Host "Settings file:"
            Get-Content -LiteralPath $configPath | ForEach-Object { Write-Host "  $_" }
        } else {
            Write-Host "Settings file not found at $configPath"
        }
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
        if ($null -ne $task) { Write-Host "Task $TaskPath$TaskName is $($task.State)" } else { Write-Host "Task $TaskPath$TaskName not found." }
        Write-Host "--- Badge logs ---"
        $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop | Where-Object { -not $_.Special -and -not [string]::IsNullOrWhiteSpace($_.LocalPath) })
        $found = 0
        foreach ($prof in $profiles) {
            $logPath = Join-Path $prof.LocalPath $LogRelativePath
            if (-not (Test-Path -LiteralPath $logPath)) { continue }
            $found++
            try {
                $lines = @(Get-Content -LiteralPath $logPath -ErrorAction Stop)
                $logItem = Get-Item -LiteralPath $logPath
                Write-Host ("{0} ({1} lines, last written {2})" -f $logPath, $lines.Count, $logItem.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
                if ($lines.Count -le ($LogHeadLines + $LogTailLines)) {
                    $show = $lines
                } else {
                    $show = @($lines[0..($LogHeadLines - 1)]) + @("... $($lines.Count - $LogHeadLines - $LogTailLines) lines skipped ...") + @($lines[($lines.Count - $LogTailLines)..($lines.Count - 1)])
                }
                foreach ($l in $show) { Write-Host "  $l" }
            } catch {
                Write-Host "Could not read ${logPath}: $($_.Exception.Message)"
            }
        }
        if ($found -eq 0) { Write-Host "No badge logs found." }
        Write-Host "=== End of report ==="
        return 0
    } catch {
        Write-Host "ERROR: report failed: $($_.Exception.Message)"
        return 1
    }
}
exit (Invoke-RemoteSessionBadgeStatus)
