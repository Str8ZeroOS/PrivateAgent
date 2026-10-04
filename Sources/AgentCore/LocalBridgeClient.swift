import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MacBridgeHealth: Sendable, Codable, Equatable {
    public var status: String
    public var service: String?
    public var startedAt: String?
    public var time: String?
    public var mode: String?

    public init(status: String, service: String? = nil, startedAt: String? = nil, time: String? = nil, mode: String? = nil) {
        self.status = status
        self.service = service
        self.startedAt = startedAt
        self.time = time
        self.mode = mode
    }
}

public struct LocalBridgeClient: MacBridgeClient {
    private let baseURL: URL
    private let token: String?
    private let urlSession: URLSession

    public init(baseURL: URL, token: String? = nil, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.urlSession = urlSession
    }

    public func health() async throws -> MacBridgeHealth {
        var request = URLRequest(url: baseURL.appending(path: "health"))
        applyAuthorization(to: &request)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw LocalBridgeClientError.invalidResponse
        }

        return try JSONDecoder().decode(MacBridgeHealth.self, from: data)
    }

    public func requestObservation(_ request: MacBridgeObservationRequest) async throws -> MacBridgeResponse {
        try await post(request, path: "observation")
    }

    public func executeAction(_ request: MacBridgeActionRequest) async throws -> MacBridgeResponse {
        try await post(request, path: "action")
    }

    private func post<Request: Encodable>(_ body: Request, path: String) async throws -> MacBridgeResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthorization(to: &request)
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw LocalBridgeClientError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MacBridgeResponse.self, from: data)
    }

    private func applyAuthorization(to request: inout URLRequest) {
        guard let token, !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}

public enum LocalBridgeClientError: Error, Sendable, Equatable {
    case invalidResponse
}
