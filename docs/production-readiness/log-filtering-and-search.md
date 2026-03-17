# Log Filtering and Search Production-Readiness Plan

## Goal
Build a production-grade log browsing experience for the iOS app that supports fast filtering, search, pagination, and repo-scoped investigation without loading whole logs into memory or forcing the client to parse raw text blobs.

## Current Architecture Analysis

### Current iOS app shape
- `GitHubAutoUpdaterApp/GitHubAutoUpdaterApp.swift`
  - Creates a single `AppViewModel` and performs an initial refresh on launch.
- `GitHubAutoUpdaterApp/AppViewModel.swift`
  - Stores connection settings in `@AppStorage`.
  - Fetches `/status`, `/log/main`, `/log/alert`, and `/log/repo/{repo}`.
  - Holds raw log text in three `String` properties: `mainLogText`, `alertLogText`, `repoLogText`.
  - Maintains `selectedRepo`, but not a first-class selected log source, search query, filter state, pagination cursor, or cached result model.
- `GitHubAutoUpdaterApp/RootView.swift`
  - `LogsView` uses a menu picker plus a `TabView` of three independent text panes.
  - The selection model is inconsistent: the picker drives repo selection, while the tab bar drives which text blob is visible.
  - Search/filter actions do not exist, and the UI displays monolithic text blocks rather than structured log events.
- `GitHubAutoUpdaterApp/APIClient.swift`
  - Only supports whole-response fetches for `/status` and `/log/...` endpoints.
- `GitHubAutoUpdaterApp/Models.swift`
  - Contains `StatusResponse`, `RepoStatus`, and a minimal `LogResponse { name, content }`.
  - No models for log entries, query parameters, cursors, summaries, facets, or paged responses.

### Current Mac helper shape
- `helper/status_server.py`
  - Exposes:
    - `GET /status`
    - `GET /log/main`
    - `GET /log/alert`
    - `GET /log/repo/{repo}`
  - Reads files directly and returns the last N lines as plain text.
  - Computes repo health from the latest matching `ok:` or `skip:` line in each per-repo log.
  - Uses a simple synchronous `HTTPServer` and no query parameters.
  - Does not expose structured log entries, timestamps, severity, event kinds, repo name metadata, pagination cursors, or server-side search.

### Current log format constraints
Observed logs are semi-structured text, not JSON. Typical patterns are:
- Run boundary: `===== 2026-03-16 04:26:58 =====`
- Repo marker: `[repo] /Users/core/Documents/GitHub/ArducamBridge`
- Status lines:
  - `ok: updated successfully`
  - `skip: working tree has local changes`
  - `skip: not a git repository`
  - `skip: fetch failed (...)`
  - `skip: invalid git work tree (...)`
- Context lines:
  - `branch: main`
  - `upstream: origin/main`
  - indented git output such as `Already up to date.`

This is enough to derive structured events on the helper side without changing the underlying updater script yet.

## Production Problems To Solve
1. Whole-log text loading does not scale.
2. Search would be expensive and inaccurate if implemented only on-device against truncated text.
3. The current UI cannot express source, repo, severity, status, or time filters cleanly.
4. The client has no stable pagination model, so long logs would require repeated full fetches.
5. Repo selection is overloaded and does not represent the actual viewing mode.
6. Missing alert log files and other file errors are flattened into generic text instead of structured empty/error states.
7. There is no query contract to support future desktop/web clients.

## Target Architecture
Move log browsing to a structured query model:
- Helper parses raw log files into normalized `LogEntry` records at request time.
- iOS app requests paged slices of entries via query parameters.
- Search and filtering happen server-side by default.
- Client stores only current query state, active page, lightweight caches, and optionally the last successful page per source.
- Raw text access remains available as a fallback/debug endpoint, but the main UX should use structured entries.

## UX Plan

### Primary logs experience
Replace the current menu-plus-tab raw text view with a single query-driven Logs screen:
- Top segmented control or prominent filter chips for log source:
  - Main
  - Alert
  - Repo
- If source is `Repo`, show a repo picker/searchable repo selector.
- Search field pinned near the top using `.searchable`.
- Filter controls in a sheet or inline chips:
  - Status: All, OK, Skipped, Failed, Warning, Unknown
  - Severity: All, Info, Warning, Error
  - Time range: Last hour, 24h, 7d, Custom
  - Event kinds: run boundary, repo summary, git output, metadata
  - “Only latest run” toggle
- Result list should render structured cells instead of a single monospaced blob:
  - timestamp
  - repo name if applicable
  - state/severity badge
  - primary message
  - optional expanded details
- Provide a sticky summary row above results:
  - source
  - active repo
  - total matched entries
  - active filters count
  - newest and oldest timestamps in current query window

### Result detail behavior
- Tap an entry to expand inline or open a detail sheet showing full raw lines for that event block.
- Long git output stays collapsed by default to keep scrolling fast.
- Preserve monospaced styling for raw detail text only.

### Empty and error states
- Distinguish:
  - No matches for current query
  - Log file missing
  - Helper unavailable
  - Repo log not found
  - Query invalid
- Offer “Clear filters” for empty-result states.
- Offer “Retry” for network/helper errors.

### Pagination UX
- Default to newest-first results.
- Load first page automatically.
- Support infinite scroll or explicit “Load older results”.
- When query changes, reset to first page.
- Include an affordance for “Jump to newest”.

### Advanced UX nice-to-haves for later
- Saved filters
- Share/export current query results
- Highlighted search terms in messages/details
- Quick filter from dashboard repo health card into logs screen

## On-Device State Plan

### State model additions
Introduce a dedicated logs state instead of separate raw strings.

Recommended app state objects:
- `LogSource`: `.main`, `.alert`, `.repo(repoID: String)`
- `LogQuery`: source, search text, selected repo, state filters, severity filters, event kinds, date range, page size, sort order, latest-run-only flag
- `PagedLogResult`: entries, nextCursor, previousCursor optional, totalApproximate or totalExact, server metadata
- `LogEntryViewData`: presentation-friendly projection for SwiftUI rows

### Persistence strategy
Use lightweight persistence only for user intent, not entire result sets.
- `@AppStorage`
  - selected log source kind
  - selected repo ID/name
  - page size preference if exposed
  - latest-run-only toggle
  - last-used non-sensitive filters that should survive relaunch
- `@SceneStorage` or plain `@Published`
  - transient search text
  - current cursor/page stack
  - sheet expansion state
- In-memory cache
  - keyed by normalized `LogQuery` without cursor for first page reuse
  - optionally cache a few recent cursor pages per query

### State rules
- Query changes invalidate pagination and current entries.
- Refresh keeps the active query and refetches page one.
- Repo list refresh from `/status` should reconcile with stored selected repo.
- If the selected repo disappears, fall back to main or clear repo selection with a user-visible notice.

## Helper API Additions

### Keep existing endpoints for compatibility
Retain:
- `GET /status`
- `GET /log/main`
- `GET /log/alert`
- `GET /log/repo/{repo}`

These become compatibility/debug endpoints and should not power the main logs UX once the new API ships.

### Add new query-driven endpoints

#### 1) `GET /logs`
Primary structured search endpoint.

Query parameters:
- `source=main|alert|repo`
- `repo=<repoName>` required when `source=repo`
- `q=<search text>` optional substring search, case-insensitive by default
- `state=ok,skipped,failed,warning,unknown` optional repeated or comma-separated
- `severity=info,warning,error` optional
- `kind=run_boundary,repo_header,status,metadata,output` optional
- `from=<ISO8601>` optional inclusive lower bound
- `to=<ISO8601>` optional inclusive upper bound
- `latest_run_only=true|false`
- `limit=<1...200>` default 50, cap 200
- `cursor=<opaque>` optional
- `sort=desc|asc` default `desc`

Response shape:
```json
{
  "query": {
    "source": "repo",
    "repo": "ArducamBridge",
    "q": "timeout",
    "state": ["skipped"],
    "severity": ["error"],
    "kind": ["status"],
    "from": "2026-03-16T00:00:00Z",
    "to": null,
    "latestRunOnly": false,
    "limit": 50,
    "sort": "desc"
  },
  "entries": [
    {
      "id": "repo:ArducamBridge:2026-03-16T04:00:00Z:status:9",
      "timestamp": "2026-03-16T04:00:00Z",
      "source": "repo",
      "repo": "ArducamBridge",
      "runId": "2026-03-16T04:00:00Z",
      "kind": "status",
      "state": "skipped",
      "severity": "error",
      "message": "invalid git work tree",
      "detail": "fatal: Unable to read current working directory: Operation not permitted",
      "rawLines": [
        "===== 2026-03-16 04:00:00 =====",
        "[repo] /Users/core/Documents/GitHub/ArducamBridge",
        "  skip: invalid git work tree (fatal: Unable to read current working directory: Operation not permitted)"
      ]
    }
  ],
  "page": {
    "nextCursor": "opaque-token",
    "hasMore": true,
    "returned": 50
  },
  "summary": {
    "totalMatched": 312,
    "byState": {"ok": 120, "skipped": 180, "failed": 0, "warning": 12, "unknown": 0},
    "bySeverity": {"info": 120, "warning": 12, "error": 180},
    "newestTimestamp": "2026-03-16T18:00:00Z",
    "oldestTimestamp": "2026-03-10T02:00:00Z"
  }
}
```

#### 2) `GET /logs/facets`
Returns available filter values for the current scope.
- Useful for repo lists, counts by state, and time bounds without loading entries.
- Accept the same scope parameters: `source`, `repo`, `from`, `to`, `latest_run_only`.

Suggested response:
- available repos
- counts by state/severity/kind
- min/max timestamp
- whether alert log exists

#### 3) `GET /logs/raw`
Raw fallback endpoint for a selected source/query.
- Query params: `source`, `repo`, `cursor`, `limitLines`
- This supports debugging/export and preserves current plain text access in a structured way.

### Status payload extensions
Extend `/status` so the client can build the logs UI quickly:
- `logCapabilities`
  - `structuredQuery: true`
  - `rawFallback: true`
  - supported filters and limits
- `repoLogStats`
  - repo name
  - last event timestamp
  - approx entry count or file size
  - latest state
- `mainLogStats` / `alertLogStats`
  - existence
  - last modified
  - size bytes

## Pagination, Search, and Filter Semantics

### Pagination semantics
- Cursor-based pagination, not page number.
- Sort newest-first by default.
- Cursor should encode enough information to resume from the last returned entry safely, ideally `(timestamp, file offset or line index, source, repo)`.
- Cursor must be opaque to clients.
- If the underlying file changes between requests:
  - best effort continuation is acceptable
  - response should include a `snapshotToken` or `generatedAt` so the client can detect drift
- Page size defaults to 50; allow 25/50/100/200 tiers.

### Search semantics
- Case-insensitive substring match initially.
- Search should apply to:
  - `message`
  - `detail`
  - raw lines within an event block
  - repo name when source is main and entries embed repo markers
- Escape hatch for future regex support, but do not expose regex in v1.
- Return matched entries only; optional later enhancement for snippet highlighting.

### Filter semantics
State mapping rules should be deterministic and helper-owned.

Proposed normalization:
- `ok:` -> `state=ok`, `severity=info`, `kind=status`
- `skip: working tree has local changes` -> `state=skipped`, `severity=warning`
- `skip: not a git repository` -> `state=warning`, `severity=warning`
- `skip: invalid git work tree (...)` -> `state=failed` or `warning` depending on desired product policy
- `skip: fetch failed (...)` -> `state=failed`, `severity=error`
- unknown `skip:` reasons -> `state=warning`, `severity=warning` unless the pattern clearly indicates failure

Recommended product rule:
- Separate “workflow skip” from “real failure”.
- Use:
  - `skipped` for benign intentional skips like local changes
  - `warning` for environment/config anomalies like not a git repository
  - `failed` for command timeouts, fetch failures, corrupted metadata, permission errors

This is more actionable than the current `latest_repo_status()` heuristic.

### Event modeling semantics
Each run block should produce multiple entries if useful, but keep the top-level browsing list concise.

Recommended v1 behavior:
- Emit one `run_boundary` entry per timestamp block.
- Emit one `status` entry per repo result.
- Attach `branch`, `upstream`, and indented output as metadata/detail on the status entry instead of separate rows unless requested by `kind=metadata,output`.

This yields a compact default list while preserving drill-down detail.

## Helper Implementation Plan

### Phase 1: Parsing and normalization layer
Modify `helper/status_server.py` to factor out log parsing into pure functions.

Add internal concepts:
- `LogSource`
- `ParsedRun`
- `ParsedLogEntry`
- normalization helpers for state/severity/kind
- query parser and validator
- cursor encoder/decoder

Recommended internal steps:
1. Create parser functions for main log and per-repo logs.
2. Parse runs by timestamp boundary line.
3. Associate repo marker + following status/detail lines into event blocks.
4. Normalize each block into a structured entry dictionary.
5. Apply filter/search predicates in memory.
6. Slice by cursor and limit.

### Phase 2: Structured API surface
In `helper/status_server.py`:
- add request routing for `/logs`, `/logs/facets`, `/logs/raw`
- add validation error responses with 400 status
- add `generatedAt` and optional `snapshotToken`
- return JSON error payloads consistently

### Phase 3: Performance and resiliency hardening
Still within `helper/status_server.py` initially:
- add small parse cache keyed by file path + mtime + query-independent normalized entries
- avoid reparsing unchanged log files on every request
- guard maximum returned bytes/entries
- cap `q` length, `limit`, and total raw lines returned
- handle missing files as structured empty sources, not generic server failures
- consider switching from `HTTPServer` to `ThreadingHTTPServer` for responsiveness when parsing larger logs

## iOS App Implementation Plan

### Phase 1: Models and API client
Modify `GitHubAutoUpdaterApp/Models.swift`:
- add `LogSourceKind`
- add `LogQuery`
- add `LogEntry`
- add `PagedLogResponse`
- add `LogFacetsResponse`
- add `LogSummary`

Modify `GitHubAutoUpdaterApp/APIClient.swift`:
- add `fetchLogs(baseURL:query:)`
- add `fetchLogFacets(baseURL:scope:)`
- keep existing raw log methods for compatibility/fallback
- build URLs with query items rather than path-only composition

### Phase 2: Dedicated logs state in view model
Modify `GitHubAutoUpdaterApp/AppViewModel.swift`:
- replace raw `mainLogText`, `alertLogText`, `repoLogText` as primary browsing state
- add `logQuery`, `logEntries`, `logSummary`, `logNextCursor`, `isLoadingLogs`, `isLoadingMoreLogs`, `logsError`
- add methods:
  - `refreshStatus()`
  - `refreshLogs(reset: Bool = true)`
  - `loadMoreLogs()`
  - `updateLogSource(...)`
  - `updateLogFilters(...)`
  - `clearLogFilters()`
- keep a raw-log fallback fetch for entry detail/export only

### Phase 3: Logs UI redesign
Modify `GitHubAutoUpdaterApp/RootView.swift`.

Strong recommendation: split `LogsView` into dedicated view files even if the project is small.
Suggested new files:
- `GitHubAutoUpdaterApp/LogsView.swift`
- `GitHubAutoUpdaterApp/LogFilterSheet.swift`
- `GitHubAutoUpdaterApp/LogEntryRow.swift`
- `GitHubAutoUpdaterApp/LogEntryDetailView.swift`

UI responsibilities:
- `LogsView.swift`
  - query controls, summary header, result list, pagination trigger
- `LogFilterSheet.swift`
  - state/severity/kind/date filters
- `LogEntryRow.swift`
  - compact rendering with badges and timestamp
- `LogEntryDetailView.swift`
  - raw detail lines and metadata

If file churn must be minimized, these can stay inside `RootView.swift` initially, but that is not recommended for production readiness.

### Phase 4: Dashboard integration
Modify `GitHubAutoUpdaterApp/RootView.swift` dashboard area so tapping a repo can optionally deep-link into Logs with prefilled source `repo` and filters matching that repo’s latest state. This improves operational workflow.

## Exact File/Area Change List

### Existing files to modify
- `helper/status_server.py`
  - add parsing, filtering, pagination, new routes, better error handling, optional caching
- `GitHubAutoUpdaterApp/Models.swift`
  - add structured log request/response models
- `GitHubAutoUpdaterApp/APIClient.swift`
  - add query-item based log APIs
- `GitHubAutoUpdaterApp/AppViewModel.swift`
  - add query-driven log state and actions
- `GitHubAutoUpdaterApp/RootView.swift`
  - replace current raw text logs UX, optionally trim dashboard-to-log handoff
- `README.md`
  - document new helper endpoints and query model

### Likely new iOS source files
- `GitHubAutoUpdaterApp/LogsView.swift`
- `GitHubAutoUpdaterApp/LogFilterSheet.swift`
- `GitHubAutoUpdaterApp/LogEntryRow.swift`
- `GitHubAutoUpdaterApp/LogEntryDetailView.swift`

### Project configuration touchpoints
- `project.yml`
  - only if explicit source grouping or build settings need adjustment; XcodeGen should already include new Swift files under `GitHubAutoUpdaterApp`

## API Contract Recommendations

### Error response contract
Use a consistent shape:
```json
{
  "error": {
    "code": "invalid_query",
    "message": "repo is required when source=repo",
    "details": {"field": "repo"}
  }
}
```

Suggested codes:
- `invalid_query`
- `missing_log`
- `repo_not_found`
- `unsupported_source`
- `cursor_invalid`
- `internal_error`

### Backward compatibility
- Keep old `/log/...` endpoints during rollout.
- iOS app should prefer `/logs` when `status.logCapabilities.structuredQuery == true`.
- If not supported, fall back to current raw endpoint behavior.

## Testing and Verification Plan

### Helper tests
This repo currently has no visible test target, so add Python tests if a test harness is introduced later. At minimum, plan for:
- parse run boundary correctly
- parse repo status blocks correctly
- normalize status/severity mapping correctly
- search matches message/detail/raw lines case-insensitively
- cursor pagination is stable across multiple pages
- missing alert log returns empty-but-valid results
- invalid query returns 400 with structured error

### iOS verification cases
- initial load shows newest entries for Main
- switching to Alert shows empty state when file missing
- switching to Repo requires/selects repo and refreshes correctly
- entering search text resets cursor and updates summary counts
- applying filters updates chips and result list
- loading more appends older entries without duplication
- refreshing while filters are active preserves query
- dashboard repo tap deep-links to repo-scoped logs correctly

## Rollout Order
1. Add structured parsing and `/logs` on helper.
2. Extend `/status` with log capability metadata.
3. Add iOS models and API client methods.
4. Refactor `AppViewModel` to query-driven log state.
5. Replace Logs UI.
6. Add dashboard-to-logs deep-linking.
7. Update README and operator docs.
8. Keep raw endpoints until the new UI is stable.

## Key Product Decisions To Lock Before Implementation
1. Whether command timeouts and permission errors map to `failed` or `warning`.
2. Whether `/logs` returns exact counts or approximate counts for large scans.
3. Whether date filters are based on parsed run timestamps only or per-line timestamps if introduced later.
4. Whether repo names are canonicalized from filenames, path basenames, or `/status` repo IDs.
5. Whether raw lines are always included in `entries` or loaded lazily in a detail endpoint.

## Recommended Default Decisions
- Map timeouts, fetch failures, corrupt metadata, and permission errors to `failed`.
- Return exact counts for current log sizes; switch to approximate only if performance becomes an issue.
- Use run timestamp as the event timestamp in v1.
- Canonicalize repo identity from the per-repo log filename stem and return both `id` and display `repo` if needed later.
- Include a compact `detail` string in list results and full `rawLines` only in expanded/detail contexts if payload size becomes a concern.

## Definition of Done
This work is production-ready when:
- The helper exposes structured log querying with validated filters and cursor pagination.
- The iOS app can browse logs without loading entire files into memory.
- Search/filter state is explicit, persistent where appropriate, and resilient across refreshes.
- Missing logs and empty results have distinct UX.
- Existing raw endpoints still work during migration.
- The architecture can support larger logs and future clients without redesign.
