# Push Notifications on Failures: Production Readiness Plan

> For Hermes: this is a design and implementation plan only. Do not modify code while executing this task.

## Goal

Deliver reliable iOS push notifications when the Mac-side GitHub auto updater detects actionable failures, without exposing local-network-only infrastructure directly to APNs and without leaking sensitive repository or filesystem data.

## Current architecture in this repo

### iOS app

Files inspected:
- `GitHubAutoUpdaterApp/GitHubAutoUpdaterApp.swift`
- `GitHubAutoUpdaterApp/AppViewModel.swift`
- `GitHubAutoUpdaterApp/APIClient.swift`
- `GitHubAutoUpdaterApp/Models.swift`
- `GitHubAutoUpdaterApp/RootView.swift`
- `GitHubAutoUpdaterApp/Info.plist`
- `project.yml`

Current behavior:
- The app is a SwiftUI iOS client that polls a helper URL stored in `@AppStorage("serverURL")`, defaulting to `http://127.0.0.1:8787`.
- It calls the Mac helper over plain HTTP using `URLSession.shared` to fetch:
  - `/status`
  - `/log/main`
  - `/log/alert`
  - `/log/repo/<repo>`
- It shows repository status, logs, cron presence, and backup directories.
- It has no push registration, no APNs token handling, no notification permission flow, no background remote notification support, and no entitlements file.
- `project.yml` currently allows arbitrary loads and local-network access, but does not define Push Notifications capability or background modes.

### Mac helper

Files inspected:
- `helper/status_server.py`
- `README.md`

Current behavior:
- The helper is a small local HTTP server on port `8787`.
- It reads cron, updater logs, alert logs, and per-repo logs from the local filesystem.
- It derives current repo state by scanning recent log lines and classifying them as `ok`, `skipped`, `warning`, `failed`, or `unknown`.
- It exposes read-only status APIs to the iOS app.
- It does not emit events, store notification state, authenticate clients, or communicate with any cloud backend.

### Architectural gap

The current design is local-network polling only. APNs requires an internet-reachable provider. Because the helper is local-only and the iPhone is not guaranteed to be on the same LAN, production push notifications require a new server-side push provider layer plus explicit device registration and failure-event delivery.

## Recommended target architecture

Recommended production architecture:

1. iOS app registers for APNs and obtains a device token.
2. iOS app sends the device token plus installation metadata to a cloud backend.
3. Mac helper detects updater failures and posts signed failure events to the same backend.
4. Backend applies dedupe, policy, rate limits, and privacy filtering.
5. Backend sends APNs notifications to the registered devices for the correct user/installations.
6. iOS app opens into the relevant repo/log context when the user taps the notification.

In short: APNs should be sent by a backend service, not directly by the Mac helper.

## APNs options

### Option A: Direct APNs from your own backend using token-based auth

Recommended.

Why:
- Standard Apple architecture.
- Keeps the APNs auth key off the user’s Mac.
- Lets you centralize retries, dedupe, token invalidation, auditing, and rate limiting.
- Easiest way to support multiple iPhones per user later.
- Simplifies future Android/webhook/email fallback support.

Operational shape:
- Use APNs provider token auth with:
  - Apple Team ID
  - Key ID
  - `.p8` APNs Auth Key
  - app bundle identifier as topic: `com.core.githubautoupdater` unless changed
- Maintain separate APNs environment handling for development vs production.

### Option B: Direct APNs from the Mac helper

Not recommended except for private single-user experiments.

Why not:
- Requires shipping or provisioning APNs credentials to the Mac.
- Harder to rotate secrets safely.
- Poor fit for a helper that may be restarted, offline, or run by non-technical users.
- Hard to coordinate token invalidation and multi-device targeting.
- Couples notification delivery to the local machine’s outbound network and clock correctness.

### Option C: Third-party push relay (Firebase, OneSignal, SNS, etc.)

Acceptable only if product priorities favor speed over control.

Pros:
- Faster initial implementation.
- Built-in dashboards and retry behavior.

Cons:
- Extra vendor dependency.
- More data sharing with third parties.
- Potential mismatch with a small, privacy-sensitive personal infrastructure tool.

Recommendation:
- Prefer Option A for production.
- Avoid Option B for production.
- Use Option C only if you explicitly want managed push infrastructure.

## Server responsibilities

A new backend service is required. This does not currently exist in the repo.

### Core responsibilities

1. Device registration
- Accept device-token registrations from iOS.
- Associate tokens with a user/account and optionally a specific Mac installation.
- Track app version, platform, bundle ID, APNs environment, locale, and last seen timestamp.

2. Installation registration
- Maintain a stable `installation_id` for each Mac/helper deployment.
- Store display name like `core-macbook-pro` or user-provided label.
- Link installation to one or more device registrations.

3. Event ingestion
- Accept failure events from the Mac helper over HTTPS.
- Authenticate each event with a signed token or HMAC.
- Normalize, validate, and persist the event.

4. Notification decisioning
- Determine whether the event is actionable.
- Deduplicate repeated failures from the same run/repo/signature.
- Apply cooldowns and grouping.
- Optionally suppress low-value states like local-changes skips.

5. APNs delivery
- Build the push payload.
- Send to all active tokens for the owning user/installation.
- Interpret APNs responses.
- Disable invalid tokens.

6. History and observability
- Store event records, send attempts, and APNs responses.
- Expose admin logs or dashboards for debugging.
- Support replay for testing.

### Suggested backend API surface

Suggested endpoints:
- `POST /v1/devices/register`
- `POST /v1/devices/unregister`
- `POST /v1/installations/register`
- `POST /v1/events/updater-failure`
- `POST /v1/events/updater-recovery` (optional but strongly recommended)
- `GET /v1/notifications/preferences`
- `PUT /v1/notifications/preferences`

### Suggested backend data model

Tables or equivalent collections:
- `users`
- `installations`
- `devices`
- `device_installations` or equivalent join mapping
- `updater_events`
- `notification_deliveries`
- `notification_preferences`
- `event_dedup_cache` or indexed dedupe fields on `updater_events`

## Notification trigger design from the Mac/helper side

The helper currently only serves status. Production push requires event production.

### Trigger source options

#### Preferred: trigger from the updater run itself

Best source of truth:
- Hook at the point where the updater script already knows run outcome, repo name, and stderr/summary.
- Emit an event when a run or repo transitions into a failure state.

Why preferred:
- Lower latency than polling logs.
- Easier to attach run IDs and precise error reasons.
- Fewer false positives from parsing truncated logs.

#### Acceptable fallback: trigger by log/state analysis in the helper

If the updater script cannot be changed immediately:
- Add helper-side polling or tailing that computes deltas from the repo log files and alert log.
- Persist previous state locally to detect transitions.

Tradeoff:
- More fragile because log parsing is heuristic-based.
- Still workable as an incremental step.

### Trigger policy

Send a notification only on transitions into actionable failure, not on every failing poll.

Recommended trigger conditions:
- `ok -> failed`
- `warning -> failed` when the warning becomes actionable
- repeated `failed` only after cooldown or materially changed fingerprint
- optional summary notification when cron itself is missing or helper health is degraded for a prolonged period

Recommended non-trigger or lower-priority cases:
- `skip: working tree has local changes`
- transient local helper read errors that self-heal quickly
- repeated identical failures within cooldown window

### Failure fingerprinting

Each event should carry enough data to dedupe repeated identical failures.

Suggested fingerprint inputs:
- `installation_id`
- repo name
- normalized failure category
- normalized summary line
- updater run ID or nearest timestamp bucket

Example categories:
- `git_pull_failed`
- `merge_conflict`
- `not_a_repo`
- `permission_denied`
- `script_missing`
- `cron_missing`
- `unknown_failure`

### Local durability on the Mac

The helper should not lose notifications because the backend is temporarily unavailable.

Recommended local behavior:
- Write outbound events to a local spool directory before attempting upload.
- Mark each event as `pending`, `sent`, `acked`, or `dead-letter`.
- Retry pending events with backoff.
- Preserve idempotency keys across retries.

Suggested local state files/dirs:
- `~/.local/var/lib/github-auto-updater/push/queue/`
- `~/.local/var/lib/github-auto-updater/push/state.json`
- `~/.local/var/log/github-auto-updater.push.log`

## Payload design

Two payloads matter: the backend event payload and the APNs payload.

### Mac helper -> backend event payload

Recommended request body:

```json
{
  "event_id": "uuid-v7",
  "idempotency_key": "install123:repoA:git_pull_failed:2026-03-16T19:00Z",
  "installation_id": "inst_abc123",
  "installation_name": "core-macbook-pro",
  "occurred_at": "2026-03-16T19:00:13Z",
  "run_id": "2026-03-16T19:00:00Z",
  "repo": "github_auto_updater",
  "state": "failed",
  "previous_state": "ok",
  "category": "git_pull_failed",
  "summary": "git pull failed: authentication error",
  "severity": "error",
  "fingerprint": "sha256:...",
  "log_ref": {
    "kind": "repo",
    "name": "github_auto_updater"
  },
  "details": {
    "exit_code": 1,
    "branch": "main"
  }
}
```

Notes:
- Do not send full log bodies by default.
- Send compact structured metadata plus a short sanitized summary.
- Include an idempotency key so retries do not create duplicate pushes.

### APNs payload

Use an alert notification, not silent push, for failure alerts.

Recommended APNs headers:
- `apns-push-type: alert`
- `apns-priority: 10`
- `apns-topic: <bundle id>`
- `apns-collapse-id: <installation_id>:<repo>` for deduping latest active issue per repo/install

Recommended payload:

```json
{
  "aps": {
    "alert": {
      "title": "GitHub Auto Updater failure",
      "body": "github_auto_updater on core-macbook-pro needs attention."
    },
    "sound": "default",
    "badge": 1,
    "thread-id": "failures",
    "category": "UPDATER_FAILURE"
  },
  "event_type": "updater.failure",
  "installation_id": "inst_abc123",
  "installation_name": "core-macbook-pro",
  "repo": "github_auto_updater",
  "state": "failed",
  "category": "git_pull_failed",
  "event_id": "uuid-v7",
  "deep_link": "githubautoupdater://repo/github_auto_updater?event_id=uuid-v7"
}
```

Design rules:
- Keep payload small.
- Avoid paths like `/Users/core/...` in push content.
- Avoid raw stderr unless explicitly user-enabled.
- Use custom keys sufficient to deep-link into the app.

### Recovery payload

Strongly recommended so users know when a failure is gone.

Example title/body:
- Title: `GitHub Auto Updater recovered`
- Body: `github_auto_updater on core-macbook-pro is healthy again.`

Send only if there was a previously-notified active failure.

## Retry and delivery strategy

### Mac/helper -> backend retry

Implement durable retry with exponential backoff.

Recommended policy:
- Retry on network errors and HTTP `5xx`
- Do not retry malformed `4xx` except `429`
- Backoff: 1 min, 5 min, 15 min, 1 hr, then every 6 hr up to retention limit
- Add jitter
- Retain unsent events for at least 7 days
- Use idempotency keys so duplicate submissions are harmless

### Backend -> APNs retry

Recommended policy:
- Treat APNs `5xx`, timeouts, and connection resets as retryable
- Retry with bounded exponential backoff and jitter
- Do not retry token-invalid errors like `BadDeviceToken` or `Unregistered`; deactivate token
- Respect APNs error semantics exactly
- Store per-delivery attempt records

### Notification dedupe and throttling

Recommended rules:
- One push per active failure fingerprint per installation/repo within a cooldown window
- Cooldown default: 6 hours for identical failures
- If summary/category changes materially, send again immediately
- If 10 repos fail at once, consider a roll-up notification plus in-app details rather than 10 separate pushes

### App-side handling

The app should:
- register categories/actions once at launch
- update badge counts based on unresolved failures if you support badges
- deep-link to the relevant repo/log context when opened from a notification
- gracefully handle stale event IDs by showing current status if detailed event history is unavailable

## Privacy and security

### Security posture

The current helper is a local unauthenticated HTTP server. That is fine for LAN polling experiments, but not enough for production event delivery.

For push notifications:
- Mac helper -> backend must use HTTPS only.
- Authenticate helper requests using one of:
  - short-lived installation access token issued at registration time, preferred
  - HMAC-signed requests with rotating shared secret
  - mTLS only if you want heavier operational overhead
- iOS device registration should be authenticated to a user account or pairing secret.
- Backend secrets and APNs keys must never live in the iOS app binary or the helper repo.

### Data minimization

Recommended defaults:
- Include repo display name and a short sanitized failure category.
- Exclude full file paths, full log contents, branch names, remotes, commit hashes, and raw command output unless needed.
- Store only the minimum metadata necessary for delivery, dedupe, and debugging.

### User controls

Expose user preferences for:
- push enabled/disabled
- notify on failure only vs failure + recovery
- notify for all repos vs selected repos
- include repo names in notification text or use generic wording when privacy mode is enabled

### Lock screen privacy modes

Support two modes:
- Standard: `Repo X on Mac Y failed`
- Private: `GitHub Auto Updater needs attention`

## Recommended implementation phases

### Phase 0: Define product semantics
- Decide what counts as a push-worthy failure.
- Decide whether `skipped` due to local changes is noisy warning vs push-worthy issue.
- Decide whether notification scope is per repo, per run, or per installation summary.
- Decide whether recovery pushes are enabled by default.

### Phase 1: Add iOS notification plumbing
- Add Push Notifications capability.
- Add remote notification registration flow.
- Add notification permission UX and settings screen controls.
- Add deep-link handling for notification opens.
- Add device registration API client.

### Phase 2: Build backend push service
- Implement device registration and installation registration.
- Implement failure-event ingestion endpoint.
- Implement APNs sender with token auth.
- Implement dedupe, rate limits, and delivery logs.

### Phase 3: Extend Mac helper into an event producer
- Add installation identity and pairing flow.
- Add failure transition detection.
- Add durable event queue and HTTPS upload.
- Add retry/backoff and dead-letter handling.

### Phase 4: Observability and rollout hardening
- Add structured logs and metrics.
- Add admin tooling for replaying events to APNs sandbox.
- Run staged rollout with one installation, then multiple devices.

## Concrete code and file changes

This section names the files in this repo that should change, plus the likely new files/modules to add.

### Existing files to modify in this repo

#### `project.yml`
Add or change:
- Push Notifications capability / entitlements reference
- Background Modes if you want remote-notification background handling
- potentially stricter ATS for production backend access instead of broad arbitrary loads
- any URL scheme registration needed for deep linking

Why:
- The current project spec has local-network access and arbitrary loads but no push capability.

#### `GitHubAutoUpdaterApp/Info.plist`
Add or generate values for:
- notification-related usage/config if needed by your design
- URL scheme/deep-link entries if using `githubautoupdater://...`

Why:
- Currently empty.

#### `GitHubAutoUpdaterApp/GitHubAutoUpdaterApp.swift`
Add:
- notification center delegate setup
- permission request flow entry point
- APNs registration kick-off
- `onOpenURL` or equivalent deep-link entry

#### `GitHubAutoUpdaterApp/AppViewModel.swift`
Add:
- notification preference state
- device registration calls
- unread/unresolved failure tracking if badges are supported
- app launch handling for notification-open context

#### `GitHubAutoUpdaterApp/APIClient.swift`
Add endpoints for:
- register device token
- unregister token
- update notification preferences
- fetch event details or notification history if supported

Also consider:
- move away from LAN-only assumptions and introduce a separate backend base URL from the helper base URL

#### `GitHubAutoUpdaterApp/Models.swift`
Add models for:
- device registration request/response
- installation registration state
- notification preferences
- push event metadata / deep-link payload models

#### `GitHubAutoUpdaterApp/RootView.swift`
Add UI for:
- enabling/disabling notifications
- showing current notification authorization state
- selecting notification privacy mode and repo scope
- navigating to repo details when app opens from notification

#### `helper/status_server.py`
Extend or refactor to add:
- installation identity management
- event generation from updater status transitions
- durable local queue/spool
- signed HTTPS upload to backend
- retry scheduling
- optional health endpoint for notification subsystem state

This file may become too large; splitting it is recommended.

### New iOS files recommended

Add files like:
- `GitHubAutoUpdaterApp/NotificationManager.swift`
  - owns `UNUserNotificationCenter`, permission checks, APNs callbacks
- `GitHubAutoUpdaterApp/NotificationRouter.swift`
  - converts push payloads into navigation targets
- `GitHubAutoUpdaterApp/BackendConfig.swift`
  - separates helper URL from cloud API URL
- `GitHubAutoUpdaterApp/NotificationModels.swift`
  - push/deep-link payload structs
- `GitHubAutoUpdaterApp/GitHubAutoUpdaterApp.entitlements`
  - push entitlement and any background mode-related config

### New helper-side files recommended

Split Python responsibilities rather than overloading `status_server.py`:
- `helper/event_detector.py`
  - computes state transitions from updater results/logs
- `helper/push_queue.py`
  - durable queue, retry bookkeeping, dead-letter handling
- `helper/backend_client.py`
  - signed HTTPS requests to backend
- `helper/config.py`
  - backend URL, installation ID, secret locations
- `helper/models.py`
  - typed event payloads
- `helper/push_worker.py`
  - background delivery loop if run separately

### New backend service components recommended

These do not exist in the repo today, but are required for a production system.

Suggested modules:
- `backend/api/devices.*`
- `backend/api/installations.*`
- `backend/api/events.*`
- `backend/services/apns_sender.*`
- `backend/services/event_router.*`
- `backend/services/dedupe.*`
- `backend/services/preferences.*`
- `backend/db/schema/*`
- `backend/jobs/retry_failed_pushes.*`

## Suggested contracts between components

### Device registration request

```json
{
  "device_token": "hex-token",
  "bundle_id": "com.core.githubautoupdater",
  "platform": "ios",
  "apns_environment": "production",
  "installation_id": "inst_abc123",
  "app_version": "0.2.0"
}
```

### Installation registration request

```json
{
  "installation_id": "inst_abc123",
  "installation_name": "core-macbook-pro",
  "helper_version": "0.2.0",
  "repo_count": 12
}
```

### Backend response to event ingest

```json
{
  "accepted": true,
  "event_id": "uuid-v7",
  "deduped": false,
  "notifications_enqueued": 1
}
```

## Failure classification policy

Recommended first-pass policy table:

| Condition | App status | Push? | Notes |
|---|---|---:|---|
| `ok:` line | ok | No | Recovery event only if prior active failure existed |
| `skip: working tree has local changes` | skipped | Usually no | Too noisy by default |
| `skip: not a git repository` | warning | Maybe | User-configurable |
| repo-level hard error | failed | Yes | Primary push trigger |
| cron missing | warning/error | Yes after persistence threshold | Avoid pushing on transient read error |
| helper cannot read logs | unknown/warning | Maybe | Push only if prolonged and status visibility is degraded |

## Operational concerns

### Pairing and ownership

You need a way to associate one Mac helper with one or more iOS devices.

Recommended pattern:
- app authenticates user to backend
- helper registration uses a short-lived pairing code or signed login URL
- helper receives `installation_id` and secret/token after pairing

Avoid:
- hard-coded shared secrets in the repo
- manual device-token copy/paste

### Environment separation

Keep separate:
- development APNs sandbox
- production APNs
- dev/staging/prod backend base URLs

The app and backend should agree on the APNs environment for each token.

### Monitoring and alerting

Track metrics such as:
- event ingestion success rate
- helper queue depth
- event-to-push latency
- APNs acceptance rate
- invalid token rate
- dedupe suppression count

### Testing plan

Minimum production test matrix:
- simulator/app launch behavior without APNs token
- real device permission denied / allowed / provisional if used
- backend registration with valid and invalid token
- helper offline then reconnect replay
- duplicate failure events with same idempotency key
- repeated identical repo failure within cooldown
- repo failure followed by recovery
- invalidated APNs token cleanup
- notification tap deep-linking to repo/log view

## Recommended implementation choice summary

1. Use a dedicated backend push provider with APNs token auth.
2. Keep the Mac helper as the source of updater failure events, but not the APNs sender.
3. Trigger pushes on failure state transitions, not repeated status polls.
4. Use durable helper-side queueing with idempotent event ingest.
5. Keep payloads intentionally small and privacy-preserving.
6. Add recovery notifications and user-configurable privacy/noise controls.
7. Refactor the helper into separate modules as soon as push logic is introduced.

## What not to do

- Do not send APNs directly from the local helper in production.
- Do not put the APNs `.p8` key on the Mac or in the iOS app.
- Do not push full logs, absolute filesystem paths, or secrets to lock screens.
- Do not notify on every failing poll cycle.
- Do not rely on the local HTTP helper as the only route for mobile visibility.

## Exit criteria for production readiness

The feature is production-ready when all of the following are true:
- real iOS devices can register and unregister tokens reliably
- helper installations can pair and authenticate securely to the backend
- a single updater failure produces at most one timely user-facing push inside the cooldown window
- backend retries transient APNs failures and disables invalid tokens automatically
- helper retries transient backend failures without dropping events
- notification content reveals no sensitive paths/logs by default
- tapping the notification opens the correct context in the app
- recovery notifications close the loop for previously-notified failures
- metrics and logs are sufficient to debug delivery problems
