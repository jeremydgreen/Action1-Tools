# Changelog

## 1.0.0 (2026-11-13)

First public release.

- Session-aware detection of Action1 remote desktop sessions, with a start delay and end grace period.
- Click-through, always-on-top badge with an elapsed timer and hover fade.
- Install, update and remove from one deploy script. The watcher is embedded.
- Skips on machines where Unified Write Filter is protecting the drive.
- Read-only status script for troubleshooting a badge that will not clear.
- All organization-specific names are settings: `$OrgFolder` sets the install folder, task folder and log folder.
