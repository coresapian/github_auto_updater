# GitHub Auto Updater iOS App

This repo contains a real SwiftUI iOS app project plus a small Mac-side helper server.

Why there is a helper server:
- An iPhone app cannot directly inspect cron jobs, shell scripts, and log files on your Mac.
- So the app talks to a tiny local HTTP server running on the Mac.
- The helper server reads the existing updater logs, exposes status to the iOS app over your local network, and can optionally accept a local POST request to run the updater immediately.

Contents:
- `GitHubAutoUpdaterApp/` — SwiftUI iOS app source
- `helper/status_server.py` — Mac-side status API and manual-run endpoint
- `project.yml` — XcodeGen project spec

Quick start:
1. Generate the Xcode project:
   `xcodegen generate`
2. Start the helper server on your Mac:
   `python3 helper/status_server.py`
3. Open `GitHubAutoUpdaterApp.xcodeproj` in Xcode.
4. Run the app in the simulator or on device.
5. In Settings, enter the Mac helper server URL.
6. Optional: enter the manual-run token if you enabled one on the helper.

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

Pairing flow:
1. Start the helper server on your Mac:
   `python3 helper/status_server.py`
2. Note the pairing code printed by the helper, or fetch it from:
   `GET /pairing/status`
3. In the iOS app Settings tab, enter:
   - Mac helper URL
   - device name
   - pairing code
4. Tap `Pair with Mac helper`.
5. The app exchanges the code for a bearer token and stores it in Keychain.
6. Future status/log reads and manual updater requests use that saved token automatically.

Helper endpoints:
- `GET /pairing/status`
- `POST /pairing/exchange`
- `GET /status`
- `GET /log/main`
- `GET /log/alert`
- `GET /log/repo/<repo>`
- `POST /run-updater`

Notes:
- This is a real iOS app scaffold, not a Tkinter wrapper.
- Finder-opening and crontab-editing remain Mac-only operations, so those stay on the Mac helper side rather than the iPhone UI.
- The helper supports optional env-based tokens, but pairing now provides app-specific bearer tokens for devices on your local network.

- `GET /log/repo/<repo-name>`

Manual run endpoint:
- `POST /run-updater`
- The helper only accepts manual POSTs from loopback or private-network client IPs.
- Loopback requests work without a token.
- LAN requests require the helper to be started with `GITHUB_AUTO_UPDATER_HELPER_TOKEN` set, and the client must send the same value in the `X-Updater-Token` header.
- The helper runs the existing updater script in the background and exposes in-memory run state, timestamps, exit code, latest summary, and coarse progress based on updated per-repo logs.

Example helper startup with token enabled:
- `GITHUB_AUTO_UPDATER_HELPER_TOKEN=change-me python3 helper/status_server.py`

Example local manual run from the Mac itself:
- `curl -X POST http://127.0.0.1:8787/run-updater -H 'Content-Type: application/json' -d '{"requestedBy":"manual"}'`

Example LAN manual run with token:
- `curl -X POST http://192.168.1.25:8787/run-updater -H 'Content-Type: application/json' -H 'X-Updater-Token: change-me' -d '{"requestedBy":"ios"}'`

iOS UI notes:
- Dashboard now includes a `Run updater now` control.
- The dashboard shows the current or most recent manual action, recent action history, and last known updater summary counts.
- Settings now include a field for the helper POST token.
- The app auto-refreshes on the configured interval so a running manual action can update without repeatedly tapping Refresh.

Notes:
- This is a real iOS app scaffold, not a Tkinter wrapper.
- Finder-opening and crontab-editing remain Mac-only operations, so those stay on the Mac helper side rather than the iPhone UI.
