# Manual Run Updater Action from iOS via Mac Helper POST Endpoint

> For Hermes: this is a production-readiness implementation plan only. Do not modify code as part of this task.

## Goal

Add a production-grade manual "Run updater now" action in the iOS app that calls a Mac helper POST endpoint, starts one updater job at a time, returns a durable job record immediately, and lets the app observe job status and progress safely until completion.

## Current architecture analysis

### iOS app today

Relevant files:
- `GitHubAutoUpdaterApp/APIClient.swift`
- `GitHubAutoUpdaterApp/AppViewModel.swift`
- `GitHubAutoUpdaterApp/Models.swift`
- `GitHubAutoUpdaterApp/RootView.swift`
- `GitHubAutoUpdaterApp/GitHubAutoUpdaterApp.swift`
- `project.yml`

Observed behavior:
- The app is a thin SwiftUI client over a helper URL stored in `@AppStorage("serverURL")` with a default of `http://127.0.0.1:8787`.
- `APIClient.swift` supports only GET requests for `/status` and `/log/*`.
- `AppViewModel.swift` only performs refresh/read operations. There is no mutation flow, no request state machine for actions, and no polling for a background job.
- `Models.swift` only models passive status/log payloads.
- `RootView.swift` exposes dashboard/log/settings views, but no destructive or privileged remote action.
- `project.yml` currently enables `NSAllowsArbitraryLoads: true` and a local-network usage description. That is acceptable for prototyping but not production-grade for a privileged helper action.

Implication:
- The iOS app is currently read-only. It needs action models, authenticated POST support, explicit job-state UI, and better transport security.

### Mac helper today

Relevant file:
- `helper/status_server.py`

Observed behavior:
- The helper is a single-file `http.server.HTTPServer` process.
- It exposes unauthenticated GET endpoints:
  - `GET /status`
  - `GET /log/main`
  - `GET /log/alert`
  - `GET /log/repo/{name}`
- It reads crontab, log files, and repo-log summaries from disk.
- It has no POST endpoints, no auth, no request validation, no durable state store, no concurrency control, and no notion of a job lifecycle.
- `HTTPServer` is single-threaded, so a long-running request would block all other requests if the updater were run inline.
- `Access-Control-Allow-Origin: *` is enabled universally. That is risky once write-capable endpoints exist.

Implication:
- The helper must evolve from a read-only status scraper into a small authenticated job-control service.
- The updater execution must happen asynchronously in a subprocess, never inline inside the request handler.

### Existing updater contract

From `README.md` and helper constants:
- updater script: `/Users/core/.local/bin/github-auto-update.sh`
- main log: `/Users/core/.local/var/log/github-auto-update.log`
- alert log: `/Users/core/.local/var/log/github-auto-update.alert.log`
- per-repo logs: `/Users/core/.local/var/log/github-auto-update/`
- scheduled via cron every 30 minutes

Implication:
- The safest first version is to reuse the existing script as the execution unit rather than reimplement updater logic in Python.
- Manual runs must coexist with cron without overlapping the same script concurrently.

## Recommended target architecture

Use a helper-managed job model.

1. iOS sends an authenticated `POST /v1/runs` request.
2. Helper validates auth, idempotency key, and current lock state.
3. Helper creates or reuses a job record and starts the updater in a background subprocess only if no equivalent/in-flight job already exists.
4. Helper returns `202 Accepted` with a job payload immediately.
5. iOS polls `GET /v1/runs/{job_id}` for status and progress and optionally refreshes existing log endpoints.
6. Helper updates the job record as the subprocess advances and marks it terminal when finished.

This keeps the request path fast, makes retries safe, and prevents the UI from blocking on a long shell execution.

## API design

### Versioning

Introduce versioned write APIs now:
- `POST /v1/runs`
- `GET /v1/runs/{job_id}`
- `GET /v1/runs`
- optional later: `POST /v1/runs/{job_id}/cancel`

Keep existing read-only endpoints for backward compatibility for now:
- `/status`
- `/log/*`

Longer term, move those to `/v1/status` and `/v1/logs/*` too.

### Create run endpoint

`POST /v1/runs`

Headers:
- `Authorization: Bearer <shared-secret-or-token>`
- `Idempotency-Key: <uuid>`
- `Content-Type: application/json`

Request body, minimum viable version:

```json
{
  "trigger": "ios_manual",
  "requested_by": "ios-app",
  "client_request_id": "optional-client-generated-uuid"
}
```

Recommended response: `202 Accepted`

```json
{
  "job": {
    "id": "run_20260316_192700_8f3c",
    "status": "queued",
    "trigger": "ios_manual",
    "requested_by": "ios-app",
    "created_at": "2026-03-16T19:27:00Z",
    "updated_at": "2026-03-16T19:27:00Z",
    "started_at": null,
    "finished_at": null,
    "progress": {
      "phase": "queued",
      "message": "Run accepted by helper",
      "percent": 0,
      "repos_total": null,
      "repos_completed": null,
      "current_repo": null
    },
    "result": null,
    "idempotency_key": "8f11062d-..."
  }
}
```

Possible status codes:
- `202 Accepted`: new job created or existing equivalent in-flight job returned
- `200 OK`: exact idempotent replay of an already-created job
- `401 Unauthorized`: missing/invalid token
- `409 Conflict`: another active run blocks this one and policy is "reject instead of reuse"
- `422 Unprocessable Entity`: malformed request body or invalid fields
- `429 Too Many Requests`: caller is spamming create-run requests
- `500 Internal Server Error`: helper-side failure before job creation

Recommendation:
- Prefer returning the existing active job on duplicate/manual overlap rather than forcing the iOS client to handle a hard conflict in the common retry case.

### Job lookup endpoint

`GET /v1/runs/{job_id}`

Headers:
- `Authorization: Bearer <token>`

Response:

```json
{
  "job": {
    "id": "run_20260316_192700_8f3c",
    "status": "running",
    "trigger": "ios_manual",
    "requested_by": "ios-app",
    "created_at": "2026-03-16T19:27:00Z",
    "updated_at": "2026-03-16T19:27:14Z",
    "started_at": "2026-03-16T19:27:02Z",
    "finished_at": null,
    "progress": {
      "phase": "updating_repo",
      "message": "Updating repo foo",
      "percent": 42,
      "repos_total": 12,
      "repos_completed": 5,
      "current_repo": "foo"
    },
    "result": null,
    "exit_code": null,
    "summary": null,
    "links": {
      "main_log": "/log/main",
      "alert_log": "/log/alert"
    }
  }
}
```

Terminal states:
- `succeeded`
- `failed`
- `cancelled`
- `timed_out`

### Job list endpoint

`GET /v1/runs?limit=20`

Purpose:
- show recent run history in app
- recover state after app restart
- reconcile if the create response was lost

This is strongly recommended even if the first UI only surfaces the latest run.

### Optional cancel endpoint

`POST /v1/runs/{job_id}/cancel`

Not required for the initial manual-run feature. Add only if the updater script can be cancelled safely and child processes are cleaned up correctly.

## Authentication and transport security requirements

The current helper has no auth and listens on `0.0.0.0`. That is not acceptable for a write-capable endpoint.

### Minimum acceptable auth for v1

Use a shared bearer token stored on both sides.

Requirements:
- helper reads `GITHUB_AUTO_UPDATER_HELPER_TOKEN` from environment or a local config file outside git
- iOS stores the token in Keychain, not `UserDefaults`/`@AppStorage`
- every `POST /v1/runs` and `GET /v1/runs*` request requires `Authorization: Bearer ...`
- constant-time token comparison on the helper side
- failed auth attempts logged without echoing secrets

This is enough for a trusted LAN/home-lab deployment, but it is still not strong enough for hostile networks.

### Stronger recommended production posture

Add TLS and narrow trust.

Preferred options, in order:
1. Bind helper to localhost and expose it only through a trusted reverse proxy with HTTPS, auth, and IP allowlisting.
2. If direct LAN access is required, terminate TLS with a local cert and do certificate pinning in the iOS app.
3. Restrict helper bind address to the LAN interface you actually need, not all interfaces.

### iOS transport changes

Current `NSAllowsArbitraryLoads: true` should be removed for production.

Replace it with one of:
- ATS exception only for the exact local helper hostname if staying on HTTP temporarily
- preferably HTTPS-only helper access with certificate pinning

### CORS

The helper currently sends `Access-Control-Allow-Origin: *`.

For a native iOS app this header is not needed at all. For a write-capable API:
- remove the wildcard
- either omit CORS entirely or restrict it tightly if a browser client is later introduced

## Idempotency requirements

Manual actions from mobile must be retry-safe because of flaky Wi‑Fi, app suspension, and duplicate taps.

### Create semantics

Require `Idempotency-Key` on `POST /v1/runs`.

Rules:
- key is generated by iOS per tap intent
- helper stores the key with a normalized request fingerprint and resulting `job_id`
- if the same key is replayed with the same body within a retention window, return the same job record
- if the same key is replayed with a different body, return `409 Conflict` or `422` with a clear error
- retain idempotency records for at least 24 hours

### Active-run deduplication

Add a second layer beyond per-request idempotency.

Policy recommendation:
- only one updater run may be active at a time across cron + iOS manual trigger
- if a manual request arrives while another run is `queued` or `running`, return the existing job record and indicate that the request was coalesced

That prevents duplicate subprocesses even when different idempotency keys are used.

### Locking

Use an OS-level lock so cron and helper cannot overlap.

Recommendation:
- helper acquires a lock file such as `~/.local/var/run/github-auto-update.lock`
- updater subprocess should also respect the same lock if possible
- if the script already has its own locking, reuse that contract; do not invent a conflicting second lock without reviewing the script

## Job status and progress tracking

A production design needs durable state visible across helper restarts.

### Job state model

Suggested states:
- `queued`
- `starting`
- `running`
- `succeeded`
- `failed`
- `timed_out`
- `cancelled`

Suggested job fields:
- `id`
- `trigger` (`cron`, `ios_manual`, maybe `helper_cli` later)
- `requested_by`
- `idempotency_key`
- `status`
- `created_at`
- `updated_at`
- `started_at`
- `finished_at`
- `pid`
- `exit_code`
- `progress.phase`
- `progress.message`
- `progress.percent`
- `progress.repos_total`
- `progress.repos_completed`
- `progress.current_repo`
- `summary`
- `error`
- `main_log_offset` or other pointers if useful

### Persistence

Persist jobs to disk, not memory only.

Recommended options:
- simplest: JSON file store under `~/.local/share/github-auto-updater-helper/jobs/`
- better: SQLite if you expect concurrency, history, and querying to grow

Given the current repo size and helper simplicity, JSON files are sufficient if writes are atomic.

Requirements:
- atomic writes via temp-file + rename
- on helper startup, reload active/recent jobs
- reconcile any `running` job whose process no longer exists into `failed` or `unknown_recovery_needed`

### Progress source

There are three practical options.

Option A: coarse progress inferred from subprocess lifecycle
- queued -> starting -> running -> succeeded/failed
- easiest to implement
- lowest fidelity

Option B: parse existing updater stdout/stderr or main log for known markers
- medium effort
- acceptable if the script already emits stable repo-level lines

Option C: enhance the updater script to emit structured progress events
- best long-term design
- example: JSON lines written to stdout or a sidecar progress file

Recommendation:
- phase 1: ship coarse progress with state + timestamps + current log tail
- phase 2: add structured progress output from the shell script and parse it in the helper for repo-level counts

## Safety concerns and operational guardrails

### Prevent overlapping runs

This is the top safety requirement.

Overlapping manual and cron runs can cause:
- concurrent git operations in the same worktrees
- lockups or corrupted working directories
- misleading logs and backup behavior

Enforce a single active run globally.

### Timeouts

A stuck updater must not run forever.

Requirements:
- subprocess timeout configured, e.g. 30-60 minutes depending on repo count
- helper marks job `timed_out`
- helper terminates child process tree cleanly, then force-kills if needed

### Command execution safety

Do not shell-interpolate user data.

Requirements:
- no user-supplied command fragments in the request body for v1
- run the known script path only
- use `subprocess.Popen([...], shell=False)`
- fixed working directory and sanitized environment

### Request scope

For v1, do not expose repo-selection, arbitrary path, branch, or script override controls from iOS.

Why:
- reduces command injection surface
- avoids partial-run semantics until the updater script explicitly supports them
- keeps the mobile action aligned with cron behavior

### Auditing

Log every manual run request with:
- timestamp
- remote IP
- auth success/failure
- job id
- trigger source
- final outcome

Do not log bearer tokens.

### Rate limiting

Even on a LAN, add simple rate limiting.

Example:
- max 5 create-run attempts per minute per client IP
- repeated auth failures back off aggressively

### Service management

For production use, the helper should be managed by `launchd`, not an ad hoc foreground Python command.

Benefits:
- auto restart
- standard logs
- env injection for token/config
- reliable boot behavior

## Recommended file and code changes

This section lists the code/files that should change during implementation.

### Mac helper

Modify:
- `helper/status_server.py`

Refactor responsibilities out of the giant single file into new helper modules if allowed by repo conventions. Recommended new files:
- `helper/config.py` — load token, host, port, storage paths, timeout
- `helper/auth.py` — bearer-token parsing and constant-time comparison
- `helper/job_store.py` — atomic persistence for job and idempotency records
- `helper/job_runner.py` — lock acquisition, subprocess launch, timeout, completion handling
- `helper/progress.py` — parse stdout/log markers into progress updates
- `helper/models.py` — request/response/job-state helpers

If the repo intentionally wants to stay single-file, keep those as internal classes in `status_server.py`, but modularizing will improve testability substantially.

Behavioral changes needed in helper:
- add POST support via `do_POST`
- parse and validate JSON request bodies
- require auth on new `/v1/runs*` endpoints
- maintain an in-memory active-job index backed by disk persistence
- spawn updater asynchronously in a subprocess
- poll/reconcile subprocess state without blocking request threads
- optionally switch from `HTTPServer` to `ThreadingHTTPServer` so status/log requests remain responsive during job creation and polling
- remove wildcard CORS behavior for write APIs
- add structured error responses

### iOS app

Modify:
- `GitHubAutoUpdaterApp/APIClient.swift`
- `GitHubAutoUpdaterApp/AppViewModel.swift`
- `GitHubAutoUpdaterApp/Models.swift`
- `GitHubAutoUpdaterApp/RootView.swift`
- `GitHubAutoUpdaterApp/Info.plist` and/or `project.yml`

Recommended new Swift files:
- `GitHubAutoUpdaterApp/RunModels.swift` — `CreateRunRequest`, `RunJob`, `RunProgress`, `RunListResponse`
- `GitHubAutoUpdaterApp/KeychainStore.swift` — helper token storage
- `GitHubAutoUpdaterApp/RunActionView.swift` or a new section inside `RootView.swift` for the manual-run UI

Behavioral changes needed in iOS:
- add authenticated POST support in `APIClient`
- send `Idempotency-Key` on manual-run requests
- store and reuse the in-flight `job_id`
- poll job endpoint while a run is active
- disable the run button while a run is active or while create request is in flight
- show queued/running/succeeded/failed states clearly
- surface summary and last-updated timestamps
- handle auth errors distinctly from connectivity errors
- move helper token storage to Keychain
- tighten ATS instead of using blanket arbitrary loads

### Documentation and operations

Modify:
- `README.md`

Recommended new docs:
- `docs/production-readiness/manual-run-updater-action.md` — this plan
- `docs/operations/helper-deployment.md` — launchd, token config, bind address, TLS/proxy guidance
- `docs/api/helper-api.md` — endpoint contracts and example payloads

## Suggested implementation phases

### Phase 0: verify external contract

Before coding, confirm:
- whether `~/.local/bin/github-auto-update.sh` already has locking
- whether the script emits stable progress markers worth parsing
- whether cron can call the same wrapper used by the helper, or vice versa

If the script currently lacks locking, fix that before exposing manual run from iOS.

### Phase 1: helper-side job control

Deliverables:
- authenticated `POST /v1/runs`
- `GET /v1/runs/{job_id}`
- durable job store
- single-active-run lock
- subprocess timeout handling
- coarse status reporting

This creates a safe backend even before the iOS UI is polished.

### Phase 2: iOS action flow

Deliverables:
- run button in dashboard
- confirmation prompt: "Run updater now on your Mac?"
- token entry/storage in settings
- create-run request with idempotency key
- polling and result display
- disabled states and retry UX

### Phase 3: richer progress and history

Deliverables:
- recent runs list
- repo-level progress counts
- better summaries sourced from structured updater output
- deep links from a job to current logs

### Phase 4: production hardening

Deliverables:
- launchd service definition
- TLS or reverse proxy hardening
- ATS tightening
- rate limiting
- audit logging
- helper test coverage and failure-injection testing

## UI/UX recommendations for iOS

On the dashboard, add a section like:
- Manual Run: button
- Active Run Status: queued/running/succeeded/failed
- Started At / Finished At
- Progress message
- Open logs / refresh status

Interaction rules:
- first tap asks for confirmation
- second identical tap should not create a new run if one is already active
- if the create request times out client-side, app should recover by listing recent runs or reusing the same idempotency key
- if auth is missing, route the user to Settings to enter the helper token

## Error-handling contract

Use structured JSON errors everywhere.

Example:

```json
{
  "error": {
    "code": "run_already_active",
    "message": "An updater run is already in progress",
    "job_id": "run_20260316_192700_8f3c"
  }
}
```

Suggested error codes:
- `unauthorized`
- `invalid_request`
- `invalid_idempotency_key`
- `idempotency_conflict`
- `run_already_active`
- `job_not_found`
- `helper_misconfigured`
- `subprocess_launch_failed`
- `run_timed_out`

## Testing requirements

### Helper tests

Add automated tests for:
- auth required and rejected correctly
- idempotent replay returns same job
- conflicting replay with same key returns error
- only one active run can exist
- completed job transitions are persisted
- timeout path marks job appropriately
- malformed JSON and unknown routes return correct errors
- log/status endpoints remain responsive while a run is active

### iOS tests

Add tests for:
- create-run request builds proper headers
- job decoding across all states
- view-model polling lifecycle
- duplicate button taps do not issue duplicate create requests
- auth error messaging vs connectivity error messaging
- run button enable/disable logic

### Manual end-to-end verification

1. Start helper with a configured token.
2. Configure the app with helper URL + token.
3. Tap "Run updater now" once.
4. Verify one job record is created and the script starts exactly once.
5. Tap again during execution.
6. Verify the same active job is returned or surfaced, not a second subprocess.
7. Kill/restart helper mid-run.
8. Verify job recovery/reconciliation is sane.
9. Break auth intentionally.
10. Verify app shows an auth-specific error.
11. Simulate a long/stuck updater.
12. Verify timeout and terminal state handling.

## Acceptance criteria

The feature is production-ready when all of the following are true:
- iOS can trigger a manual run using an authenticated POST request.
- Duplicate taps and network retries do not create duplicate updater executions.
- At most one updater run is active across manual and cron triggers.
- The helper returns a durable job id immediately and tracks status to completion.
- The iOS UI shows run state and outcome without freezing or guessing.
- Secrets are not stored in plaintext app preferences.
- The helper no longer exposes a write-capable unauthenticated LAN endpoint.
- The system fails safely under helper restarts, script hangs, and transient network failures.

## Recommended implementation order

1. Review the shell updater script and confirm/add locking.
2. Add helper config + auth loading.
3. Add durable job store and idempotency store.
4. Add subprocess-based job runner with timeout.
5. Add `POST /v1/runs` and `GET /v1/runs/{job_id}`.
6. Add iOS run models and API methods.
7. Add iOS manual-run UI and polling flow.
8. Tighten ATS and token storage.
9. Add tests.
10. Add launchd/deployment docs.

## Bottom line

The right production design is not "iOS hits a POST endpoint that directly runs the shell script in the request handler." The right design is "iOS creates an authenticated, idempotent run job; the helper safely serializes execution in the background; and the app observes that durable job until completion." That matches the current read-only architecture, minimizes risk, and leaves room for richer progress and history later.
