# Action1 Tools

PowerShell tools for Windows admins who manage endpoints with Action1 RMM, written by Jeremy Green.

Every script is built to run unattended as SYSTEM from an RMM tool. They are written and tested for [Action1](https://www.action1.com/), so they follow its rules: no parameters (all settings live in an editable block at the top of each script), no blank lines, and a single `exit` on the last line. They also work from other RMM tools, Intune or a scheduled task.

## Tools

Tools are being added one at a time. Each one gets its own folder with the script, a README and a changelog.

| Tool | What it does |
| --- | --- |
| [Remote Session Badge](RemoteSessionBadge/) | Lets users know when an IT tech can see their screen. Shows an on-screen badge with a timer while an Action1 remote desktop session is connected. |

## Using these scripts

1. Read the tool's README first.
2. Change the settings block at the top of the script to fit your environment.
3. Test on one machine before deploying widely.

## License

MIT License. See [LICENSE](LICENSE). You can use, change and share these scripts, as long as you keep the copyright notice and license text.

## Disclaimer

Not affiliated with or endorsed by any employer. Test before deploying. Provided as-is under the MIT License.
