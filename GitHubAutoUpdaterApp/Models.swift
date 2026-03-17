import Foundation

enum RepoHealth: String, Codable, CaseIterable {
    case ok
    case skipped
    case failed
    case warning
    case unknown

    var label: String {
        switch self {
        case .ok: return "Healthy"
        case .skipped: return "Skipped"
        case .failed: return "Failed"
        case .warning: return "Warning"
        case .unknown: return "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .skipped: return "pause.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

struct RepoStatus: Codable, Identifiable, Hashable {
    let id: String
    let repo: String
    let state: RepoHealth
    let summary: String
    let updatedAt: Date?
    let logPath: String?
}

struct SummaryCounts: Codable, Hashable {
    let ok: Int
    let skipped: Int
    let failed: Int

    var compactDescription: String {
        "ok \(ok) • skipped \(skipped) • failed \(failed)"
    }
}

struct LatestSummary: Codable, Hashable {
    let runStamp: String?
    let summary: String?
    let counts: SummaryCounts?
}

struct DashboardSummary: Codable, Hashable {
    let totalRepos: Int
    let healthyRepos: Int
    let attentionRepos: Int
    let failedRepos: Int
    let warningRepos: Int
    let skippedRepos: Int
    let unknownRepos: Int
    let backupsCount: Int
    let alertLogPresent: Bool
    let latestRepoUpdate: Date?

    static let placeholder = DashboardSummary(
        totalRepos: 0,
        healthyRepos: 0,
        attentionRepos: 0,
        failedRepos: 0,
        warningRepos: 0,
        skippedRepos: 0,
        unknownRepos: 0,
        backupsCount: 0,
        alertLogPresent: false,
        latestRepoUpdate: nil
    )
}

struct ManualRunProgress: Codable, Hashable {
    let totalRepos: Int
    let completedRepos: Int
    let percent: Int
    let touchedRepos: [String]
    let lastTouchedRepo: String?
    let lastTouchedAt: String?

    static let empty = ManualRunProgress(
        totalRepos: 0,
        completedRepos: 0,
        percent: 0,
        touchedRepos: [],
        lastTouchedRepo: nil,
        lastTouchedAt: nil
    )
}

struct ManualRunAction: Codable, Identifiable, Hashable {
    let id: String
    let state: String
    let requestedAt: String
    let startedAt: String?
    let finishedAt: String?
    let trigger: String
    let clientIP: String?
    let pid: Int?
    let exitCode: Int?
    let statusMessage: String
    let latestSummary: LatestSummary?
    let progress: ManualRunProgress

    var stateLabel: String {
        switch state {
        case "queued": return "Queued"
        case "running": return "Running"
        case "succeeded": return "Succeeded"
        case "failed": return "Failed"
        default: return state.capitalized
        }
    }
}

struct ManualRunState: Codable, Hashable {
    let current: ManualRunAction?
    let latest: ManualRunAction?
    let history: [ManualRunAction]
    let tokenConfigured: Bool
    let postEndpoint: String
    let authHeader: String

    static let empty = ManualRunState(
        current: nil,
        latest: nil,
        history: [],
        tokenConfigured: false,
        postEndpoint: "/run-updater",
        authHeader: "X-Updater-Token"
    )
}

struct PairingStatus: Codable, Hashable {
    let authRequired: Bool
    let authMode: String
    let helperInstanceID: String
    let pairingAvailable: Bool
    let pairingCodeLabel: String?
    let pairingCodeExpiresAt: String?
    let pairingInstructions: String
    let activeTokenCount: Int
    let recommendedTransport: String

    static let placeholder = PairingStatus(
        authRequired: false,
        authMode: "bearer-token",
        helperInstanceID: "",
        pairingAvailable: false,
        pairingCodeLabel: nil,
        pairingCodeExpiresAt: nil,
        pairingInstructions: "Start the Mac helper to load pairing information.",
        activeTokenCount: 0,
        recommendedTransport: "local-network-only"
    )
}

struct PairingExchangeResponse: Codable, Hashable {
    let authToken: String
    let tokenId: String
    let tokenPreview: String
    let issuedAt: String
    let deviceName: String
    let helperInstanceID: String
    let authMode: String
    let pairingCodeExpiresAt: String?
}

struct NotificationStatus: Codable, Hashable {
    let configured: Bool
    let channels: [String]
    let lastSentAt: String?
    let lastResult: String?
    let lastRunStamp: String?

    static let placeholder = NotificationStatus(
        configured: false,
        channels: [],
        lastSentAt: nil,
        lastResult: nil,
        lastRunStamp: nil
    )
}

struct StatusResponse: Codable {
    let cronInstalled: Bool
    let cronEntry: String
    let scriptPath: String
    let mainLog: String
    let alertLog: String
    let repoLogDir: String
    let backups: [String]
    let repos: [RepoStatus]
    let crontab: String
    let latestSummary: LatestSummary
    let manualRun: ManualRunState
    let helperTime: Date?
    let dashboard: DashboardSummary
    let pairing: PairingStatus
    let notifications: NotificationStatus

    static let placeholder = StatusResponse(
        cronInstalled: false,
        cronEntry: "",
        scriptPath: "",
        mainLog: "",
        alertLog: "",
        repoLogDir: "",
        backups: [],
        repos: [],
        crontab: "",
        latestSummary: LatestSummary(runStamp: nil, summary: nil, counts: nil),
        manualRun: .empty,
        helperTime: nil,
        dashboard: .placeholder,
        pairing: .placeholder,
        notifications: .placeholder
    )
}

struct LogResponse: Codable {
    let name: String
    let content: String
}

struct RunUpdaterResponse: Codable {
    let ok: Bool?
    let error: String?
    let manualRun: ManualRunState?
}

enum LogSource: String, CaseIterable, Identifiable {
    case main
    case alert
    case repo

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum LogSeverityFilter: String, CaseIterable, Identifiable {
    case all
    case info
    case warning
    case error
    case matched

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .info: return "Info"
        case .warning: return "Warn"
        case .error: return "Error"
        case .matched: return "Match"
        }
    }
}

struct LogLine: Identifiable, Hashable {
    let text: String
    let index: Int

    var id: Int { index }
    var normalized: String { text.lowercased() }

    var severity: LogSeverityFilter {
        let value = normalized
        if value.contains("error") || value.contains("failed") || value.contains("fatal") {
            return .error
        }
        if value.contains("warn") || value.contains("skip") || value.contains("stale") {
            return .warning
        }
        return .info
    }
}
