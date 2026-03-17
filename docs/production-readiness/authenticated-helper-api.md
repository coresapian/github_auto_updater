# Authenticated Helper API Production Readiness Plan

> For Hermes: this is a design-and-implementation plan only. Do not change app/helper code while following this document.

## 1. Executive summary

The current architecture is a simple SwiftUI iOS client talking directly to a Python HTTP server on the Mac over the local network.

Current flow:
- iOS app stores a raw `serverURL` string in `@AppStorage`.
- `APIClient.swift` performs anonymous `GET` requests to `/status`, `/log/main`, `/log/alert`, and `/log/repo/<name>`.
- `helper/status_server.py` binds `0.0.0.0:8787`, allows any host on the LAN, serves plain HTTP, has no authentication, and returns sensitive local state including crontab contents, filesystem paths, repo names, backup directories, and recent logs.
- `project.yml` currently sets `NSAllowsArbitraryLoads: true`, so App Transport Security is effectively disabled.

This is acceptable for a throwaway prototype, but not for a production deployment. The local network is not a trust boundary. Any device on the same Wi‑Fi, a malicious captive portal, compromised router, hostile browser page on the Mac, or passive observer can read or tamper with helper traffic today.

Recommended production direction:
1. Treat the helper as a real authenticated service, even on LAN.
2. Require HTTPS with certificate pinning.
3. Add explicit device pairing and device-scoped credentials.
4. Use short-lived access tokens plus refresh tokens.
5. Add per-request signing to reduce replay and token theft risk.
6. Store secrets in Keychain/Secure Enclave where possible.
7. Version the API and centralize auth, transport, and error handling.

## 2. Existing architecture analysis

### iOS app

Relevant existing files:
- `GitHubAutoUpdaterApp/GitHubAutoUpdaterApp.swift`
- `GitHubAutoUpdaterApp/AppViewModel.swift`
- `GitHubAutoUpdaterApp/APIClient.swift`
- `GitHubAutoUpdaterApp/Models.swift`
- `GitHubAutoUpdaterApp/RootView.swift`
- `project.yml`

Current behavior:
- `GitHubAutoUpdaterApp.swift` creates one `AppViewModel` and refreshes immediately on launch.
- `AppViewModel.swift` stores `serverURL` and `refreshInterval` in `@AppStorage`, fetches status/logs, and exposes raw error text to the UI.
- `APIClient.swift` uses `URLSession.shared.data(from:)` with no custom session, no auth headers, no request signing, no trust evaluation, and no HTTP status inspection.
- `Models.swift` only models anonymous status/log responses.
- `RootView.swift` exposes a settings field for a raw helper URL and shows logs/status directly.
- `project.yml` disables ATS via `NSAllowsArbitraryLoads: true` and allows arbitrary HTTP access.

Architectural implications:
- No concept of paired device identity.
- No session lifecycle.
- No secure token persistence.
- No TLS or certificate pinning.
- No downgrade protection.
- No server trust UX.

### Mac helper

Relevant existing file:
- `helper/status_server.py`

Current behavior:
- Single-file helper using `BaseHTTPRequestHandler` and `HTTPServer`.
- Listens on `0.0.0.0:8787`.
- No auth on any endpoint.
- `Access-Control-Allow-Origin: *` for every response.
- Reads sensitive files from the user home directory.
- Returns raw `crontab -l` output.
- Exposes repo logs with simple filename sanitization.
- No structured config, no persistence model, no audit logging, no rate limiting, no TLS, and no explicit API versioning.

Architectural implications:
- One monolithic module currently mixes transport, route handling, file access, shell execution, and response formatting.
- There is no seam where auth can be added cleanly without refactoring.
- It is difficult to test safely in the current shape.

## 3. Threat model

### Assets that must be protected

Sensitive data currently exposed by the helper:
- crontab contents
- absolute local filesystem paths
- updater logs and alert logs
- per-repo operational state
- backup directory names and locations
- future possibility of helper control endpoints if added later

Sensitive secrets introduced by auth:
- helper private key / TLS private key
- pairing secret or pairing code
- device public keys
- access tokens
- refresh tokens
- request-signing keys or device private keys

### Adversaries

Assume these are realistic:
- Another device on the same home/office Wi‑Fi.
- A malicious guest on the local network.
- A compromised router or hostile access point.
- Passive LAN observer sniffing unencrypted traffic.
- Active MITM modifying traffic or swapping helper identity.
- Malicious web content in a browser on the Mac abusing permissive CORS.
- Local malware on the Mac reading helper config/state files.
- Someone with temporary physical access to an unlocked phone or Mac.
- A stolen iPhone with unlocked app state.

### Attacks against the current prototype

The current design is vulnerable to:
- Unauthorized read access to all helper endpoints from any LAN client.
- MITM reading or modifying HTTP responses.
- DNS/IP spoofing because the app trusts whatever URL the user enters.
- Replay or automation attacks because no nonce/timestamp exists.
- Browser-based abuse because `Access-Control-Allow-Origin: *` permits cross-origin reads from a page that can reach the helper.
- Future privilege escalation if write endpoints are ever added without a security redesign.

### Security goals

The production design should guarantee:
- Only explicitly paired devices can call the helper API.
- A paired device can prove possession of long-term key material or a valid refresh token.
- Captured traffic is not useful after short time windows.
- MITM cannot silently impersonate the helper.
- Stolen access tokens alone are insufficient, or at least very low value due to expiry and request binding.
- Secrets at rest are kept in platform secure storage.
- Logs do not leak bearer tokens, pairing secrets, or private keys.
- The API is ready for later expansion to state-changing actions without redoing security.

## 4. Production authentication architecture

## 4.1 Recommended trust model

Use a paired-device model, not a shared LAN password.

Each iOS device should have its own identity and its own revocable credentials.

Recommended shape:
- Helper owns a long-term server identity certificate and private key.
- iOS app generates a device keypair on first pairing. Prefer Secure Enclave-backed P-256 if practical; otherwise Keychain-stored private key with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` or stricter depending on UX needs.
- Pairing is explicit and local-user mediated through a short-lived one-time code displayed on the Mac console/UI or generated manually by the helper.
- After successful pairing, the helper stores the device public key and issues a refresh token for that device.
- The app exchanges the refresh token for short-lived access tokens.
- Every API request includes both an auth header and a request signature tied to the access token and request contents.

This gives defense in depth:
- TLS protects transport.
- Pinning protects against helper impersonation.
- Device keypair proves device identity.
- Access token authorizes the session.
- Request signature reduces replay and narrows the blast radius of token leakage.

## 4.2 Why not trust the local network

Do not rely on any of these as security controls:
- same Wi‑Fi
- RFC1918/private IP ranges
- same subnet
- mDNS/Bonjour discovery alone
- source IP allowlists
- obscurity of a high port
- local-only origin assumptions in the browser

These are convenience features, not trust primitives.

## 5. Token and session design

## 5.1 Pairing flow

Recommended initial enrollment flow:
1. User starts helper in pairing mode on the Mac.
2. Helper generates:
   - a short-lived pairing code, 8-12 characters, random, no ambiguous characters
   - a `pairing_id`
   - expiry timestamp, e.g. 5 minutes
3. iOS app asks user for helper URL and pairing code.
4. App generates device keypair locally.
5. App calls `POST /v1/auth/pair/complete` over HTTPS with:
   - pairing code
   - device name
   - device public key
   - app version / platform info
6. Helper validates code and expiry, stores device public key, and returns:
   - device identifier
   - refresh token
   - server metadata
   - optional certificate pinset / current fingerprint for UI confirmation
7. App stores:
   - helper base URL
   - pinned certificate/public key hash
   - device ID
   - refresh token
   - local private key reference

Important properties:
- Pairing code must be single-use.
- Pairing must be rate-limited.
- Pairing mode should be off by default.
- Helper should log pairing attempts without storing the code value.

## 5.2 Access token model

Recommended token types:

1. Refresh token
- Long-lived, device-scoped, random 256-bit secret.
- Stored only in secure storage on the phone.
- Stored hashed server-side, not plaintext.
- Rotated on every successful refresh if feasible.
- Revocable per device.

2. Access token
- Short-lived, e.g. 5 minutes.
- Opaque random token or compact signed token.
- Simpler and safer for this helper: opaque random token stored server-side with device ID, expiry, scope, and session metadata.
- Include minimal scope now: `status:read logs:read`.

Why opaque tokens instead of JWT first:
- Easier revocation.
- Simpler implementation in a small helper.
- Fewer opportunities to misuse claims validation.
- No need for stateless cross-service scaling here.

## 5.3 Session lifecycle

Recommended endpoints:
- `POST /v1/auth/pair/start` or helper-local CLI only for creating pairing codes
- `POST /v1/auth/pair/complete`
- `POST /v1/auth/token/refresh`
- `POST /v1/auth/logout`
- `POST /v1/auth/revoke-device`
- `GET /v1/auth/whoami`

Recommended behavior:
- Access tokens expire in 5 minutes.
- Refresh tokens expire in 30-90 days or remain persistent until revoked, depending on UX preference.
- Refresh token rotation on every refresh is preferred.
- If a refresh token is replayed after rotation, revoke the whole device session and require re-pairing.
- App refreshes proactively when access token is close to expiry.
- Helper should cap active sessions per device.

## 5.4 Request signing

Bearer-only auth is better than nothing, but for a production local-network helper I recommend proof-of-possession style request signing.

Recommended headers on each request:
- `Authorization: Bearer <access-token>`
- `X-Device-ID: <device-id>`
- `X-Timestamp: <unix-epoch-seconds>`
- `X-Nonce: <random-128-bit>`
- `X-Content-SHA256: <hex body hash>`
- `X-Signature: <base64 signature>`
- `X-Key-ID: <device-key-id>`

Signing string example:
- HTTP method
- canonical path + sorted query
- timestamp
- nonce
- body hash
- access token hash or session ID

Signature algorithm:
- Preferred: Ed25519 if available cleanly across platforms.
- Strong Apple-native alternative: P-256 ECDSA via CryptoKit/Secure Enclave.

Server verification rules:
- Reject timestamps outside a small skew window, e.g. ±60 seconds.
- Reject reused nonces for the active token window.
- Verify body hash before signature verification result is accepted.
- Bind the signature to the exact method/path/query/body.
- Optionally bind to the access token ID so a signature cannot be replayed with a different token.

Why sign if TLS already exists:
- Reduces the value of token theft from logs/memory.
- Adds replay protection.
- Helps future-proof the design for any write endpoints.

If implementation complexity must be reduced for phase 1, the minimum acceptable baseline is:
- HTTPS + certificate pinning
- device-scoped refresh/access tokens
- strict rate limiting
- no CORS wildcard

Then add request signing in phase 2.

## 6. Transport security

## 6.1 Require HTTPS

The helper should not serve production traffic over plain HTTP.

Recommended options, in order:
1. HTTPS directly in the helper with a locally generated self-signed certificate and app-side certificate/public-key pinning.
2. HTTPS terminated by a localhost reverse proxy only if operationally justified, but this adds complexity for a personal helper.

For this project, option 1 is simplest.

## 6.2 Certificate strategy

Recommended approach:
- Generate a helper-specific self-signed certificate on first run.
- Store certificate + private key in a protected helper state directory and/or macOS Keychain-backed storage.
- Pin the helper certificate public key hash in the iOS app after successful pairing.
- On certificate rotation, require explicit trust update, ideally during a trusted paired session.

Do not rely on:
- insecure trust-all URLSession delegate logic
- hostname mismatch exceptions without pinning
- disabled certificate validation

## 6.3 ATS posture on iOS

Current `project.yml` explicitly sets:
- `NSAllowsArbitraryLoads: true`

This should be removed.

Target state:
- ATS enabled by default.
- Only HTTPS connections allowed.
- If a local-network exception is still required during migration, keep it as narrow and temporary as possible.
- Long term, rely on TLS + pinning rather than arbitrary loads.

## 6.4 Local discovery

If convenience discovery is desired later, use Bonjour/mDNS only for discovery metadata, not trust.

Discovery can tell the app “a helper exists at this IP/port,” but trust must still come from:
- certificate pinning
- successful pairing
- valid auth/session state

## 7. Secret storage design

## 7.1 iOS

Store the following in Keychain, not `@AppStorage` or `UserDefaults`:
- refresh token
- device ID
- private key reference
- certificate pin / SPKI hash
- optional last trusted helper fingerprint

Keep in `@AppStorage` only non-sensitive preferences, such as:
- display refresh interval
- maybe the helper URL if desired, though storing it in Keychain is also acceptable

Preferred private-key strategy:
- Generate a Secure Enclave-backed P-256 signing key if supported.
- Mark non-exportable.
- Require device-unlock access control.

## 7.2 Mac helper

Store the following securely:
- TLS private key
- helper config secret(s)
- hashed refresh tokens
- device public keys
- nonce replay cache metadata

Recommended storage split:
- Secret values: macOS Keychain if practical, or a rootless per-user secret store with file mode `0600` if Keychain integration is too heavy initially.
- Non-secret structured state: `~/Library/Application Support/GitHubAutoUpdaterHelper/`.

Suggested files/state:
- `config.json` or `settings.json` for non-secret runtime config
- `devices.json` for paired device metadata and public keys
- `sessions.json` or lightweight SQLite database for refresh/access token records and nonce replay state
- TLS certificate files in an app support subdirectory with strict permissions if not stored in Keychain

Important storage rules:
- Never store plaintext refresh tokens after issuance; store only a salted hash.
- Never log bearer tokens, pairing codes, or full signatures.
- Zero or redact sensitive values in debug output.

## 8. API design recommendations

## 8.1 Version the API

Move from anonymous endpoints:
- `/status`
- `/log/main`
- `/log/alert`
- `/log/repo/<name>`

To versioned endpoints:
- `GET /v1/status`
- `GET /v1/logs/main`
- `GET /v1/logs/alert`
- `GET /v1/logs/repos/{repo}`
- auth endpoints under `/v1/auth/*`

## 8.2 Response hardening

Recommended server behaviors:
- Return correct HTTP status codes and structured JSON errors.
- Add `Cache-Control: no-store` for auth responses and sensitive logs.
- Add `Content-Security-Policy: default-src 'none'` if any HTML is ever served, though currently JSON only.
- Remove `Access-Control-Allow-Origin: *` unless there is a browser client requirement. If browser use is not required, omit CORS entirely.
- Add request ID/correlation ID for debugging.

## 8.3 Minimize exposed data

Production status payload should not expose more than needed.

Consider reducing or gating these fields:
- raw `crontab`
- absolute file paths
- full backup paths

Prefer summarized status objects over raw operational internals. Keep detailed diagnostics behind an authenticated, explicit “advanced diagnostics” scope if needed.

## 9. Recommended implementation phases

## Phase 0: Security cleanup baseline

Goal:
- Remove obviously unsafe defaults before adding auth complexity.

Changes:
- Remove ATS arbitrary loads.
- Stop returning CORS wildcard headers.
- Introduce API version prefix.
- Add central request/response helpers on both client and helper.
- Add helper config/state directory.

## Phase 1: Pairing + bearer auth + HTTPS

Goal:
- Achieve a secure minimum viable authenticated helper.

Changes:
- Helper creates/stores TLS certificate.
- iOS client validates helper certificate with pinning.
- Add device pairing and refresh/access tokens.
- Move tokens to Keychain.
- Require `Authorization` on all protected endpoints.
- Add rate limits and audit logging.

## Phase 2: Proof-of-possession request signing

Goal:
- Reduce replay/token theft risk and prepare for future mutating endpoints.

Changes:
- Generate device signing keypair.
- Add signature headers.
- Verify timestamp, nonce, body hash, and signature server-side.
- Add nonce replay cache.

## Phase 3: Hardening and operations

Goal:
- Make the helper maintainable and supportable.

Changes:
- Device management UI/CLI on Mac.
- Revoke specific devices.
- Rotate helper certificate safely.
- Add tests, metrics, structured logs, and backup/recovery procedures.

## 10. Concrete file-by-file change plan

This section names what should change, even though this document does not make code changes.

### iOS app: modify existing files

#### `GitHubAutoUpdaterApp/APIClient.swift`

Current role:
- Anonymous GETs using `URLSession.shared`.

Planned changes:
- Replace `URLSession.shared` with a dedicated session configured with a delegate for trust evaluation/pinning.
- Build `URLRequest` objects instead of `data(from:)`.
- Attach auth headers and request-signing headers to protected requests.
- Inspect `HTTPURLResponse` and map 401/403/429/5xx to typed errors.
- Add automatic access-token refresh and retry-once logic through an auth coordinator.
- Canonicalize path/query/body for request signing.
- Support only `https://` URLs in production mode.

#### `GitHubAutoUpdaterApp/AppViewModel.swift`

Current role:
- Stores `serverURL` and fetches status/logs.

Planned changes:
- Remove responsibility for raw auth/session handling.
- Depend on an `AuthManager` and `APIClient` abstraction.
- Track pairing state, trust state, and auth errors separately from transport errors.
- Add explicit onboarding states: unpaired, pairing, paired, expired session, certificate mismatch.
- Avoid loading protected data until pairing is complete.

#### `GitHubAutoUpdaterApp/Models.swift`

Planned changes:
- Add auth-related DTOs:
  - `PairingRequest`
  - `PairingResponse`
  - `RefreshTokenRequest`
  - `AccessTokenResponse`
  - `APIErrorResponse`
  - `WhoAmIResponse`
- Introduce versioned response models if the helper payload shape changes.
- Consider reducing direct exposure to raw filesystem path fields.

#### `GitHubAutoUpdaterApp/RootView.swift`

Planned changes:
- Replace the simple settings-only connection model with pairing UX.
- Add views/sections for:
  - helper URL input
  - pairing code input
  - trusted helper fingerprint display/confirmation
  - session expiration/re-pair prompts
  - device revocation awareness
- Show certificate mismatch as a distinct, high-severity warning.

#### `project.yml`

Planned changes:
- Remove `INFOPLIST_KEY_NSAppTransportSecurity -> NSAllowsArbitraryLoads: true`.
- Add any minimal ATS exceptions only if strictly required during migration.
- Keep `NSLocalNetworkUsageDescription`.
- If Bonjour discovery is added later, add Bonjour service declarations.
- Add any additional source files listed below.

### iOS app: add new files

#### `GitHubAutoUpdaterApp/AuthManager.swift`

Responsibilities:
- Own pairing, refresh, logout, and token rotation logic.
- Expose current auth state to `AppViewModel`.
- Serialize refresh requests to avoid token stampedes.
- Invalidate local credentials on revocation/certificate mismatch.

#### `GitHubAutoUpdaterApp/KeychainStore.swift`

Responsibilities:
- Wrap Keychain reads/writes/deletes.
- Store refresh token, device ID, certificate pin, private key reference.
- Centralize secure-accessibility classes.

#### `GitHubAutoUpdaterApp/RequestSigner.swift`

Responsibilities:
- Canonicalize requests.
- Produce body hash and signature headers.
- Use Secure Enclave/CryptoKit key material.

#### `GitHubAutoUpdaterApp/ServerTrustEvaluator.swift`

Responsibilities:
- Handle TLS challenge validation.
- Compare certificate/SPKI pins.
- Support planned pin rotation rules.

#### `GitHubAutoUpdaterApp/AuthModels.swift`

Responsibilities:
- Keep auth/session DTOs separate from status/log models if preferred for clarity.

Optional additions:
- `GitHubAutoUpdaterApp/SettingsStore.swift`
- `GitHubAutoUpdaterApp/PairingView.swift`
- `GitHubAutoUpdaterApp/SecurityStatusView.swift`

### Mac helper: modify existing files

#### `helper/status_server.py`

Current role:
- Entire helper implementation.

Planned changes:
- Reduce this file to bootstrap/wiring only.
- Load config and secrets.
- Start HTTPS server, not plain `HTTPServer` on HTTP.
- Register versioned routes.
- Apply auth middleware to protected routes.
- Remove `Access-Control-Allow-Origin: *` default.
- Bind to configurable interface/port.
- Add structured logging and graceful error handling.

### Mac helper: add new files

#### `helper/config.py`

Responsibilities:
- Load runtime config.
- Resolve app support paths.
- Validate bind host, port, TLS paths, and security settings.

#### `helper/models.py`

Responsibilities:
- Define typed request/response and persistence models.
- Device record, session record, pairing record, API error types.

#### `helper/storage.py`

Responsibilities:
- Manage device/session persistence.
- Hash refresh tokens.
- Track revocation state.
- Maintain nonce replay cache.
- Prefer SQLite or a simple atomic JSON store depending on complexity tolerance.

#### `helper/auth.py`

Responsibilities:
- Pairing code generation/validation.
- Access token issuance.
- Refresh token rotation.
- Authorization checks for protected endpoints.
- Device revocation.

#### `helper/crypto.py`

Responsibilities:
- Hashing, constant-time comparisons, request-signature verification, token generation.
- TLS pin/fingerprint helper functions.

#### `helper/tls.py`

Responsibilities:
- Certificate bootstrap/generation/loading.
- SSL context creation.
- Certificate rotation support.

#### `helper/routes.py`

Responsibilities:
- Define `/v1/status`, `/v1/logs/*`, and `/v1/auth/*` routing.
- Keep business logic thin by calling service modules.

#### `helper/security.py`

Responsibilities:
- Rate limiting.
- IP-based abuse controls.
- Timestamp/nonce replay window checks.
- Request ID generation.
- Header validation.

#### `helper/log_access.py`

Responsibilities:
- Existing file/log reading logic moved out of transport layer.
- Path normalization and output minimization.

#### `helper/tests/`

Add tests for:
- pairing success/failure/expiry
- token refresh and rotation
- revoked device behavior
- nonce replay rejection
- signature verification failure modes
- unauthorized/expired token responses
- route authorization matrix

Suggested files:
- `helper/tests/test_auth.py`
- `helper/tests/test_signing.py`
- `helper/tests/test_routes.py`
- `helper/tests/test_storage.py`

## 11. API contract proposal

## 11.1 Pairing

`POST /v1/auth/pair/complete`

Request:
```json
{
  "pairingId": "...",
  "pairingCode": "ABCD-92KQ",
  "deviceName": "Core’s iPhone",
  "devicePublicKey": "base64...",
  "platform": "iOS",
  "appVersion": "0.2.0"
}
```

Response:
```json
{
  "deviceId": "dev_123",
  "refreshToken": "rt_...",
  "accessToken": "at_...",
  "expiresAt": "2026-03-16T20:00:00Z",
  "server": {
    "name": "core-macbook",
    "certificatePin": "sha256/..."
  }
}
```

## 11.2 Refresh

`POST /v1/auth/token/refresh`

Request:
```json
{
  "deviceId": "dev_123",
  "refreshToken": "rt_..."
}
```

Response:
```json
{
  "accessToken": "at_...",
  "refreshToken": "rt_rotated_...",
  "expiresAt": "2026-03-16T20:05:00Z"
}
```

## 11.3 Protected request

Example:
`GET /v1/status`

Headers:
```text
Authorization: Bearer at_...
X-Device-ID: dev_123
X-Timestamp: 1773710400
X-Nonce: 7f6c4ef5d7f84f35975b05d57b0a17b5
X-Content-SHA256: e3b0c44298fc1c149afbf4c8996fb924...
X-Key-ID: key_1
X-Signature: base64signature...
```

## 12. Security requirements checklist

The implementation should not be considered production-ready until all are true:

- [ ] Helper serves HTTPS only for production traffic.
- [ ] iOS app pins helper certificate/public key.
- [ ] ATS arbitrary loads removed.
- [ ] No anonymous access to status or log endpoints.
- [ ] Pairing is explicit, short-lived, single-use, and rate-limited.
- [ ] Tokens are device-scoped and revocable.
- [ ] Refresh tokens are stored hashed server-side.
- [ ] iOS secrets stored in Keychain, not `@AppStorage`.
- [ ] Request timestamps and nonces enforced.
- [ ] Sensitive headers/tokens never logged.
- [ ] CORS wildcard removed unless explicitly justified.
- [ ] API versioning introduced.
- [ ] Tests cover auth, refresh, replay, and revocation cases.
- [ ] Certificate mismatch produces a blocking warning in the app.

## 13. Testing strategy

### Unit tests

Helper:
- pairing code issuance and expiry
- refresh token hashing and rotation
- access token expiry
- signature verification
- nonce replay cache eviction and rejection
- route authorization

iOS:
- Keychain storage wrapper
- request canonicalization/signing
- auth retry logic on expired access tokens
- trust evaluator pin match/mismatch behavior

### Integration tests

- Pair a fresh device against a new helper instance.
- Refresh an access token successfully.
- Confirm expired access token triggers refresh.
- Confirm revoked refresh token forces re-pairing.
- Confirm MITM-style certificate mismatch blocks requests.
- Confirm replaying the same signed request is rejected.
- Confirm unpaired device receives 401/403 on protected endpoints.

### Manual validation

- Try helper access from an unpaired browser/client on the same LAN.
- Rotate helper certificate and verify trust-mismatch UX.
- Revoke a device and confirm the app cannot recover without re-pairing.
- Review helper logs to ensure no tokens or secrets appear.

## 14. Risks and tradeoffs

### Simpler but weaker option

The lowest-complexity acceptable solution is:
- HTTPS
- certificate pinning
- pairing
- refresh/access bearer tokens
- Keychain storage

This is much easier than adding proof-of-possession signatures and is probably good enough for many home-lab deployments.

### Stronger but more complex option

Add device-key request signing on top.

Benefits:
- Better replay resistance
- Better protection if access tokens leak
- Better future support for write endpoints

Costs:
- More code on both sides
- Nonce cache/state handling
- More failure modes and clock-skew UX

Recommended decision:
- Build the code structure to support signing from day one.
- Ship phase 1 first if schedule matters.
- Add signing before adding any state-changing helper endpoints.

## 15. Recommended order of implementation

1. Refactor helper into modules without changing behavior.
2. Introduce versioned routes and central error handling.
3. Add helper config/state directory and persistence model.
4. Add TLS certificate generation and HTTPS serving.
5. Remove ATS arbitrary loads and add iOS trust evaluation/pinning.
6. Add pairing flow.
7. Add refresh/access tokens and Keychain storage.
8. Protect all current endpoints with auth.
9. Add device revocation and audit logging.
10. Add request signing and nonce replay protection.
11. Reduce sensitive payload fields where possible.
12. Add comprehensive tests and a production-readiness review.

## 16. Bottom line

The current app/helper design is a prototype with zero meaningful network security. The most important production changes are:
- move from HTTP to HTTPS,
- remove ATS arbitrary loads,
- add explicit device pairing,
- store secrets in Keychain/secure storage,
- require short-lived authenticated sessions for every endpoint,
- and ideally add proof-of-possession request signing for replay resistance.

If these changes are implemented in the file layout described above, the helper API will have a credible path from “trusted toy on a LAN” to a production-grade authenticated local service.