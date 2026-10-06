import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AgentCore

/// Scripted HTTP transport: routes by "METHOD /path" and records requests.
final class StubHTTPTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> HTTPResponse

    private let lock = NSLock()
    private var routes: [String: [Handler]] = [:]
    private var fallback: Handler?
    private(set) var requests: [URLRequest] = []

    /// Queue a handler for "GET /status". Multiple handlers for the same route
    /// are used in order; the last one repeats.
    func on(_ route: String, _ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        routes[route, default: []].append(handler)
    }

    func on(_ route: String, status: Int, json: String) {
        on(route) { _ in HTTPResponse(statusCode: status, body: Data(json.utf8)) }
    }

    func onAny(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        fallback = handler
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let handler: Handler? = {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            if var queue = routes[key], !queue.isEmpty {
                let next = queue.count > 1 ? queue.removeFirst() : queue[0]
                routes[key] = queue
                return next
            }
            return fallback
        }()
        guard let handler else {
            return HTTPResponse(statusCode: 404, body: Data(#"{"error":"not_found"}"#.utf8))
        }
        return try handler(request)
    }

    func recorded() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    func count(_ route: String) -> Int {
        recorded().filter { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" == route }.count
    }

    static func json(_ request: URLRequest) -> [String: Any] {
        guard let body = request.httpBody else { return [:] }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

let refused: StubHTTPTransport.Handler = { _ in throw URLError(.cannotConnectToHost) }
let timedOut: StubHTTPTransport.Handler = { _ in throw URLError(.timedOut) }
