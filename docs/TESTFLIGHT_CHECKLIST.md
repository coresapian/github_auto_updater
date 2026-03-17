# TestFlight / App Store Readiness Checklist

## Before archiving
- Set your Apple Developer Team in `project.yml` or in Xcode.
- Confirm bundle identifier is correct for the production app.
- Replace development helper URLs with a production-safe onboarding flow.
- Generate and add a real App Icon set.
- Verify local network copy and onboarding strings are final.
- Verify notification behavior on device.
- Verify pairing flow on a real iPhone over LAN.
- Verify manual updater run flow on a real iPhone over LAN.
- Review helper auth and token storage policy.

## App metadata
- App name
- Subtitle
- Description
- Keywords
- Privacy policy URL
- Support URL
- Marketing URL
- Screenshots for required device sizes
- App review contact info

## Permissions and review-sensitive behaviors
- Local network access is required to reach the Mac helper.
- Notifications are used to surface updater failures.
- The app does not collect analytics or track users.
- The app communicates only with the user-owned Mac helper on local/private networks unless the user configures webhook/ntfy on the helper.

## Distribution strategy
- Start with TestFlight for internal testers.
- Validate onboarding, pairing, token persistence, and notification UX.
- Gather screenshots and refine permission copy.
- Only move to App Store submission after real-device LAN validation.

## Archive checklist
- `xcodegen generate`
- clean build on simulator
- archive on a signed device target
- validate privacy manifest in archive
- verify app icon assets exist
- verify version/build numbers are bumped
