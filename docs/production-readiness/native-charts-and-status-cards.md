# Native Charts and Status Cards Implementation Plan

> For Hermes: this is a planning document only. Do not modify application code while using this plan.

## Goal

Upgrade the current iOS dashboard from a basic `List` of strings into a production-grade native SwiftUI dashboard with status cards and Apple Charts-powered visualizations, while extending the Mac helper so it can provide trustworthy, structured, chart-ready operational metrics.

## Current Architecture Analysis

### iOS app today

Codebase summary:
- `GitHubAutoUpdaterApp/GitHubAutoUpdaterApp.swift`
  - Creates a single `@StateObject` `AppViewModel`
  - Injects it into the environment
  - Triggers an initial refresh on launch
- `GitHubAutoUpdaterApp/RootView.swift`
  - Holds all three main screens in one file: `DashboardView`, `LogsView`, `SettingsView`
  - Uses `TabView` with `NavigationStack` inside each tab
  - Dashboard is a `List` with three sections: updater info, repositories, backups
- `GitHubAutoUpdaterApp/AppViewModel.swift`
  - Single source of truth for app state
  - Fetches `/status`, `/log/main`, `/log/alert`, and selected repo log
  - Stores raw response plus log text and selection state
- `GitHubAutoUpdaterApp/Models.swift`
  - Defines a small API contract: `StatusResponse`, `RepoStatus`, `LogResponse`, `RepoHealth`
- `GitHubAutoUpdaterApp/APIClient.swift`
  - Thin HTTP client around the helper server

Current iOS strengths:
- Cleanly separated network/model/view-model layers for a small app
- Single observable model keeps the UI simple
- Existing repo health enum is a good starting point for color and status mapping
- iOS 17 deployment target means Swift Charts and newer SwiftUI layout APIs are available

Current iOS limitations relevant to charts/cards:
- `DashboardView` is list-driven and text-heavy, not card-driven
- All views live in `RootView.swift`, so UI concerns are overly coupled
- The data model is a point-in-time snapshot only; there is no historical series for charts
- No explicit presentation models for KPI cards or chart series
- No visible loading skeletons, freshness metadata, or “last updated” indicators
- Status is encoded mostly as text and colored dots; there is limited semantic/accessibility support

### Mac helper today

Codebase summary:
- `helper/status_server.py`
  - Uses Python stdlib `HTTPServer`
  - Exposes read-only endpoints:
    - `GET /status`
    - `GET /log/main`
    - `GET /log/alert`
    - `GET /log/repo/<name>`
  - Reads current log files and crontab state directly from disk/shell commands
  - Infers per-repo state by scanning recent repo log lines for `ok:` or `skip:` markers

Current helper strengths:
- Minimal operational surface area
- Easy to run locally and reason about
- Already acts as the trust boundary between iOS and Mac-only resources

Current helper limitations relevant to charts/cards:
- `/status` exposes only a snapshot, not historical samples
- Per-repo data is only `{ id, repo, state, summary }`
- No timestamps for last success, last failure, last run, or state transitions
- No aggregate metrics like repo counts by health, stale repo count, or alert count
- Helper reads plain text logs on demand; this is fine for logs, but not ideal for repeated chart aggregation
- The current contract cannot support line charts, bar charts, trend deltas, or freshness indicators without additional fields or a new endpoint

## Product Direction

Keep the overall product shape:
- iOS app remains the read-only monitoring client
- Mac helper remains the local source of truth and the only component that touches cron/log files

But evolve the architecture in a production-friendly way:
- The helper should produce structured dashboard metrics, not just raw text and snapshot strings
- The iOS app should consume those metrics into a dedicated dashboard presentation layer
- The dashboard should move from a `List` to adaptive card-based layout with native charts
- Logs and Settings remain secondary tabs; Dashboard becomes the primary operational surface

## Target Architecture

### Recommended API shape

Do not force the dashboard to derive analytics from raw logs on-device.

Instead, add one new helper endpoint for chart-ready data:
- `GET /dashboard`

Recommended response sections:
- `generatedAt`: ISO-8601 timestamp for helper-side payload generation
- `updater`: cron/install/script status, last run, next scheduled run, data freshness
- `summary`: repo counts by health, repos needing attention, backups count, alert count
- `runHistory`: time-bucketed samples for the last 24h and 7d
- `repos`: enriched per-repo dashboard models with timestamps and counters
- `alerts`: notable issues for banner/status-card presentation

Keep existing endpoints for backward compatibility:
- `/status`
- `/log/main`
- `/log/alert`
- `/log/repo/<name>`

### Recommended helper-side data strategy

For production-grade charts, the helper should not re-parse only the last few log lines every time a chart is requested.

Recommended approach:
1. Introduce a structured metrics history file on the Mac, for example:
   - `~/.local/var/log/github-auto-update/dashboard-history.jsonl`
2. Each updater run appends a normalized event/snapshot with timestamped outcomes
3. The helper reads recent structured history, applies retention, and returns chart series
4. Raw log endpoints remain available for diagnostics

If changing the updater script is out of scope initially, use a staged migration:
- Phase 1: helper derives best-effort history by parsing existing text logs
- Phase 2: updater script emits structured events directly
- Phase 3: helper prefers structured history and falls back to log parsing only when needed

This keeps the iOS UI native and clean without making it responsible for operational parsing logic.

## SwiftUI Information Architecture

### Tabs

Retain the current top-level tab structure:
- Dashboard
- Logs
- Settings

This is already the right information architecture for the product.

### Dashboard IA

Rebuild Dashboard as a vertical, card-first experience:

1. Global status section
2. Fleet health metrics section
3. Run history section
4. Repo attention section
5. Selected repo detail section
6. Operational details section

### Screen behavior by size class

On iPhone:
- Single-column scrollable dashboard
- Full-width cards
- Charts use shorter aspect ratios and simplified legends

On iPad:
- Two-column adaptive layout using `LazyVGrid` or `AnyLayout`
- Hero card spans full width
- Summary cards appear in a metrics row/grid
- Trend and repo detail charts can sit side by side

### Dashboard navigation model

Keep Dashboard lightweight and glanceable.

Interaction pattern:
- Tap a repo card to select it and update the detail card/chart below
- Keep Logs tab as the deep-dive destination for raw operational text
- Do not introduce modal-heavy chart drilldowns in v1 unless the repo count becomes large

## Card Hierarchy

### 1. Hero status card

Purpose:
- Give a single answer to “Is the updater healthy right now?”

Contents:
- Overall status title: Healthy / Attention Needed / Degraded / Offline
- Helper freshness: “Updated 18s ago”
- Cron installed status
- Last successful updater run
- Next scheduled run estimate
- Primary CTA: Refresh

Visual treatment:
- Large title + status icon
- Supporting metric chips underneath
- Use semantic colors plus symbols, not color alone

### 2. KPI summary cards

A compact row/grid of small cards showing:
- Total repos monitored
- Healthy repos
- Warning/skipped repos
- Failed repos
- Repos stale for more than threshold
- Backups found

These should be the fastest scanning surface after the hero card.

### 3. Fleet health distribution card

Purpose:
- Show current repo distribution by health bucket

Recommended chart:
- `SectorMark` donut chart on iOS 17+ for health distribution
- Fallback: stacked horizontal bar if label density or accessibility becomes difficult

Buckets:
- Healthy
- Skipped/local changes
- Warning
- Failed
- Unknown

Why this works:
- The current repo model already has discrete health states
- This is the most natural first chart from the existing architecture

### 4. Run history card

Purpose:
- Show whether the updater is running on schedule and whether outcomes are trending better or worse

Recommended chart:
- Line chart or area chart over time
- Prefer multiple series only if the legend remains readable

Primary metrics to visualize:
- Successful runs per time bucket
- Failed/skipped runs per time bucket
- Optional average run duration once the helper can provide it

Time ranges:
- 24 hours
- 7 days

If only one chart is included in v1, this and the fleet distribution chart should be the first two.

### 5. Attention-required card

Purpose:
- Surface the repos or system conditions that require action now

Contents:
- Failed repos sorted by most recent failure first
- Stale repos sorted by oldest successful update first
- Cron missing / helper unreachable / missing script conditions
- Recent alert count or recent alert headline

Presentation:
- Prefer list-style alert rows inside a card rather than a chart
- Each row should have icon, repo name, issue reason, and recency

### 6. Selected repo detail card

Purpose:
- Provide one layer of drill-down without leaving Dashboard

Contents:
- Repo name
- Current health state and summary
- Last success time
- Last failure time, if any
- Last log event time
- Mini sparkline of recent outcomes, if available
- Open Logs hint: “See Logs tab for raw output”

Recommended chart:
- Small bar or line chart representing recent per-run outcomes for the selected repo

### 7. Operational details card

Purpose:
- Preserve advanced system information without making the dashboard feel like a debug screen

Contents:
- Cron entry
- Script path
- Repo log directory
- Backup root / count
- Maybe current server URL for support scenarios

Presentation:
- Secondary/tertiary card at the bottom of the dashboard
- On iPhone, collapse behind a disclosure group if it gets long

## Metrics to Visualize

### Metrics the current helper can support with minimal enrichment

These can be derived from the existing snapshot model plus log parsing:
- Repo counts by `RepoHealth`
- Total monitored repos
- Backups count
- Current cron installed state
- Current repo summaries

### Metrics that should be added for production readiness

Add these to helper output so the iOS dashboard can become truly operational:
- `generatedAt`
- `lastRefreshDurationMs` or helper request timing if useful
- `lastUpdaterRunAt`
- `lastSuccessfulRunAt`
- `nextScheduledRunAt`
- `dataAgeSeconds`
- `repoHealthCounts`
- `staleRepoCount`
- `alertCount24h`
- `backupCount`
- `latestBackupAt` if meaningful

Per repo, add:
- `lastEventAt`
- `lastSuccessAt`
- `lastFailureAt`
- `failureCount24h`
- `skipCount24h`
- `successCount24h`
- `isStale`
- `staleDurationHours`
- `recentOutcomes` or `history` sample array

For chart series, add:
- `bucketStart`
- `successCount`
- `failureCount`
- `skipCount`
- optional `avgDurationSeconds`

## Recommended Chart Types

### Use these in v1

1. Health distribution donut
- Best for current categorical repo health
- Easy executive summary card

2. Run history line/area chart
- Best for schedule confidence and trend visualization
- Helps answer “Is the updater keeping up?”

3. Repo-level mini sparkline or bar strip
- Best inside the selected repo detail card
- Shows recent reliability without overwhelming the screen

### Use these in v2 if metrics mature

4. Horizontal bar chart for “oldest successful update age by repo”
- Best for ranking stale/problem repos
- Useful when monitoring many repos

5. Stacked bar chart for daily success/failure/skip mix
- Good alternative to multiple overlapping lines
- Easier to read if buckets are daily rather than hourly

### Avoid in v1

- Pie charts without center labels or counts
- Complex multi-axis charts
- Heat maps unless you first create a stronger history model and custom accessibility support
- Chart overload; two primary charts plus one mini repo chart is enough

## Accessibility Requirements

Accessibility should be a first-class requirement, not a polish pass.

### Visual accessibility

- Never rely on color alone; every status uses icon + text + color
- Meet contrast requirements in light and dark mode
- Use semantic colors that map to system accessibility behavior where possible
- Keep card background separations visible under increased contrast settings

### Dynamic Type

- All status cards must reflow cleanly at large content sizes
- Small KPI cards should wrap values instead of truncating critical metrics
- Charts should move legends below or into summary text when text becomes large

### VoiceOver

For every card:
- Provide a concise summary label
- Provide a detailed value string
- Ensure decorative chart elements are either hidden or described through a chart descriptor

For charts specifically:
- Add `accessibilityLabel`, `accessibilityValue`, and chart summaries
- Provide non-visual summary text below the chart, for example:
  - “18 healthy repos, 2 skipped, 1 failed”
  - “Updater completed 46 successful runs and 3 failures in the last 7 days”

### Motion and interaction

- Keep chart animations subtle and short
- Respect Reduce Motion where practical
- Maintain minimum 44x44 tap targets on repo cards and controls
- Ensure card tap areas are clearly bounded and predictable

### Color semantics

Suggested status mapping:
- Healthy: green + checkmark.circle.fill
- Warning/skipped: yellow/orange + exclamationmark.triangle.fill or pause.circle.fill
- Failed: red + xmark.octagon.fill
- Unknown: gray + questionmark.circle.fill

## Code and File Changes

### Existing files to modify

1. `GitHubAutoUpdaterApp/Models.swift`
- Expand dashboard API models
- Add chart series models and enriched repo dashboard models
- Separate transport models from presentation helpers if the file becomes large

2. `GitHubAutoUpdaterApp/APIClient.swift`
- Add `fetchDashboard(baseURL:)`
- Keep existing status/log methods for compatibility
- Consider centralizing date decoding if helper returns ISO timestamps

3. `GitHubAutoUpdaterApp/AppViewModel.swift`
- Add dashboard-specific state and selection models
- Track freshness / last loaded timestamp / loading phases
- Transform API payload into card-ready presentation data
- Avoid making the SwiftUI view compute chart series directly

4. `GitHubAutoUpdaterApp/RootView.swift`
- Remove the current monolithic dashboard implementation from this file
- Keep root navigation only
- Point Dashboard tab at a dedicated screen file

5. `helper/status_server.py`
- Add structured dashboard endpoint and richer payload generation
- Add timestamp normalization and aggregate counters
- Potentially offload parsing/aggregation helpers into separate helper modules

6. `project.yml`
- No extra package is required for Apple Charts because it is a system framework
- Update only if you decide to add unit/UI test targets or reorganize groups explicitly

### New iOS files to add

Recommended new file structure:

- `GitHubAutoUpdaterApp/Screens/DashboardScreen.swift`
  - Main dashboard composition
- `GitHubAutoUpdaterApp/Dashboard/HeroStatusCard.swift`
- `GitHubAutoUpdaterApp/Dashboard/KPISummaryGrid.swift`
- `GitHubAutoUpdaterApp/Dashboard/FleetHealthChartCard.swift`
- `GitHubAutoUpdaterApp/Dashboard/RunHistoryChartCard.swift`
- `GitHubAutoUpdaterApp/Dashboard/AttentionRequiredCard.swift`
- `GitHubAutoUpdaterApp/Dashboard/SelectedRepoDetailCard.swift`
- `GitHubAutoUpdaterApp/Dashboard/OperationalDetailsCard.swift`
- `GitHubAutoUpdaterApp/Dashboard/RepoHealthStyle.swift`
  - Central place for label/icon/color mappings
- `GitHubAutoUpdaterApp/Dashboard/DashboardFormatting.swift`
  - Relative date formatting, count formatting, etc.

If you want clearer separation of concerns, also add:
- `GitHubAutoUpdaterApp/ViewModels/DashboardPresentationModel.swift`
  - Chart series and card view data, already normalized for the UI

### New helper files to add

Recommended helper-side decomposition:

- `helper/dashboard_models.py`
  - Typed payload-building helpers or dataclasses
- `helper/history_store.py`
  - Reads/writes structured metrics history
- `helper/log_parser.py`
  - Parses existing logs into normalized events during migration

This will keep `status_server.py` from becoming the single dumping ground for HTTP, parsing, aggregation, and serialization.

### Recommended tests to add

iOS tests:
- `GitHubAutoUpdaterAppTests/DashboardDecodingTests.swift`
- `GitHubAutoUpdaterAppTests/DashboardPresentationTests.swift`
- `GitHubAutoUpdaterAppUITests/DashboardAccessibilityTests.swift`

Helper tests:
- `helper/tests/test_log_parser.py`
- `helper/tests/test_history_store.py`
- `helper/tests/test_dashboard_payload.py`

## Proposed Data Model Additions

Suggested transport models on the iOS side:

```swift
struct DashboardResponse: Decodable {
    let generatedAt: Date
    let updater: UpdaterStatus
    let summary: FleetSummary
    let runHistory: [RunHistoryPoint]
    let repos: [RepoDashboardStatus]
    let alerts: [DashboardAlert]
}
```

Suggested supporting concepts:
- `UpdaterStatus`
- `FleetSummary`
- `RunHistoryPoint`
- `RepoDashboardStatus`
- `RepoOutcomePoint`
- `DashboardAlert`

Important design rule:
- The transport layer should match helper JSON
- The presentation layer should convert transport models into card-ready data structures
- Avoid embedding formatting logic throughout the SwiftUI views

## Dashboard Layout Recommendation

### iPhone layout order

1. Hero status card
2. KPI summary grid (2 columns)
3. Fleet health donut card
4. Run history card
5. Attention-required card
6. Selected repo detail card
7. Operational details card

### iPad layout order

Row 1:
- Hero status card spanning full width

Row 2:
- KPI summary grid spanning full width

Row 3:
- Fleet health chart
- Run history chart

Row 4:
- Attention-required card
- Selected repo detail card

Row 5:
- Operational details card spanning full width

## Implementation Phases

### Phase 0: Contract design

Deliverables:
- Define the new helper JSON contract for `/dashboard`
- Decide timestamp formats, bucket granularity, stale threshold, retention length
- Document fallback behavior when history is unavailable

### Phase 1: Helper enrichment

Deliverables:
- Add structured dashboard endpoint
- Introduce helper-side aggregation and history retention
- Preserve existing `/status` and log endpoints

Acceptance criteria:
- Helper can answer chart-oriented requests without the iOS app parsing raw logs
- Payload includes timestamps, counts, and time buckets

### Phase 2: iOS model and view-model refactor

Deliverables:
- Add `DashboardResponse` and presentation models
- Extend `APIClient` and `AppViewModel`
- Introduce card-focused dashboard state management

Acceptance criteria:
- Dashboard data is loaded and normalized before rendering
- Existing Logs and Settings behavior remains intact

### Phase 3: Native card UI

Deliverables:
- Replace dashboard `List` with a card-based scroll view
- Add hero card, KPI summary cards, attention card, operational details card
- Preserve repo selection behavior

Acceptance criteria:
- Dashboard remains fast and readable on iPhone and iPad
- No card depends on raw string parsing in the view layer

### Phase 4: Native charts

Deliverables:
- Add fleet health donut chart
- Add run history line/area or stacked-bar chart
- Add selected repo mini trend chart

Acceptance criteria:
- Charts render correctly with empty, sparse, and dense data
- Every chart has an accessible textual summary

### Phase 5: Accessibility and resilience hardening

Deliverables:
- VoiceOver labels and chart summaries
- Large Dynamic Type verification
- Error, loading, empty, and stale-data states
- Helper offline state card/banner

Acceptance criteria:
- Dashboard remains understandable with VoiceOver alone
- Offline or stale helper states are obvious and non-destructive

## Edge Cases to Handle Explicitly

- Helper reachable but returns empty history
- Helper reachable but logs are missing
- Cron not installed
- Script path missing
- Zero repos monitored
- All repos unknown
- Very large repo counts causing legend/card overflow
- Selected repo disappears after refresh
- Device offline / helper unreachable / timeout
- Timestamps missing or malformed

## Design Constraints and Non-Goals

Keep these constraints from the existing architecture:
- iOS remains read-only with respect to cron and Finder operations
- Raw logs stay available in the Logs tab
- Settings remains the place for helper URL and refresh controls

Non-goals for this feature:
- Editing cron from iOS
- Executing updater runs remotely from iOS unless explicitly requested later
- Replacing the helper with a database-backed service
- Building a custom charting engine when Swift Charts already covers the need

## Summary Recommendation

The correct production move is not just “add charts to the current list.”

Instead:
- Keep the three-tab app structure
- Refactor Dashboard into a card-based SwiftUI screen
- Add a helper-side `/dashboard` contract with structured, timestamped metrics
- Start with three visualizations:
  - repo health distribution donut
  - run history trend chart
  - selected repo mini trend chart
- Back the visuals with strong accessibility summaries and clear status semantics
- Split the current monolithic `RootView.swift` into focused screen/card files

That path keeps the app native, scalable, accessible, and maintainable while respecting the current separation between the iOS client and the Mac-side operational helper.
