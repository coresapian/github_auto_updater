# Changelog

All notable changes to this project will be documented in this file.

## [0.1.1] - Planned

Planned follow-up items:
- Real-device APNs verification and helper credential hardening
- Bonjour discovery polish and onboarding UX improvements
- TestFlight feedback fixes and App Store submission polish
- Additional helper observability and notification controls

## [0.1.0] - 2026-03-17

Initial public release.

Highlights:
- SwiftUI iOS app for monitoring a Mac-side GitHub auto-updater helper
- Paired-device onboarding with bearer token storage in Keychain
- Cron/status/log inspection via local helper API
- Manual updater run endpoint and in-app trigger
- Dashboard cards, repo health states, log filtering, and search
- Local notifications plus helper-side notification hooks (ntfy/webhook/APNs scaffolding)
- Bonjour discovery for helper instances on the local network
- Real app icon asset set
- Privacy manifest, TestFlight/App Store readiness docs, and archive workflow
- GitHub Actions CI for helper validation and simulator build
