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

    static let placeholder = StatusResponse(
        cronInstalled: false,
        cronEntry: "",
        scriptPath: "",
        mainLog: "",
        alertLog: "",
        repoLogDir: "",
        backups: [],
        repos: [],
        crontab: ""
    )
}

struct LogResponse: Codable {
    let name: String
    let content: String
}
