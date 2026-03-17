# GitHub Auto Updater iOS App

This repo contains a real SwiftUI iOS app project plus a small Mac-side helper server.

Why there is a helper server:
- An iPhone app cannot directly inspect cron jobs, shell scripts, and log files on your Mac.
- So the app talks to a tiny local HTTP server running on the Mac.
- The helper server reads the existing updater logs and exposes status to the iOS app over your local network.

Contents:
- `GitHubAutoUpdaterApp/` — SwiftUI iOS app source
- `helper/status_server.py` — Mac-side status API
- `project.yml` — XcodeGen project spec

Quick start:
1. Generate the Xcode project:
   `xcodegen generate`
2. Start the helper server on your Mac:
   `python3 helper/status_server.py`
3. Open `GitHubAutoUpdaterApp.xcodeproj` in Xcode.
4. Run the app in the simulator or on device.
5. In Settings, enter the Mac helper server URL.

Default helper URL on the same Mac:
- `http://127.0.0.1:8787`

For a physical iPhone on your LAN, use your Mac's local IP, for example:
- `http://192.168.1.25:8787`

Current monitored assets on the Mac:
- cron entry: `*/30 * * * * /Users/core/.local/bin/github-auto-update.sh`
- updater script: `/Users/core/.local/bin/github-auto-update.sh`
- main log: `/Users/core/.local/var/log/github-auto-update.log`
- alert log: `/Users/core/.local/var/log/github-auto-update.alert.log`
- per-repo logs: `/Users/core/.local/var/log/github-auto-update/`

Notes:
- This is a real iOS app scaffold, not a Tkinter wrapper.
- Finder-opening and crontab-editing remain Mac-only operations, so those stay on the Mac helper side rather than the iPhone UI.
