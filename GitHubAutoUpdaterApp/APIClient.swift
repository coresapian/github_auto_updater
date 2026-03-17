import Foundation

struct APIClient {
    func fetchStatus(baseURL: String) async throws -> StatusResponse {
        let url = try makeURL(baseURL: baseURL, path: "/status")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(StatusResponse.self, from: data)
    }

    func fetchLog(baseURL: String, kind: String, repo: String? = nil) async throws -> LogResponse {
        var path = "/log/\(kind)"
        if let repo, !repo.isEmpty {
            let encoded = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo
            path += "/\(encoded)"
        }
        let url = try makeURL(baseURL: baseURL, path: path)
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(LogResponse.self, from: data)
    }

    func runUpdater(baseURL: String, token: String) async throws -> RunUpdaterResponse {
        let url = try makeURL(baseURL: baseURL, path: "/run-updater")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Updater-Token")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["requestedBy": "ios-app"], options: [])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(RunUpdaterResponse.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(RunUpdaterResponse.self, from: data), let message = apiError.error, !message.isEmpty {
                throw APIClientError.server(message)
            }
            throw APIClientError.server(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))
        }
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

enum APIClientError: LocalizedError {
    case server(String)

    var errorDescription: String? {
        switch self {
        case .server(let message):
            return message
        }
    }
}
