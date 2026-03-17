# GitHub Auto Updater TestFlight and App Store Readiness Plan

> For Hermes: this is a planning document only. Do not modify product code while following it.

## Goal

Make the current iOS client and Mac helper shippable for TestFlight first, then App Store review, without surprising Apple review, users, or release engineering.

## Current architecture summary

### iOS app

Current app structure is a single iOS SwiftUI target generated from `project.yml`.

Key files:
- `project.yml`
- `GitHubAutoUpdaterApp/GitHubAutoUpdaterApp.swift`
- `GitHubAutoUpdaterApp/AppViewModel.swift`
- `GitHubAutoUpdaterApp/APIClient.swift`
- `GitHubAutoUpdaterApp/Models.swift`
- `GitHubAutoUpdaterApp/RootView.swift`
- `GitHubAutoUpdaterApp/Info.plist`

Observed behavior:
- `GitHubAutoUpdaterApp.swift` launches one `AppViewModel` and immediately calls `refresh()`.
- `AppViewModel.swift` stores `serverURL` and `refreshInterval` in `@AppStorage`, but only `serverURL` is actually used at runtime today.
- `APIClient.swift` uses `URLSession.shared` and constructs requests against:
  - `/status`
  - `/log/main`
  - `/log/alert`
  - `/log/repo/{name}`
- `RootView.swift` provides three tabs:
  - Dashboard
  - Logs
  - Settings
- The app currently displays raw paths, raw crontab content, backup folder paths, and raw log text from the helper.

### Mac helper

Current helper is a standalone Python script:
- `helper/status_server.py`

Observed behavior:
- Runs `HTTPServer(("0.0.0.0", 8787), Handler)`.
- Exposes unauthenticated plaintext HTTP endpoints on the LAN.
- Reads local machine state from fixed paths under the current macOS user's home directory.
- Shells out to `crontab -l`.
- Returns raw log content and file paths.
- Allows any origin via `Access-Control-Allow-Origin: *`.

### Release configuration and compliance state today

Observed release posture from `project.yml` and project files:
- iOS deployment target: 17.0
- Bundle id: `com.core.githubautoupdater`
- Automatic signing enabled, but `DEVELOPMENT_TEAM` is empty
- `NSLocalNetworkUsageDescription` exists
- `NSAppTransportSecurity` currently sets `NSAllowsArbitraryLoads = true`
- `Info.plist` itself is effectively empty and relies on generated keys
- No privacy manifest found
- No entitlements file found
- No unit/UI test target found
- No CI workflow found
- No release checklist found

## Executive assessment

The app is a valid early internal prototype, but it is not App Store-ready in its current form.

Primary blockers:
1. Plain HTTP plus `NSAllowsArbitraryLoads = true`
2. Local-network-only dependency on an external helper with no in-app onboarding or review-safe fallback
3. No privacy manifest
4. No signing/team/release automation setup
5. No auth or trust model between iPhone and helper
6. No reviewer path if the helper is unavailable
7. No tests or release checklist
8. Mac helper distribution model is not yet productized

## Recommended distribution strategy

### Recommended product split

Use a two-part distribution model:

1. iOS app:
   - Distributed through TestFlight immediately after hardening
   - Distributed through the App Store only after reviewer-safe onboarding and transport/security changes are complete

2. Mac helper:
   - Do not plan on shipping the current Python script through the Mac App Store as-is
   - Ship it instead as a separately notarized Developer ID companion download, or rewrite it as a proper macOS companion app/agent in Swift if Mac App Store distribution is desired later

### Why this split is the lowest-risk path

The current helper depends on:
- Python availability
- reading arbitrary local files
- reading crontab
- exposing a local server on all interfaces
- fixed user-specific filesystem paths

That is workable for a direct-download macOS companion, but it is not a strong fit for Mac App Store sandboxing. For App Store review of the iOS app, the safer story is:
- "This iPhone app connects to a user-installed local companion running on their Mac on the same local network"
- the iOS app remains a companion dashboard, not a shell or remote-code tool

### Review-safe fallback requirement

Before App Store submission, the iOS app should include one of these:

Preferred:
- a demo mode with bundled mock status/log data so reviewers can use the app without setting up the Mac helper

Acceptable:
- an in-app connection test plus first-run onboarding that makes it obvious the app requires a companion running on the user's own Mac

Best:
- both demo mode and companion setup flow

Without this, review risk is high because the app may appear broken or non-functional in Apple's environment.

## Review risks and mitigations

### 1) App Transport Security risk

Current state:
- `project.yml` enables `NSAllowsArbitraryLoads: true`

Risk:
- This is a major App Store review smell unless there is a very strong and narrow justification.
- The app currently communicates with a local helper over plaintext HTTP.

Mitigation:
- Remove `NSAllowsArbitraryLoads`
- Replace it with a narrow ATS exception for local-network helper access only, if still required
- Prefer HTTPS on the helper with a pinned/self-managed trust story if feasible
- If HTTPS is not feasible for v1, scope ATS exceptions as tightly as possible and document that traffic never leaves the user's LAN

Implementation direction:
- Replace broad arbitrary loads with domain/IP-scoped exceptions or local-network specific handling
- Validate all helper URLs before storing them
- Consider requiring `http://` only for RFC1918/private IPs or localhost in debug, and a safer transport strategy for production

### 2) Local network permission risk

Current state:
- `NSLocalNetworkUsageDescription` exists with generic copy
- No visible onboarding explaining why the permission appears or what device is being discovered/reached
- No Bonjour declaration is present

Risk:
- Users may deny the prompt because the reason is too vague
- Review may question why local network access is needed

Mitigation:
- Add a pre-permission explainer screen before the first connection attempt
- Use user-facing copy that explicitly says the app connects only to the user's Mac helper to read updater status and logs
- If Bonjour/mDNS discovery will be added, declare `NSBonjourServices`; if not, do not add it

Recommended permission copy:
- Title: "Connect to your Mac"
- Body: "GitHub Auto Updater uses your local network only to reach the helper running on your Mac and show repository update status, cron health, and logs. Data stays on your local network unless you choose to share it."

Recommended `NSLocalNetworkUsageDescription` text:
- "Allow local network access so the app can connect to the GitHub Auto Updater helper running on your Mac and display repository update status and logs."

### 3) External dependency / broken reviewer flow risk

Current state:
- The app requires a separately running Mac helper with a manually entered URL
- There is no built-in mock mode

Risk:
- App may be rejected as non-functional or too limited if reviewers cannot evaluate it
- Reviewers may not understand how to set up the helper

Mitigation:
- Add demo mode with realistic sample data and logs
- Add first-run onboarding with companion install instructions
- Add a connection diagnostics screen
- Add App Review notes with exact setup steps and a test helper endpoint or demo mode instructions

### 4) Security and privacy posture risk

Current state:
- Helper is unauthenticated
- Helper listens on `0.0.0.0`
- CORS is `*`
- Raw filesystem paths and logs are returned

Risk:
- Even on a home LAN, this is too open for a production product
- Leaking user filesystem paths and raw logs may create privacy and support issues

Mitigation:
- Bind helper to explicit interfaces or user-selected exposure mode
- Add authentication or pairing token between app and helper
- Remove or redact absolute paths from normal UI payloads
- Add a dedicated "diagnostic export" path instead of always exposing raw internals
- Limit logs and returned metadata to the minimum necessary

### 5) Mac helper distribution risk

Current state:
- Helper is a script launched manually with `python3`

Risk:
- Hard to support for non-technical users
- Fragile across Python environments
- Weak notarization/install story

Mitigation:
- Phase 1: package helper as a signed/notarized standalone macOS app/menubar app or launch agent bundle, even if still Python-based internally
- Phase 2: rewrite helper in Swift if long-term App Store/macOS integration is desired

## Privacy manifest requirements

### iOS app privacy manifest

Add `PrivacyInfo.xcprivacy` to the iOS target.

Why it is needed:
- `@AppStorage` uses `UserDefaults`
- UserDefaults is a Required Reason API category and should be declared

Likely manifest content for the current codebase:
- `NSPrivacyAccessedAPITypes`
  - `NSPrivacyAccessedAPICategoryUserDefaults`
  - approved reason covering app settings/preferences storage

Expected current data collection posture for App Store privacy labels:
- Data not collected by the app for tracking
- User-entered helper URL is stored on device only
- Logs/status are fetched from the user's own Mac and not obviously sent to a developer backend

Still verify before submission:
- whether crash reporting, analytics, or external SDKs are added later
- whether any logs are uploaded off-device

### Mac helper privacy manifest

If the helper remains an external download and not an Apple-platform app bundle, an Apple privacy manifest is not the immediate blocker.

If the helper becomes a bundled macOS app target later:
- add its own privacy manifest
- review any Required Reason APIs it uses
- document file access behavior and networking clearly

## Signing and provisioning plan

### Apple Developer setup

Required:
1. Use a paid Apple Developer Program account
2. Set a real `DEVELOPMENT_TEAM` in `project.yml`
3. Confirm bundle identifier ownership for `com.core.githubautoupdater` or move to a company-controlled namespace
4. Create App ID in the Apple Developer portal
5. Enable automatic signing in CI with App Store Connect API key or match-style certificate management

### Certificates/profiles

For TestFlight/App Store:
- Apple Distribution certificate
- iOS App Store provisioning via automatic signing or managed profiles

If later shipping a macOS companion outside the App Store:
- Developer ID Application certificate
- notarization workflow for the companion installer/app bundle

### Versioning

Current state:
- marketing version `0.1.0`
- build number `1`

Production plan:
- Keep semantic marketing versions in `MARKETING_VERSION`
- Auto-increment `CURRENT_PROJECT_VERSION` in CI per archive/upload
- Fail CI if version/build are not monotonic

## Concrete code and file changes required

This section names the files that should change during the hardening effort. It is a plan, not an instruction to change them now.

### iOS project configuration

1. Modify `project.yml`
   - set `DEVELOPMENT_TEAM`
   - remove `NSAllowsArbitraryLoads: true`
   - add narrower ATS exceptions if absolutely necessary
   - add `INFOPLIST_KEY_NSBonjourServices` only if Bonjour discovery is implemented
   - add privacy manifest file to sources/resources
   - add test targets
   - add separate Debug/TestFlight/Release config values if needed

2. Add `GitHubAutoUpdaterApp/PrivacyInfo.xcprivacy`
   - declare Required Reason API usage for UserDefaults

3. Consider adding `GitHubAutoUpdaterApp/Entitlements.plist` only if future capabilities require it
   - today no special entitlement appears necessary

### iOS networking and connection UX

4. Modify `GitHubAutoUpdaterApp/APIClient.swift`
   - validate HTTP responses and status codes
   - add timeout policy
   - differentiate transport/auth/decoding errors
   - prepare for authenticated helper requests
   - optionally support certificate pinning or token headers

5. Modify `GitHubAutoUpdaterApp/AppViewModel.swift`
   - actually honor `refreshInterval` with a timer/task
   - validate and normalize helper URL input
   - add connection state model
   - support onboarding/demo mode/review mode
   - handle permission-denied and offline states explicitly

6. Modify `GitHubAutoUpdaterApp/RootView.swift`
   - add first-run onboarding
   - add local-network rationale before first attempt
   - add connection diagnostics and empty/error states
   - add demo mode entry point
   - reduce raw internal/path exposure in user-facing tabs

7. Add new files for production UX, likely under `GitHubAutoUpdaterApp/`
   - `OnboardingView.swift`
   - `ConnectionDiagnosticsView.swift`
   - `DemoData.swift`
   - `NetworkPermissionExplainerView.swift`
   - `ReleaseConfig.swift` or equivalent environment/config layer

### iOS testing

8. Add test targets
   - `GitHubAutoUpdaterAppTests/`
   - `GitHubAutoUpdaterAppUITests/`

9. Add tests covering:
   - URL validation
   - decoding of helper payloads
   - error handling for unreachable helper
   - onboarding/demo mode flows
   - ATS/local-network messaging regressions where testable

### Mac helper hardening

10. Modify `helper/status_server.py`
   - stop binding to all interfaces by default, or make it explicit/user-configurable
   - add pairing token or authenticated session model
   - reduce payload surface area
   - redact absolute local paths from default responses
   - add health/version endpoint
   - add structured error payloads
   - add request logging policy that avoids sensitive data leakage

11. Add helper config and packaging files, likely under `helper/` or a new `mac-helper/` directory
   - `helper/config.example.json` or TOML/YAML equivalent
   - launch agent plist if using LaunchAgent distribution
   - signing/notarization scripts if packaging outside App Store
   - README/install guide for companion setup

### Documentation and operations

12. Add/update docs
   - `README.md` for user-safe install and connection docs
   - `docs/production-readiness/testflight-and-app-store-readiness.md` (this file)
   - `docs/release-checklists/ios-release-checklist.md`
   - `docs/review/app-review-notes.md`
   - `docs/privacy/privacy-policy.md`

13. Add CI workflows
   - `.github/workflows/ios-ci.yml`
   - `.github/workflows/ios-release.yml`
   - optionally `.github/workflows/mac-helper-package.yml`

## Production implementation phases

## Phase 0: Release positioning decision

Objective:
Decide what exactly will be submitted and what distribution promise is made to users.

Deliverables:
- Written decision that the iOS app is a companion to a separately distributed Mac helper for v1
- Written decision whether App Store launch waits for demo mode
- Written decision whether the helper stays Python for v1 or is repackaged/reimplemented

Exit criteria:
- Product/release owner approves the distribution story
- Review notes draft exists

## Phase 1: iOS compliance hardening

Objective:
Resolve the most likely policy blockers.

Tasks:
1. Add `PrivacyInfo.xcprivacy`
2. Remove broad ATS arbitrary loads
3. Narrow local-network messaging and onboarding text
4. Add a reviewer-safe demo mode
5. Add clear empty/error/offline states

Exit criteria:
- App can be launched and evaluated without a real helper
- Privacy manifest validates in Xcode/archive
- ATS configuration is narrowly scoped and justified

## Phase 2: Transport and helper trust hardening

Objective:
Turn the helper connection into a product feature rather than a LAN debug endpoint.

Tasks:
1. Add helper version endpoint
2. Add pairing/auth token flow
3. Bind helper more safely than `0.0.0.0` by default
4. Redact sensitive path/log details from standard payloads
5. Add connection diagnostics in app

Exit criteria:
- Unauthorized devices cannot trivially read helper data
- App can explain connection problems clearly
- Standard UI no longer exposes unnecessary raw local paths

## Phase 3: Signing, packaging, and CI

Objective:
Make builds reproducible and releasable.

Tasks:
1. Set team and signing config in `project.yml`
2. Add CI build/test/archive workflow
3. Add App Store Connect upload automation
4. Add version bump policy
5. Add notarized packaging path for the Mac helper if shipping externally

Exit criteria:
- Clean CI build from scratch
- TestFlight upload from CI succeeds
- Release artifacts and release notes are reproducible

## Phase 4: QA and App Review preparation

Objective:
Reduce reviewer surprises and customer-facing defects.

Tasks:
1. Add unit/UI tests
2. Run device testing on real LAN and offline scenarios
3. Prepare App Review notes
4. Prepare screenshots and metadata
5. Prepare support/privacy docs

Exit criteria:
- Release checklist passes
- Reviewer can understand and use the app
- Known failure cases have user-friendly handling

## CI and release pipeline plan

### CI workflow: pull request

Add a PR workflow that runs on every pull request:
- generate project if using XcodeGen
- build app for simulator
- run unit tests
- run UI smoke tests if available
- lint plist/manifest existence
- fail if `NSAllowsArbitraryLoads` appears in `project.yml` or generated project for release configs

Suggested steps:
1. Checkout
2. Select Xcode version
3. Install XcodeGen if needed
4. Run `xcodegen generate`
5. Build for iPhone simulator
6. Run tests
7. Archive config validation script

### CI workflow: release branch / tag

Add a release workflow that:
- verifies version/build numbers
- archives the iOS app
- exports with App Store signing
- uploads to TestFlight
- stores dSYMs/artifacts
- optionally prepares helper packaging artifact

### Suggested validation commands

Examples to automate:
- `xcodegen generate`
- `xcodebuild -project GitHubAutoUpdaterApp.xcodeproj -scheme GitHubAutoUpdaterApp -destination 'platform=iOS Simulator,name=iPhone 15' build`
- `xcodebuild -project GitHubAutoUpdaterApp.xcodeproj -scheme GitHubAutoUpdaterApp -destination 'platform=iOS Simulator,name=iPhone 15' test`
- `xcodebuild -project GitHubAutoUpdaterApp.xcodeproj -scheme GitHubAutoUpdaterApp -configuration Release -archivePath build/GitHubAutoUpdaterApp.xcarchive archive`

## TestFlight readiness checklist

### Build and signing
- [ ] Paid Apple Developer account active
- [ ] Bundle ID finalized
- [ ] `DEVELOPMENT_TEAM` set
- [ ] Automatic signing or managed signing works on CI and locally
- [ ] Marketing version and build number updated

### Compliance
- [ ] `PrivacyInfo.xcprivacy` added and valid
- [ ] `NSAllowsArbitraryLoads` removed or narrowly scoped
- [ ] `NSLocalNetworkUsageDescription` final copy approved
- [ ] App Privacy questionnaire completed accurately in App Store Connect
- [ ] Privacy policy URL prepared if required by metadata posture

### Product quality
- [ ] First-run onboarding exists
- [ ] Demo mode or reviewer-safe fallback exists
- [ ] Connection failures produce actionable messages
- [ ] Real device tested on same Wi-Fi as helper
- [ ] Real device tested when helper is down
- [ ] Real device tested with permission denied then re-enabled

### Helper readiness
- [ ] Helper install steps documented
- [ ] Helper defaults are not dangerously open
- [ ] Helper version is visible for support
- [ ] Sensitive path exposure reviewed

### Submission ops
- [ ] Screenshots captured
- [ ] Beta description written
- [ ] "What to Test" written for testers
- [ ] Internal testing first, then external testing

## App Store readiness checklist

### Policy and review
- [ ] App remains useful and reviewable without private developer environment assumptions
- [ ] Review notes explain the companion-helper model clearly
- [ ] Reviewer can use demo mode or supplied helper setup path
- [ ] No broad ATS exception without explicit justification
- [ ] Local network usage is obvious, limited, and user-benefiting
- [ ] App metadata does not imply unsupported automation or remote administration features

### Security
- [ ] Helper authentication/pairing implemented
- [ ] Helper exposure defaults minimized
- [ ] Raw logs/paths shown only when necessary and preferably behind diagnostics UI
- [ ] Input URL validation prevents malformed/unexpected targets

### Quality
- [ ] Unit tests present
- [ ] UI smoke tests present
- [ ] Crash-free manual test pass completed
- [ ] Accessibility pass on main screens completed
- [ ] Release notes and support docs ready

### Operations
- [ ] CI archive/upload works
- [ ] Rollback plan exists
- [ ] Contact/support channel defined
- [ ] Analytics/crash tooling reviewed for privacy impact if added

## Recommended App Review notes draft

Use a version of this in App Store Connect once the app is ready:

"GitHub Auto Updater is an iPhone companion app for a user-installed helper running on the user's own Mac on the same local network. The app uses local network access only to connect to that helper and display repository update status, cron health, and updater logs. No third-party backend is required for core operation. For App Review, use the built-in Demo Mode from first launch to explore the UI without a companion. If you would like to test live connection mode, setup instructions are included in Settings > Companion Setup." 

## Highest-priority recommended changes by file

### `project.yml`
Highest priority:
- fill in signing team
- remove broad ATS arbitrary loads
- add privacy manifest resource
- add test targets
- formalize release configs

### `GitHubAutoUpdaterApp/AppViewModel.swift`
Highest priority:
- connection state machine
- URL validation
- refresh scheduler using `refreshInterval`
- demo mode support
- better error taxonomy

### `GitHubAutoUpdaterApp/APIClient.swift`
Highest priority:
- response validation
- timeout/auth support
- safer URL construction
- future pairing support

### `GitHubAutoUpdaterApp/RootView.swift`
Highest priority:
- onboarding
- diagnostics
- permission explanation
- reviewer/demo path
- less raw internal data in primary UI

### `helper/status_server.py`
Highest priority:
- auth/pairing
- reduced network exposure
- safer payload surface
- packaging/installability

## Practical release order

Recommended order of execution:
1. Decide companion distribution model
2. Add privacy manifest
3. Remove broad ATS exception
4. Add onboarding and demo mode
5. Add helper auth/pairing and safer binding
6. Add tests and CI
7. Ship internal TestFlight
8. Ship external TestFlight
9. Prepare App Review notes and metadata
10. Submit to App Store only after reviewer-safe flow is verified on a clean device

## Bottom line

The iOS app can likely reach internal TestFlight quickly after compliance hardening.

The biggest App Store risks are not SwiftUI quality issues; they are productization and policy issues around:
- broad ATS bypass
- dependence on a manually run external helper
- lack of review-safe onboarding/demo behavior
- insecure local helper exposure

If those are addressed, the most credible v1 path is:
- App Store iOS companion app
- separately notarized Mac companion/helper outside the Mac App Store
- clear onboarding, privacy manifest, narrow network permissions, and reviewer demo mode
