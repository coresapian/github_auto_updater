# Background Refresh Production Readiness Plan

## Scope

This document analyzes the current iOS app + Mac helper architecture in `/Users/core/GitHub/github_auto_updater` and proposes a production-grade implementation plan for background refresh in the iOS app.

No code was modified while producing this plan.

## Current architecture

### iOS app

Current iOS implementation is a small SwiftUI application with one shared `AppViewModel`:

- `GitHubAutoUpdaterApp/GitHubAutoUpdaterApp.swift`
  - Creates `@StateObject private var viewModel = AppViewModel()`
  - Triggers one foreground refresh with `.task { await viewModel.refresh() }`
- `GitHubAutoUpdaterApp/AppViewModel.swift`
  - Stores `serverURL` and `refreshInterval` in `@AppStorage`
  - Holds all app state in memory (`status`, selected repo, log text, error text, loading flag)
  - `refresh()` fetches `/status`, then always fetches `/log/main` and `/log/alert`, then fetches the selected repo log
  - No persistence layer, no refresh coordinator, no lifecycle hooks, no background task integration
- `GitHubAutoUpdaterApp/APIClient.swift`
  - Uses `URLSession.shared`
  - No custom timeout policy, cache policy, reachability handling, validation, ETag support, or background-aware session configuration
- `GitHubAutoUpdaterApp/Models.swift`
  - Decodes a single `StatusResponse` plus log payloads
  - No timestamps, revisions, sync metadata, or persisted snapshot model
- `GitHubAutoUpdaterApp/RootView.swift`
  - Manual refresh only
  - Settings exposes `refreshInterval`, but that value does not currently drive any scheduler
  - UI assumes data exists only in current process memory

### Mac helper

The Mac-side helper is a small synchronous HTTP server:

- `helper/status_server.py`
  - Serves `/status`, `/log/main`, `/log/alert`, and `/log/repo/<name>`
  - Computes status by reading cron config and local log files on demand
  - No auth, no cache headers, no timestamps/revisions in the payload, no lightweight summary endpoint
  - Returns all repo status each time `/status` is called

### Important architectural observation

The iOS app is currently a foreground polling client, not a background-capable sync client.

That matters because iOS background refresh is not a timer. The system grants limited execution windows opportunistically. A production design must therefore:

1. Persist the last known status locally
2. Fetch a small payload during background execution
3. Avoid downloading large logs in the background
4. Reschedule work every time a task runs
5. Tolerate long gaps, skipped runs, and network unreachability

## iOS constraints that must shape the design

### 1) Background refresh cadence is heuristic, not guaranteed

`BGAppRefreshTask` does not run every N seconds or every N minutes. iOS decides when to launch the app based on device state, battery, usage patterns, network conditions, user behavior, and the app's historical execution time.

Implication:
- The current `refreshInterval` setting cannot mean "refresh every 30 seconds" in the background.
- For production, the setting should become a user preference that influences `earliestBeginDate`, not a guarantee.

### 2) This app depends on a local-network Mac helper

The app only works when:
- the helper is running on the Mac
- the iPhone can reach that Mac over LAN
- local network permissions are granted
- the device is on the same network path as the helper

Implication:
- Many background launches will fail simply because the user is away from home/office Wi‑Fi or the Mac is asleep.
- Failures must be treated as normal environmental outcomes, not exceptional corruption.

### 3) Background windows are short

The app should assume a short execution budget. Pulling `/status` plus multiple full log payloads is wasteful.

Implication:
- Background refresh should update only lightweight status metadata.
- Full log downloads should remain foreground-only or on-demand.

### 4) App process may be cold-started for the task

A background task may launch the app in a fresh process with no in-memory state.

Implication:
- All essential status must be loadable from disk.
- Task orchestration must not depend on a live SwiftUI view hierarchy.

### 5) Users can disable Background App Refresh

Production behavior must degrade cleanly when the capability is off.

Implication:
- The app should still refresh on foreground activation and manual pull.
- The UI should clearly indicate whether background refresh is available/enabled.

## Production target architecture

Implement background refresh as a small, durable sync pipeline rather than as an extension of `AppViewModel`.

### Recommended separation of responsibilities

1. `AppViewModel`
   - UI-facing observable state only
   - Loads cached snapshot immediately on launch
   - Triggers foreground refresh requests through a sync service

2. `RefreshCoordinator` or `BackgroundRefreshManager`
   - Registers `BGTaskScheduler` task identifiers
   - Schedules the next refresh after launch, foreground refresh, and task completion
   - Owns background task handlers and expiration behavior

3. `StatusSyncService`
   - Performs a lightweight refresh against the helper
   - Writes a persisted snapshot atomically
   - Returns a structured sync result (`success`, `noChange`, `temporaryFailure`, `permanentFailure`)

4. `SnapshotStore`
   - Reads and writes cached state on disk
   - Stores sync metadata such as `lastSuccess`, `lastAttempt`, `lastError`, `consecutiveFailureCount`, payload revision, and source URL

5. `APIClient`
   - Uses a dedicated `URLSessionConfiguration`
   - Adds request timeout, response validation, and optional conditional request support

This split keeps UI state, persistence, and scheduler behavior independent.

## Recommended refresh model

### Background task type

Use `BGAppRefreshTask`, not `BGProcessingTask`.

Why:
- This workload is a short metadata fetch
- It should not require external power
- It should not require long-running processing
- `BGProcessingTask` would be excessive and less appropriate for simple status sync

### What background refresh should fetch

Background refresh should fetch only a compact status payload.

Recommended background payload:
- cron installed state
- last updater run timestamp
- overall repo statuses / counts
- per-repo summary state and message
- server-side revision or last-modified timestamp
- optional "hasAlert" boolean / recent failure summary

Background refresh should not fetch:
- full main log text
- full alert log text
- full selected repo log text

Those log endpoints are comparatively heavy and have low value for a background budget.

### Foreground refresh behavior

Foreground/manual refresh can still fetch logs, but should be staged:

1. Load cached snapshot instantly
2. Fetch `/status` first
3. Update dashboard state
4. Lazily fetch visible log content only if the user is on the Logs screen or explicitly requests it

This avoids every refresh paying the cost of three log downloads.

## Refresh cadence plan

### User-facing semantics

Rename the existing setting conceptually from "refresh interval" to "preferred background refresh cadence".

Important product wording:
- Do not promise exact intervals
- Explain that iOS decides actual background execution timing
- Present the preference as a hint to the system

### Suggested cadence mapping

Map the current `refreshInterval` value into conservative `earliestBeginDate` buckets.

Recommended mapping:
- 10s to 300s setting today should not be used literally for background work
- Replace with UI options such as:
  - "System default"
  - "About hourly"
  - "A few times per day"
  - "Daily"

If keeping numeric values for now, translate internally as:
- 10-60 seconds -> schedule earliest begin ~30-60 minutes
- 60-300 seconds -> schedule earliest begin ~1-3 hours

Production recommendation:
- Default target: earliest begin around 1 hour
- On repeated failures: back off to 2h, 4h, then 8h
- On success: return to baseline schedule

### Rescheduling rules

Always submit the next `BGAppRefreshTaskRequest` in all of these places:
- application launch
- scene phase change to background
- after manual foreground refresh success/failure
- at the end of every background task handler

Never assume a previously submitted request is sufficient forever.

## State synchronization strategy

### Current gap

Right now all data is ephemeral. If the app is relaunched in the background, there is nothing to synchronize against and nothing useful to display later unless the network request succeeds.

### Persisted snapshot design

Introduce a persisted snapshot model containing at minimum:

- `status: StatusResponse` or a background-specific lightweight equivalent
- `fetchedAt`
- `lastSuccessfulRefreshAt`
- `lastAttemptAt`
- `failureCount`
- `lastErrorSummary`
- `serverURL`
- `serverRevision` or `lastModified` if helper support is added
- `isStale`

Optionally persist:
- `selectedRepoID`
- cached log metadata, but not necessarily full log content

### Source of truth rules

Recommended rules:

1. Disk snapshot is the durable source of truth across launches.
2. In-memory `AppViewModel` mirrors the disk snapshot.
3. Background refresh writes disk first, then notifies interested UI state if the app is active.
4. Foreground refresh merges over cached data instead of replacing everything with blanks during loading.

### Conflict model

This app is single-writer in practice, but foreground and background refresh could overlap.

Use these protections:
- one refresh pipeline at a time
- actor-based sync service or explicit mutex/serial queue
- monotonic `fetchedAt` / revision checks before replacing snapshot
- atomic file write

## Failure handling plan

### Failure classes

Treat failures explicitly by class.

1. Configuration failures
   - malformed `serverURL`
   - background refresh disabled
   - missing task registration

2. Environmental failures
   - no local network permission
   - helper unreachable
   - device off LAN
   - Mac asleep/offline

3. Server/protocol failures
   - helper returns malformed JSON
   - non-200 responses
   - timeout
   - payload schema mismatch

4. Task lifecycle failures
   - background task expiration before completion
   - duplicate scheduling attempts

### Handling policy

Configuration failures:
- surface clearly in Settings
- do not keep aggressively rescheduling high-frequency work

Environmental failures:
- mark snapshot stale
- preserve last known good data
- increment transient failure counter
- apply backoff
- avoid clearing the dashboard to empty

Server/protocol failures:
- preserve last known data
- log a compact diagnostic string
- count toward retry backoff

Expiration:
- cancel in-flight network request
- call `task.setTaskCompleted(success: false)`
- reschedule with backoff

### UX policy for failure

The dashboard should show:
- last successful refresh time
- whether displayed data is cached/stale
- a concise connection state such as:
  - "Updated 42m ago"
  - "Using cached status; helper unreachable"
  - "Background refresh unavailable"

That is much better than replacing valid data with a raw transport error banner.

## Mac helper changes recommended for production readiness

Background refresh can be implemented entirely on the iOS side against the current `/status` endpoint, but production quality will improve substantially if the helper exposes a lighter and more cacheable summary.

### Recommended helper additions

In `helper/status_server.py`:

1. Add timestamps to the payload
   - `generatedAt`
   - `lastUpdaterRunAt` if derivable

2. Add revision metadata
   - `revision` computed from the newest relevant file mtimes or a hash of summary content

3. Add a lightweight summary endpoint
   - `GET /status/summary`
   - returns status metadata only, not large log content

4. Add cache-friendly headers if practical
   - `ETag`
   - `Last-Modified`

5. Optionally add a cheap health endpoint
   - `GET /healthz`
   - useful for fast connectivity diagnostics

This is especially important because the current `/status` payload may grow with repo count.

## Concrete code/file change plan

Below is the recommended file-level implementation plan.

### 1) `project.yml`

Add BackgroundTasks capability and the permitted task identifiers.

Planned changes:
- enable background mode for app refresh
- define `BGTaskSchedulerPermittedIdentifiers`
- ensure generated Info.plist contains the background task identifier

Recommended identifier:
- `com.core.githubautoupdater.refresh`

Also consider adding any required generated plist keys through XcodeGen rather than editing the checked-in `Info.plist` stub directly.

### 2) `GitHubAutoUpdaterApp/Info.plist`

If plist generation is not fully controlled by `project.yml`, update this file to include:
- `BGTaskSchedulerPermittedIdentifiers`
- `UIBackgroundModes` with `fetch`

Source of truth should ideally remain `project.yml` to avoid drift.

### 3) `GitHubAutoUpdaterApp/GitHubAutoUpdaterApp.swift`

Expand app bootstrap responsibilities:
- register background task handler during app initialization
- load cached snapshot immediately on launch
- schedule refresh on startup
- observe app/scene lifecycle and reschedule when entering background

Recommended responsibilities in this file:
- create shared `RefreshCoordinator`
- inject shared `SnapshotStore` / `StatusSyncService` into `AppViewModel`
- call a `scheduleNextRefresh()` API at controlled lifecycle points

### 4) New file: `GitHubAutoUpdaterApp/BackgroundRefreshManager.swift`

Create a dedicated type for:
- `BGTaskScheduler.shared.register(...)`
- `submitAppRefresh(after:)`
- handling `BGAppRefreshTask`
- cancellation on expiration
- rescheduling after completion
- translating user preference + failure backoff into `earliestBeginDate`

This should not live inside SwiftUI view code.

### 5) New file: `GitHubAutoUpdaterApp/StatusSyncService.swift`

Create an actor or isolated service that:
- performs the lightweight status fetch
- classifies failures
- updates the snapshot store atomically
- returns a strongly typed sync result
- prevents overlapping refresh operations

Recommended method surface:
- `refresh(trigger: .foreground | .background | .manual) async -> SyncOutcome`
- `loadCachedSnapshot() -> CachedStatusSnapshot?`

### 6) New file: `GitHubAutoUpdaterApp/SnapshotStore.swift`

Persist the last known dashboard state.

Responsibilities:
- encode/decode cached snapshot JSON
- store sync metadata
- perform atomic writes
- provide stale-age calculations
- optionally publish change notifications

Preferred storage:
- `Application Support` JSON file
- not `UserDefaults` for the full payload

Keep `UserDefaults` / `@AppStorage` only for small preferences.

### 7) `GitHubAutoUpdaterApp/AppViewModel.swift`

Refactor away from being the direct network orchestrator.

Planned changes:
- depend on `StatusSyncService` rather than raw `APIClient`
- expose cached status immediately on app start
- show last refresh metadata and stale state
- trigger manual/foreground refresh through the service
- stop fetching all logs inside `refresh()`
- split dashboard refresh from log refresh

Recommended state additions:
- `lastRefreshDescription`
- `isUsingCachedData`
- `backgroundRefreshAvailable`
- `connectionStatus`

### 8) `GitHubAutoUpdaterApp/APIClient.swift`

Harden for production use.

Planned changes:
- create a dedicated `URLSession` with explicit timeout intervals
- validate `HTTPURLResponse` status codes
- support conditional requests if helper adds `ETag` / `Last-Modified`
- support lightweight summary endpoint
- distinguish timeout/unreachable/decoding failures

Optional addition:
- separate methods for `fetchStatusSummary()` and `fetchLog()`

### 9) `GitHubAutoUpdaterApp/Models.swift`

Add models for background sync metadata.

Planned additions:
- `CachedStatusSnapshot`
- `SyncOutcome`
- `RefreshTrigger`
- `ConnectionState`
- lightweight `StatusSummaryResponse` if helper summary endpoint is added

Also extend status models with optional server-provided timestamps/revision fields if helper changes ship.

### 10) `GitHubAutoUpdaterApp/RootView.swift`

Update the UI to reflect cached/background behavior.

Planned changes:
- show last updated time on Dashboard
- show stale/cached status badge
- explain that background refresh is system-managed
- replace the current seconds-based setting UI with a background cadence preference
- keep log loading user-initiated or view-driven

The key UX change is that the app should always show the last known status first, then refine it.

### 11) `helper/status_server.py`

Recommended production changes on the helper side:
- add `generatedAt`
- add `revision`
- add `/status/summary`
- optionally emit `ETag` / `Last-Modified`
- optionally make request handling more concurrent if future load increases

The helper does not need a radical redesign, but it should support smaller and more deterministic background fetches.

## Execution sequence

Implement in this order:

### Phase 1: Durable client state
- add `SnapshotStore`
- add cached snapshot model
- load snapshot at launch
- update UI to display cached data and staleness

### Phase 2: Sync service extraction
- move network refresh logic from `AppViewModel` into `StatusSyncService`
- separate dashboard refresh from log refresh
- ensure logs are foreground-only/on-demand

### Phase 3: Background task integration
- add BackgroundTasks entitlement/configuration
- add `BackgroundRefreshManager`
- register task on launch
- schedule next refresh on launch/background/completion

### Phase 4: Failure/backoff hardening
- classify errors
- store failure count and last error summary
- implement cadence backoff
- add expiration handling and cancellation

### Phase 5: Helper protocol improvements
- add summary endpoint and timestamps
- optionally add revision/ETag support
- switch background sync to summary endpoint

## Testing and validation plan

### Functional testing

1. Foreground cold launch with helper reachable
   - cached snapshot appears immediately if present
   - fresh status replaces cache

2. Foreground cold launch with helper unreachable
   - cached snapshot remains visible
   - UI shows stale/connection warning

3. Manual refresh while reachable
   - status updates
   - logs load only on demand

4. Manual refresh while unreachable
   - no data loss
   - failure metadata updates

### Background task testing

Validate with Xcode background task simulation and device testing:
- task registration succeeds
- task executes in cold-start conditions
- background sync fetches summary only
- snapshot persists
- next task is rescheduled
- expiration handler cancels work cleanly

### Environmental testing specific to this app

Test all of these real-world cases on device:
- on same Wi‑Fi as Mac helper
- on cellular away from LAN
- Mac sleeping
- helper not running
- local network permission denied
- Background App Refresh disabled in Settings
- Low Power Mode

### Performance targets

Background run goals:
- one lightweight request
- minimal JSON decoding
- no large log transfers
- finish well under the system expiration window

## Risks and mitigations

### Risk: users expect exact polling cadence
Mitigation:
- rename the setting and explain iOS-managed scheduling in UI

### Risk: local-network dependency makes background refresh appear unreliable
Mitigation:
- show cached status age clearly
- classify unreachable-helper as expected environmental state

### Risk: current payload grows with repo count
Mitigation:
- add summary endpoint and optional revision metadata

### Risk: data disappears on failed refresh
Mitigation:
- persist and preserve last known good snapshot

### Risk: background and foreground refresh race
Mitigation:
- centralize refresh in a single actor/service and serialize writes

## Recommended acceptance criteria

This feature should be considered production-ready when all of the following are true:

1. The app shows last known status immediately on launch without waiting for the network.
2. Background refresh uses `BGAppRefreshTask` and successfully reschedules itself.
3. Background sync fetches status summary only, not full logs.
4. Failed refreshes never erase valid previously cached status.
5. The UI exposes last success time, stale state, and concise failure reason.
6. Scheduling uses conservative, system-aligned cadence rather than seconds-based polling semantics.
7. The app behaves correctly when the helper is unreachable, the Mac is asleep, or the device is off-LAN.
8. Configuration for `BackgroundTasks` is present in the generated app target metadata.

## Bottom line

The existing codebase is a clean scaffold for a foreground monitoring app, but it is not yet architected for production background refresh.

The central changes are:
- move from in-memory state to persisted snapshot state
- move from view-model-driven networking to a dedicated sync service
- use `BGAppRefreshTask` for lightweight summary refresh only
- add scheduling/backoff/error classification around iOS's non-deterministic background model
- optionally improve the Mac helper with summary/timestamp/revision support

That approach matches iOS constraints, reduces wasted background work, and makes the app resilient to the local-network dependency that defines this product.