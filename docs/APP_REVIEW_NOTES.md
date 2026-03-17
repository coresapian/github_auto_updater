# App Review Notes

## What the app does
GitHub Auto Updater monitors and controls a user-owned Mac helper that watches Git repositories and cron-driven update jobs.

## Network model
- The iOS app talks to a helper server running on the user's Mac.
- The primary intended deployment is local/private network use.
- The app does not require a public cloud backend to function.

## Permissions
- Local Network: required to communicate with the user's Mac helper.
- Notifications: used to surface updater failure alerts to the user.

## Data collection
- No third-party analytics.
- No ad tracking.
- No user profile collection.
- Tokens are stored locally in Keychain on device.

## Potential reviewer questions
1. Why local network?
   - The app communicates with the user's own Mac helper process.
2. Why notifications?
   - To alert the user when repository update runs fail.
3. Does the app run code on the device?
   - No. It triggers actions on the user-owned Mac helper.
