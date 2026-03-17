import Foundation

enum RepoHealth: String, Codable, CaseIterable {
    case ok
    case skipped
    case failed
    case warning
    case unknown

    var label: String {
        switch self {
        case .ok: return "Green"
        case .skipped, .warning: return "Yellow"
        case .failed: return "Red"
        case .unknown: return "Gray"
        }
    }
}

struct RepoStatus: Codable, Identifiable, Hashable {
    let id: String
    let repo: String
    let state: RepoHealth
    let summary: String
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

    var tintName: String {
        switch state {
        case "queued": return "orange"
        case "running": return "blue"
        case "succeeded": return "green"
        case "failed": return "red"
        default: return "gray"
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
        manualRun: .empty
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
