import Foundation

public struct LocalBridgeClient: MacBridgeClient {
    private let baseURL: URL
    private let urlSession: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseURL: URL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func requestObservation(_ request: MacBridgeObservationRequest) async throws -> MacBridgeResponse {
        try await post(request, path: "observation")
    }

    public func executeAction(_ request: MacBridgeActionRequest) async throws -> MacBridgeResponse {
        try await post(request, path: "action")
    }

    private func post<Request: Encodable>(_ body: Request, path: String) async throws -> MacBridgeResponse {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw LocalBridgeClientError.invalidResponse
        }

        return try decoder.decode(MacBridgeResponse.self, from: data)
    }
}

public enum LocalBridgeClientError: Error, Sendable, Equatable {
    case invalidResponse
}
