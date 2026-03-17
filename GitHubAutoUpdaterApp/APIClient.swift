import Foundation

struct APIClient {
    func fetchStatus(baseURL: String) async throws -> StatusResponse {
        let url = try makeURL(baseURL: baseURL, path: "/status")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(StatusResponse.self, from: data)
    }

    func fetchLog(baseURL: String, kind: String, repo: String? = nil) async throws -> LogResponse {
        var path = "/log/\(kind)"
        if let repo, !repo.isEmpty {
            let encoded = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo
            path += "/\(encoded)"
        }
        let url = try makeURL(baseURL: baseURL, path: path)
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(LogResponse.self, from: data)
    }

    private func makeURL(baseURL: String, path: String) throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw URLError(.badURL)
        }
        components.path = path
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }
}
