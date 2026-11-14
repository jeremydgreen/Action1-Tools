# Remote Session Badge

Shows a small red badge at the top of the user's screen while an Action1 remote desktop session is connected, and removes it when the session ends.

Example badge text:

```
IT Remote Desktop Session is Connected (00:04:12)
Contact your IT help desk if this is not expected
```

## Why I built it

When a tech connects through Action1 remote desktop, they can see everything on the user's screen: email, open documents, personal messages. By default, the user gets little or no ongoing sign that this is happening. I think users deserve to know when someone can see their screen.

Remote sessions are also easy to forget. A tech finishes up, closes the window, and never disconnects, so the session stays open. Or a session gets opened that the user never expected.

The badge solves both problems. It tells the user, clearly and the whole time, that IT can see their screen right now, and for how long. A forgotten or unexpected session gets noticed, and the user knows who to call if they did not ask for help.

It is built to stay out of the way:

- Always on top, but click-through. It never takes focus and does not show in the taskbar or Alt+Tab.
- Fades while the mouse pointer is over it, so the tech can see what is behind it.
- Waits a few seconds before showing and before hiding, so brief helper processes do not make it flicker.

This is an awareness indicator, not a security control. Anyone with SYSTEM-level access can stop it.

## How it works

Action1 keeps `action1_remote.exe` processes running in session 0 even when nobody is connected. During a real remote session, an `action1_remote.exe` runs inside the signed-in user's own session, because screen capture and input have to happen there. The watcher only counts processes in its own session, so idle Action1 processes do not trigger it.

The deploy script writes the watcher to disk and registers a scheduled task that starts it at every sign-in, as the signed-in user.

## Files

| File | Purpose |
| --- | --- |
| `Deploy-RemoteSessionBadge.ps1` | Installs, updates or removes the badge. Run as SYSTEM. The watcher is embedded inside it, so this is the only file you deploy. |
| `Get-RemoteSessionBadgeStatus.ps1` | Read-only diagnostic for when a badge will not clear. Changes nothing. |

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1
- Action1 agent (for detection)
- PowerShell in FullLanguage mode for signed-in users (the watcher exits if it finds Constrained Language Mode)

## Settings

All settings are in the editable block at the top of `Deploy-RemoteSessionBadge.ps1`. There are no parameters.

| Setting | Default | Purpose |
| --- | --- | --- |
| `$Action` | `Install` | `Install` or `Remove`. |
| `$OrgFolder` | `YourOrg` | Short name for your organization, no spaces. Used for the install folder, the task folder and each user's log folder. |
| `$InstallFolder` | `C:\Windows\Web\<OrgFolder>\RemoteSessionBadge` | Where the watcher and its settings file are written. |
| `$TaskName` | `Remote Session Badge` | Scheduled task name. |
| `$TaskPath` | `\<OrgFolder>\` | Scheduled task folder. |
| `$BadgeLine1` | `IT Remote Desktop Session is Connected ({elapsed})` | First line of the badge. `{elapsed}` shows the session time. |
| `$BadgeLine2` | `Contact your IT help desk if this is not expected` | Second line. Leave blank for a one-line badge. Put your help desk number here. |
| `$StartDelaySeconds` | `10` | Seconds a session must be detected before the badge appears. |
| `$EndGraceSeconds` | `8` | Seconds after a session ends before the badge disappears. |
| `$PollSeconds` | `2` | How often to check for a session. |
| `$BadgeBackColor` | `#B00020` | Badge color. |
| `$BadgeTextColor` | `#FFFFFF` | Text color. |
| `$BadgeOpacity` | `0.9` | 0.3 to 0.99. Capped at 0.99 so the badge stays click-through. |
| `$HoverFade` | `$true` | Fade the badge while the pointer is over it. |
| `$HoverOpacity` | `0.15` | Opacity while faded. |
| `$FontName` / `$FontSize` | `Arial` / `11` | Badge font. |
| `$MarginTop` | `6` | Pixels from the top of the screen. |
| `$DiagnosticLogging` | `$false` | Log every change in the set of `action1_remote` processes. |
| `$SkipWhenUWFEnabled` | `$true` | Skip with exit code 2 when Unified Write Filter is protecting the drive, since changes would be lost at restart. |
| `$UseHeadlessConhost` | `$true` | Launch through `conhost --headless` so no console window flashes at sign-in. |

If you change `$OrgFolder`, `$InstallFolder`, `$TaskName` or `$TaskPath`, make the same change in `Get-RemoteSessionBadgeStatus.ps1`.

## Deploy with Action1

1. Edit the settings block, at least `$OrgFolder` and `$BadgeLine2`.
2. Add `Deploy-RemoteSessionBadge.ps1` to your Action1 script library as a PowerShell script.
3. Run it on a test machine with a user signed in. Then start a remote session to that machine and confirm the badge appears after about 10 seconds and clears after you disconnect.
4. Deploy to the rest of your endpoints.

To change the badge text or timing later, edit the settings and run the script again. It stops running watchers so the new settings apply right away.

No reboot is needed. The badge starts for whoever is signed in now and for everyone at their next sign-in.

## Remove

Set `$Action = "Remove"` and run the script again. It stops running watchers, deletes the scheduled task and removes the install folder.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Failure. Check the script output. |
| 2 | Skipped because Unified Write Filter is protecting the drive. Run it again in your servicing window. |

## Troubleshooting

If a badge will not clear, run `Get-RemoteSessionBadgeStatus.ps1` from Action1 right away, before anyone signs out, restarts or redeploys. Each watcher overwrites its log when it starts, so those actions erase the evidence.

The report shows signed-in sessions, every `action1_remote.exe` with its session and start time, every PowerShell process (so a leftover test copy of the watcher shows up), the installed files and task, and each user's badge log. It does not print `action1_remote.exe` command lines, since they can carry connection details.

Each user's log is at `%LOCALAPPDATA%\<OrgFolder>\RemoteSessionBadge\RemoteSession.log`.

## Known limitations

- Shows on the primary monitor only.
- Action1 can show the user an Accept/No prompt for up to 15 seconds. If the user takes longer than `$StartDelaySeconds` to answer No, the badge can appear briefly and then clear.
- Built and tested for Action1. Other remote tools may work by changing `$ProcessName` in the embedded watcher to a process that runs inside the user's session only during a remote session, but that has not been tested.
- Not a security control. It shows that a session exists; it does not block or audit anything.

## License

MIT. See the [LICENSE](../LICENSE) file in the root of this repository.

Author: Jeremy Green
