# Secure pairing with Mac helper: production readiness plan

## Current architecture summary

### iOS app today

The iOS app is a single SwiftUI target with very little transport abstraction:

- `GitHubAutoUpdaterApp/GitHubAutoUpdaterApp.swift`
  - Creates a single `AppViewModel` and immediately calls `refresh()` on launch.
- `GitHubAutoUpdaterApp/AppViewModel.swift`
  - Stores one user-editable `serverURL` in `@AppStorage`.
  - Calls the helper directly for `/status`, `/log/main`, `/log/alert`, and repo log endpoints.
  - Has no concept of pairing state, enrolled helpers, trust, certificates, or device identity.
- `GitHubAutoUpdaterApp/APIClient.swift`
  - Uses `URLSession.shared.data(from:)` with a raw URL string.
  - Has no authentication, no custom trust evaluation, no certificate pinning, and no request signing.
- `GitHubAutoUpdaterApp/RootView.swift`
  - Settings is a plain URL text field plus refresh interval.
  - There is no onboarding flow, no discovery UI, and no paired-device management UI.
- `GitHubAutoUpdaterApp/Models.swift`
  - Contains only status/log data models, not pairing/enrollment models.
- `project.yml`
  - `NSAllowsArbitraryLoads: true`, which is not acceptable for production.
  - `NSLocalNetworkUsageDescription` exists, but there is no Bonjour service declaration and no local-network discovery implementation.

### Mac helper today

The Mac helper is a single Python file:

- `helper/status_server.py`
  - Binds `HTTPServer(("0.0.0.0", 8787), Handler)`.
  - Exposes unauthenticated HTTP endpoints for system and log data.
  - Allows any device on the LAN to fetch status if the port is reachable.
  - Has no enrollment model, no notion of devices, no persistent trust store, no revocation, no TLS, and no audit logging.
  - Uses `Access-Control-Allow-Origin: *`, which is unnecessary for a native iOS client and broadens attack surface.

### Main production gaps

1. Transport is plaintext HTTP on the LAN.
2. There is no identity for either side.
3. There is no trust establishment ceremony.
4. Any LAN client can query sensitive status/log data.
5. The app requires manual URL entry and cannot safely discover the right helper.
6. There is no device enrollment lifecycle, no revocation, and no helper-side audit trail.
7. ATS is effectively disabled globally.

This means the current implementation is fine for local prototyping, but not acceptable for a production pairing model.

## Target production architecture

Use a two-layer trust model:

1. TLS with helper certificate pinning for server authenticity.
2. Per-device enrollment using asymmetric device keys and signed session tokens for client authorization.

High-level flow:

1. Helper advertises itself over Bonjour on the local network.
2. iPhone discovers helpers and shows them in onboarding.
3. User selects a helper and starts pairing.
4. Helper displays or exposes a short-lived pairing code out-of-band.
5. iPhone generates a device keypair in Secure Enclave/Keychain and submits a pairing request signed by that device key, including the one-time code.
6. Helper validates the code, creates a device enrollment record, returns helper identity metadata and a short-lived bootstrap token over TLS.
7. iPhone pins the helper certificate/public key and stores the issued device identifier plus server trust material.
8. All future requests use HTTPS plus device authentication (signed requests or device-bound bearer/access tokens).
9. Helper maintains an enrolled-device registry with revoke/rename/last-seen metadata.

This is enough for a secure single-user home-lab style product without introducing a cloud dependency.

## Security goals

Must have:

- No plaintext status/log traffic on the LAN.
- No global ATS bypass.
- Explicit user-approved pairing ceremony.
- Mutual trust at the application layer, even if LAN is hostile.
- Persisted device enrollment records on the helper.
- Revocation from either side.
- Auditability for pair/unpair activity.
- Narrow service exposure to only paired devices.

Nice to have later:

- Optional mTLS after first enrollment.
- iCloud-backed paired-helper metadata sync across the user’s iOS devices.
- QR-based pairing payload for smoother onboarding.

## Recommended pairing and trust design

### 1. Helper identity

The helper should have a long-lived identity keypair separate from ephemeral session tokens.

Recommended approach:

- Generate an Ed25519 identity keypair on first launch for helper identity metadata/signing.
- Generate or provision a TLS certificate for the helper.
- Pin the helper TLS certificate public key or SPKI hash in the iOS app after successful pairing.

For local-only deployment, the practical option is:

- Helper creates a self-signed TLS cert on first run.
- Pairing flow returns the helper certificate fingerprint and identity public key.
- iOS stores both and rejects future mismatches.

Why both:

- TLS protects transport.
- Helper identity signing key provides app-layer identity continuity if TLS material rotates through a controlled flow.

### 2. iPhone/device identity

Each iPhone/iPad should create its own device identity:

- Create a Secure Enclave-backed P-256 signing key if available; otherwise Keychain-stored software key.
- Export only the public key to the helper.
- Never export the private key.
- Store a stable device UUID and user-visible device name.

The helper stores:

- `device_id`
- `device_name`
- `public_key`
- `created_at`
- `last_seen_at`
- `status` (`active`, `revoked`)
- optional `capabilities`

### 3. Pairing secret / out-of-band confirmation

Do not pair solely by network reachability.

Use a one-time pairing code generated on the Mac helper side:

- 6-8 digits minimum, valid for 5 minutes.
- Single use.
- Rate limited.
- Cleared after success or expiry.

Best UX progression:

Phase 1:
- User opens helper UI/CLI on Mac and requests “Pair new device”.
- Helper shows a numeric code.
- iPhone enters the code.

Phase 2:
- Helper also shows a QR code containing service instance ID, TLS fingerprint, helper public key fingerprint, and short-lived nonce.
- iPhone scans QR and only manually confirms a short code.

This out-of-band step prevents silent enrollment by another LAN client.

### 4. Transport after pairing

Use HTTPS only.

Recommended session/auth model:

Option A, simplest production path:
- TLS with server pinning.
- Per-request signed authorization headers using the device private key.
- Helper validates signatures against enrolled public keys.

Option B, easier operationally for larger APIs:
- TLS with server pinning.
- Device signs a challenge to mint a short-lived access token.
- Access token used for normal API calls.
- Refresh requires another signed challenge.

For this codebase, Option B is more maintainable because the app already uses simple request/response calls and the helper is small. It keeps endpoint authorization logic straightforward.

Recommended concrete protocol:

1. `POST /api/v1/pairing/challenge`
   - iOS sends helper instance ID and pairing code.
   - Helper returns nonce/challenge if code is valid.
2. `POST /api/v1/pairing/complete`
   - iOS sends device metadata, device public key, challenge signature, and CSR-like enrollment payload.
   - Helper stores enrollment and returns `device_id`, helper metadata, and short-lived bootstrap access token.
3. `POST /api/v1/auth/challenge`
   - iOS requests a nonce for an enrolled device.
4. `POST /api/v1/auth/token`
   - iOS signs nonce with device private key and gets short-lived access token (for example 15 minutes).
5. All normal endpoints require `Authorization: Bearer <token>`.

Keep access tokens short-lived and helper-local. No long-lived bearer secrets in plaintext user defaults.

### 5. Revocation and re-enrollment

Revocation must be possible from both sides.

Helper-side revocation:
- Primary control surface.
- User can list enrolled devices and revoke one.
- Revoked devices lose token minting ability immediately.

iOS-side removal:
- “Forget this Mac” deletes local pinning data, tokens, and device private-key references for that helper record.
- Does not by itself remove the helper-side record unless network is available and user confirms remote unenroll.

Re-enrollment behavior:
- A revoked device must repeat the full pairing ceremony with a fresh one-time code.
- Helper certificate or identity changes should force a trust reset and explicit user confirmation.

## Local-network discovery design

Use Bonjour/mDNS for discovery.

Recommended service type:
- `_ghautoupdater._tcp`

Advertise TXT records such as:
- `instance_id=<stable helper UUID>`
- `display_name=<user-visible Mac name>`
- `api_version=1`
- `tls=1`
- `pairing=required`
- `fingerprint_hint=<short fingerprint prefix>`

iOS discovery:
- Use `NWBrowser` or `NetServiceBrowser` to list Bonjour services.
- Resolve endpoints to host/port.
- Display only helpers that advertise TLS and supported API version.
- On selection, fetch a public `/api/v1/hello` document over HTTPS to verify service metadata before entering code.

Privacy/permission notes:
- Add `NSBonjourServices` to the app Info.plist/project config with `_ghautoupdater._tcp`.
- Keep `NSLocalNetworkUsageDescription`, but update wording so it explains discovery and secure pairing.

Fallback path:
- Keep a manual “Enter helper address” path for networks where mDNS is blocked.
- Manual entry should still require HTTPS and full pairing.

## Onboarding UX plan

### Desired first-run flow

Screen 1: Welcome
- Explain that the app connects only to a Mac helper on the local network.
- Explain that pairing is required before any logs/status are visible.

Screen 2: Discover helpers
- Start Bonjour discovery automatically.
- Show loading state, discovered helpers, and a manual address fallback.
- For each helper show Mac name, network endpoint, API version, and whether it is already paired.

Screen 3: Pair selected helper
- Explain how to generate a one-time code on the Mac.
- Provide code entry field and optional QR scanner.
- Validate code format client-side.

Screen 4: Trust confirmation
- Show helper name and certificate fingerprint summary.
- If QR was used, auto-match the fingerprint and ask user to confirm.
- Make it explicit that this trusts that Mac for future access.

Screen 5: Pairing success
- Store helper as a named connection.
- Offer “Test connection now”.
- Offer “Set as default helper”.

Settings / paired helpers management
- List all paired helpers, not just one URL.
- Show status: reachable, last connected, certificate state, device enrollment status.
- Actions: reconnect, rename, forget local record, remotely revoke this device, view trust fingerprint.

Error states
- Code expired.
- Helper identity changed.
- Token expired and refresh failed.
- Helper discovered but API version unsupported.
- Local network permission denied.
- TLS pin mismatch.

## Enrollment and revocation model

### Helper-side state

Store helper persistent state in a new app-specific directory, for example:

- `~/.config/github-auto-updater-helper/config.json`
- `~/.config/github-auto-updater-helper/helper_identity.json`
- `~/.config/github-auto-updater-helper/enrolled_devices.json`
- `~/.config/github-auto-updater-helper/audit.log`

Suggested enrollment record shape:

```json
{
  "device_id": "uuid",
  "device_name": "Alice iPhone",
  "public_key_pem": "...",
  "created_at": "2026-03-16T19:00:00Z",
  "last_seen_at": "2026-03-16T20:00:00Z",
  "status": "active",
  "revoked_at": null,
  "capabilities": ["read_status", "read_logs"]
}
```

### iOS-side state

Replace single `serverURL` storage with structured paired-helper records.

Suggested helper record fields:

- helper instance ID
- display name
- last resolved host/port
- base HTTPS URL
- pinned certificate/SPKI hash
- helper identity public key/fingerprint
- enrolled `device_id`
- local key reference / key tag
- last successful connection timestamp
- revocation state / trust warning state

Sensitive material storage:

- Tokens in Keychain.
- Private keys in Secure Enclave/Keychain.
- Non-sensitive helper metadata in `AppStorage` or a small local JSON/SwiftData store.

## API surface changes

### New helper endpoints

Public-ish bootstrap endpoints:
- `GET /api/v1/hello`
  - returns helper metadata, API version, instance ID, TLS required, pairing availability
- `POST /api/v1/pairing/challenge`
- `POST /api/v1/pairing/complete`

Authenticated endpoints:
- `POST /api/v1/auth/challenge`
- `POST /api/v1/auth/token`
- `GET /api/v1/status`
- `GET /api/v1/logs/main`
- `GET /api/v1/logs/alert`
- `GET /api/v1/logs/repo/{repo}`
- `GET /api/v1/devices` (optional admin/self visibility)
- `POST /api/v1/devices/{device_id}/revoke` or helper-local admin command only

Behavior changes versus current API:
- Remove permissive CORS header.
- Require auth for status/logs.
- Return structured error payloads with machine-readable codes.
- Add API versioning now to avoid future breakage.

## Concrete file-by-file implementation plan

## iOS app changes

### Modify `project.yml`

Change:
- Remove `NSAllowsArbitraryLoads: true`.
- Add `NSBonjourServices` with `_ghautoupdater._tcp`.
- Keep and refine `NSLocalNetworkUsageDescription` to mention secure discovery/pairing.
- If QR scanning is added, add camera usage description.

Why:
- Production ATS compliance and local-network discovery permissions.

### Modify `GitHubAutoUpdaterApp/AppViewModel.swift`

Refactor from a single-helper URL model to a pairing-aware app state model.

Add responsibilities:
- onboarding state machine
- discovered helpers list
- paired helpers list
- selected helper
- connection/auth refresh lifecycle
- trust failure handling
- revoke/forget actions

Do not let this file continue to directly model a single raw URL string as the primary source of truth.

### Modify `GitHubAutoUpdaterApp/APIClient.swift`

Refactor into a real transport/auth layer.

Add:
- HTTPS-only base URLs
- custom `URLSession` with trust/pinning delegate
- access-token acquisition/refresh
- typed requests for `hello`, pairing, auth, status, and logs
- structured error mapping

Potential split:
- keep `APIClient.swift` as façade
- add supporting files below

### Modify `GitHubAutoUpdaterApp/Models.swift`

Keep current status/log models, but add or move pairing/auth models into dedicated files.

New model groups needed:
- helper discovery model
- helper enrollment model
- pairing challenge/complete payloads
- auth challenge/token payloads
- paired helper persistence model
- trust state enum / errors

### Modify `GitHubAutoUpdaterApp/RootView.swift`

Replace current tabs-first launch experience with conditional navigation:
- if no paired helper/default helper exists, show onboarding flow
- if paired, show normal dashboard/logs/settings
- add paired helpers management screens
- move raw URL editing to advanced/manual discovery fallback only

### Add `GitHubAutoUpdaterApp/Onboarding/OnboardingCoordinator.swift`

Purpose:
- drive first-run state machine
- route between discovery, manual entry, code entry, trust confirmation, and success

### Add `GitHubAutoUpdaterApp/Onboarding/DiscoveryView.swift`

Purpose:
- show Bonjour-discovered helpers
- support manual address entry fallback
- support retry and permission troubleshooting

### Add `GitHubAutoUpdaterApp/Onboarding/PairingCodeView.swift`

Purpose:
- collect one-time code
- show QR scan option later
- display validation and expiry errors cleanly

### Add `GitHubAutoUpdaterApp/Onboarding/TrustConfirmationView.swift`

Purpose:
- show helper display name, endpoint, and fingerprint summary
- require explicit confirm action before storing trust material

### Add `GitHubAutoUpdaterApp/Settings/PairedHelpersView.swift`

Purpose:
- list paired Macs
- show connection status and last seen time
- allow default selection, rename, revoke/forget

### Add `GitHubAutoUpdaterApp/Networking/BonjourDiscoveryService.swift`

Purpose:
- wrap `NWBrowser`/Bonjour browsing
- publish discovered helper entries to the UI

### Add `GitHubAutoUpdaterApp/Networking/HelperTrustStore.swift`

Purpose:
- persist pinned helper certificate/SPKI hashes and helper identity metadata
- answer trust lookups during connections

### Add `GitHubAutoUpdaterApp/Networking/PinnedSessionDelegate.swift`

Purpose:
- perform TLS server trust evaluation and pin comparison

### Add `GitHubAutoUpdaterApp/Security/DeviceKeyManager.swift`

Purpose:
- create/retrieve per-device signing keys from Secure Enclave/Keychain
- sign pairing and auth challenges
- manage key tags per helper enrollment if needed

### Add `GitHubAutoUpdaterApp/Security/TokenStore.swift`

Purpose:
- store short-lived/refresh tokens in Keychain
- clear tokens on revocation/forget

### Add `GitHubAutoUpdaterApp/Persistence/PairedHelperStore.swift`

Purpose:
- persist paired helper records
- replace the current single `serverURL` string as canonical state

Optional but recommended:
- add `GitHubAutoUpdaterApp/Support/AppError.swift`
- add `GitHubAutoUpdaterApp/Support/Logger.swift`

## Mac helper changes

### Replace or substantially refactor `helper/status_server.py`

This file should no longer be a single unauthenticated `BaseHTTPRequestHandler` script.

Minimum required changes:
- add HTTPS support
- add helper identity/bootstrap config loading
- add pairing-code generation/validation
- add enrolled device registry
- add token minting/validation
- add structured routing and error responses
- require auth for sensitive endpoints
- bind more deliberately and log access
- remove wildcard CORS

Because the file is currently monolithic, the clean production move is to split it.

### Add `helper/app.py`

Purpose:
- process entrypoint
- load config, identity, device registry, and HTTP/TLS server

### Add `helper/config.py`

Purpose:
- centralize paths, ports, API version, certificate locations, and timeouts

### Add `helper/identity.py`

Purpose:
- generate/load helper identity keypair
- compute fingerprints
- surface instance ID and display metadata

### Add `helper/tls.py`

Purpose:
- load/generate self-signed certificate
- configure HTTPS server socket
- optionally support rotation tooling

### Add `helper/discovery.py`

Purpose:
- publish Bonjour `_ghautoupdater._tcp` service with TXT records
- manage lifecycle during helper startup/shutdown

### Add `helper/pairing.py`

Purpose:
- issue one-time pairing codes
- validate expiry, single-use semantics, and rate limits
- complete enrollments

### Add `helper/device_registry.py`

Purpose:
- persist enrolled devices
- update last seen timestamps
- revoke/reactivate as allowed

### Add `helper/auth.py`

Purpose:
- issue auth challenges
- verify signatures from enrolled public keys
- mint/validate short-lived access tokens

### Add `helper/api.py`

Purpose:
- route `/api/v1/*` endpoints
- enforce auth where required
- adapt existing status/log functions to authenticated handlers

### Add `helper/storage.py`

Purpose:
- atomic JSON file IO for config/enrollment state
- file locking where appropriate

### Add `helper/audit.py`

Purpose:
- append pair/unpair/auth failure/security-relevant events to audit log

### Add `helper/cli.py`

Purpose:
- helper-local administrative commands:
  - `serve`
  - `pairing-code create`
  - `devices list`
  - `devices revoke <id>`
  - `devices rename <id> <name>`
  - `trust show`

This gives the user a safe way to manage enrollment on the Mac without editing files manually.

## Proposed request lifecycle

### First-time pairing

1. Helper running and advertising Bonjour.
2. iPhone discovers helper.
3. iPhone calls `GET /api/v1/hello` over HTTPS.
4. User creates one-time pairing code on Mac via CLI/helper UI.
5. iPhone enters code.
6. iPhone creates local device keypair.
7. iPhone requests pairing challenge.
8. Helper validates code and returns nonce.
9. iPhone signs nonce with device key and submits enrollment.
10. Helper stores device, returns `device_id`, helper metadata, and bootstrap token.
11. iPhone stores pinned trust material and device enrollment locally.
12. iPhone fetches authenticated status to verify success.

### Normal reconnect

1. Discovery or persisted helper address resolution.
2. HTTPS connection with pinning.
3. If token valid, call authenticated endpoints.
4. If token expired, perform signed challenge to mint new token.
5. If helper identity/pin mismatch, block and require explicit trust reset.

### Revocation

Mac-initiated:
1. User revokes device from CLI/helper UI.
2. Helper marks device revoked and invalidates outstanding tokens.
3. Next iOS request gets `device_revoked`.
4. App shows recovery UI requiring re-pair.

Phone-initiated:
1. User taps “Forget this Mac”.
2. App optionally calls remote unenroll endpoint if reachable and confirmed.
3. App deletes tokens, pins, and local enrollment state regardless.

## Backward compatibility / migration

Current users store a plain `serverURL` and connect over HTTP. Migrate carefully.

Plan:
- On first launch after upgrade, detect legacy `serverURL`.
- Put it in a “Legacy manual endpoint” bucket only for migration assistance.
- Do not auto-trust or silently convert it to a paired helper.
- Show a one-time migration screen explaining that production builds require secure pairing.
- After successful secure pairing, stop using the old raw URL.

## Testing plan

### iOS tests to add

If/when tests are added to the project, cover:
- helper discovery parsing and deduplication
- trust pin validation success/failure
- Keychain token persistence and cleanup
- pairing state-machine transitions
- migration from legacy `serverURL`
- revoked-device UX handling

### Helper tests to add

Add Python tests for:
- pairing code issuance, expiry, and single-use semantics
- enrollment record persistence
- challenge signature verification
- token issuance/expiry/revocation
- unauthorized access rejection for status/log endpoints
- hello/discovery metadata correctness

### Manual verification checklist

- Fresh install on iPhone with no helpers paired.
- Bonjour discovery works on same Wi‑Fi.
- Manual entry works when Bonjour is unavailable.
- Pairing fails with wrong/expired code.
- Pairing succeeds with valid code.
- Relaunch preserves trust and reconnects.
- Revoked device loses access immediately.
- Helper identity change triggers trust warning and blocks silent reconnect.
- ATS passes with no arbitrary loads.

## Rollout sequence

### Phase 0: Security groundwork

- Add structured helper modules and persistent storage.
- Introduce HTTPS and helper identity.
- Add `GET /api/v1/hello`.

### Phase 1: Pairing and auth

- Implement one-time pairing codes.
- Implement device keys and enrollment.
- Protect status/log endpoints with token auth.

### Phase 2: iOS onboarding and management UI

- Discovery UI
- pairing flow
- paired helpers management
- legacy migration UX

### Phase 3: Hardening

- audit logs
- rate limiting
- helper-side brute-force protections
- better error taxonomy
- optional QR flow

## Specific recommendations and non-goals

Do:
- Use HTTPS only.
- Pin helper trust after user-confirmed pairing.
- Store private keys and tokens in Apple security APIs, not `AppStorage`.
- Model multiple paired helpers, even if only one is commonly used.
- Keep helper admin actions local to the Mac helper CLI/UI.

Do not:
- Keep `NSAllowsArbitraryLoads` enabled.
- Treat local network as trusted.
- Depend on obscurity like an unadvertised port number.
- Store long-lived shared secrets in the iOS app bundle.
- Continue exposing status/logs anonymously on `0.0.0.0` over plaintext HTTP.

## Short file change summary

Existing files to modify:
- `project.yml`
- `GitHubAutoUpdaterApp/AppViewModel.swift`
- `GitHubAutoUpdaterApp/APIClient.swift`
- `GitHubAutoUpdaterApp/RootView.swift`
- `GitHubAutoUpdaterApp/Models.swift`
- `helper/status_server.py` (or convert into compatibility shim importing new modules)

New iOS files recommended:
- `GitHubAutoUpdaterApp/Onboarding/OnboardingCoordinator.swift`
- `GitHubAutoUpdaterApp/Onboarding/DiscoveryView.swift`
- `GitHubAutoUpdaterApp/Onboarding/PairingCodeView.swift`
- `GitHubAutoUpdaterApp/Onboarding/TrustConfirmationView.swift`
- `GitHubAutoUpdaterApp/Settings/PairedHelpersView.swift`
- `GitHubAutoUpdaterApp/Networking/BonjourDiscoveryService.swift`
- `GitHubAutoUpdaterApp/Networking/HelperTrustStore.swift`
- `GitHubAutoUpdaterApp/Networking/PinnedSessionDelegate.swift`
- `GitHubAutoUpdaterApp/Security/DeviceKeyManager.swift`
- `GitHubAutoUpdaterApp/Security/TokenStore.swift`
- `GitHubAutoUpdaterApp/Persistence/PairedHelperStore.swift`
- optional support/error/logging files

New helper files recommended:
- `helper/app.py`
- `helper/config.py`
- `helper/identity.py`
- `helper/tls.py`
- `helper/discovery.py`
- `helper/pairing.py`
- `helper/device_registry.py`
- `helper/auth.py`
- `helper/api.py`
- `helper/storage.py`
- `helper/audit.py`
- `helper/cli.py`

## Final recommendation

The right production direction is not to bolt a password onto the current `status_server.py`, but to promote the helper into a small authenticated local service with:

- Bonjour discovery
- HTTPS
- helper certificate pinning
- Secure Enclave/Keychain-backed device identity
- one-time-code enrollment
- short-lived access tokens
- explicit device management and revocation

That architecture fits the current app/helper split, avoids cloud complexity, and closes the biggest security gaps without changing the product’s local-first model.
