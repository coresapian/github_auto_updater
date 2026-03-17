import Foundation

struct APIClient {
    func fetchStatus(baseURL: String, authToken: String? = nil) async throws -> StatusResponse {
        let url = try makeURL(baseURL: baseURL, path: "/status")
        var request = URLRequest(url: url)
        applyAuth(authToken, to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(StatusResponse.self, from: data)
    }

    func fetchPairingStatus(baseURL: String) async throws -> PairingStatus {
        let url = try makeURL(baseURL: baseURL, path: "/pairing/status")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try decoder.decode(PairingStatus.self, from: data)
    }

    func exchangePairingCode(baseURL: String, pairingCode: String, deviceName: String) async throws -> PairingExchangeResponse {
        let url = try makeURL(baseURL: baseURL, path: "/pairing/exchange")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["pairingCode": pairingCode, "deviceName": deviceName])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(PairingExchangeResponse.self, from: data)
    }

    func registerDevice(baseURL: String, authToken: String, deviceToken: String, deviceName: String) async throws -> DeviceRegistrationResponse {
        let url = try makeURL(baseURL: baseURL, path: "/devices/register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(authToken, to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "deviceToken": deviceToken,
            "deviceName": deviceName,
            "platform": "ios"
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(DeviceRegistrationResponse.self, from: data)
    }

    func fetchLog(baseURL: String, kind: String, repo: String? = nil, authToken: String? = nil) async throws -> LogResponse {
        var path = "/log/\(kind)"
        if let repo, !repo.isEmpty {
            let encoded = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo
            path += "/\(encoded)"
        }
        let url = try makeURL(baseURL: baseURL, path: path)
        var request = URLRequest(url: url)
        applyAuth(authToken, to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(LogResponse.self, from: data)
    }

    func runUpdater(baseURL: String, token: String) async throws -> RunUpdaterResponse {
        let url = try makeURL(baseURL: baseURL, path: "/run-updater")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(token, to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["requestedBy": "ios-app"])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(RunUpdaterResponse.self, from: data)
    }

    private func applyAuth(_ authToken: String?, to request: inout URLRequest) {
        let trimmed = authToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue(trimmed, forHTTPHeaderField: "X-Updater-Token")
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = payload["error"] as? String {
                throw APIClientError.server(error)
            }
            throw APIClientError.server(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))
        }
    }

    private func makeURL(baseURL: String, path: String) throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw URLError(.badURL)
        }
        components.path = path
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }
}

enum APIClientError: LocalizedError {
    case server(String)
    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        }
    }
}
