import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data = Data()) {
        self.statusCode = statusCode
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    public func jsonObject() -> [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

/// Injectable HTTP layer so connection/pairing logic is unit-testable
/// with scripted responses instead of a live network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public enum HTTPTransportError: Error, Sendable, Equatable {
    case nonHTTPResponse
}

public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPTransportError.nonHTTPResponse
        }
        return HTTPResponse(statusCode: http.statusCode, body: data)
    }
}

/// Why a host could not be reached, in plain words.
public struct NetworkFailure: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case timedOut
        case connectionRefused
        case hostNotFound
        case offline
        case connectionLost
        case insecureConnectionBlocked
        case cancelled
        case other
    }

    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    public static func classify(_ error: Error) -> NetworkFailure {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return NetworkFailure(kind: .timedOut, message: "timed out")
            case .cannotConnectToHost:
                return NetworkFailure(kind: .connectionRefused, message: "connection refused (nothing listening on that port)")
            case .cannotFindHost, .dnsLookupFailed:
                return NetworkFailure(kind: .hostNotFound, message: "host not found")
            case .notConnectedToInternet:
                return NetworkFailure(kind: .offline, message: "no network route (Wi-Fi off or Local Network access denied)")
            case .networkConnectionLost:
                return NetworkFailure(kind: .connectionLost, message: "connection dropped")
            case .appTransportSecurityRequiresSecureConnection:
                return NetworkFailure(kind: .insecureConnectionBlocked, message: "plain HTTP blocked by App Transport Security")
            case .cancelled:
                return NetworkFailure(kind: .cancelled, message: "cancelled")
            default:
                return NetworkFailure(kind: .other, message: urlError.localizedDescription)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case 61, 111: // ECONNREFUSED (Darwin, Linux)
                return NetworkFailure(kind: .connectionRefused, message: "connection refused (nothing listening on that port)")
            case 60, 110: // ETIMEDOUT
                return NetworkFailure(kind: .timedOut, message: "timed out")
            case 65, 113, 51, 101: // EHOSTUNREACH / ENETUNREACH
                return NetworkFailure(kind: .offline, message: "no route to host")
            default:
                break
            }
        }
        return NetworkFailure(kind: .other, message: error.localizedDescription)
    }
}

enum HTTPJSON {
    static func request(
        _ url: URL,
        method: String = "GET",
        bearer: String? = nil,
        jsonBody: [String: Any]? = nil,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
        }
        return request
    }
}

extension URL {
    static func httpBase(host: String, port: Int) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (1...65535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = trimmed
        components.port = port
        return components.url
    }
}
