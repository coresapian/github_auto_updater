# Archive / Signing / TestFlight Upload Workflow

## Requirements
- Apple Developer account
- Xcode signed in with the correct team
- A valid App Store Connect app record
- Bundle ID reserved in App Store Connect
- App icons and screenshots prepared

## One-time setup
- Set your `DEVELOPMENT_TEAM`
- Confirm `PRODUCT_BUNDLE_IDENTIFIER`
- Verify notification and local-network permission copy
- Test on a physical device over LAN

## Scripted archive
Use:
- `scripts/archive_testflight.sh`

Example:
```bash
DEVELOPMENT_TEAM=YOURTEAMID APP_BUNDLE_ID=com.core.githubautoupdater bash scripts/archive_testflight.sh
```

## Recommended upload path
- Prefer Xcode Organizer for the first upload.
- After the archive succeeds, validate and upload from Organizer.
- For CI later, add App Store Connect API key based upload.

## Before submitting to TestFlight
- Validate pairing flow on a real iPhone
- Validate manual run flow on a real iPhone
- Validate local notification flow
- If using APNs, validate remote registration and helper delivery
- Confirm privacy manifest is present
- Confirm app icon set is present

## Before App Store review
- Complete `docs/TESTFLIGHT_CHECKLIST.md`
- Review `docs/APP_REVIEW_NOTES.md`
- Provide a privacy policy URL and support URL
