import Foundation

/// The Thalovant control API rejected a request or returned an unusable response.
public struct ThalovantApiError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    /// HTTP status code, when the server produced a response.
    public let statusCode: Int?
    /// Raw response body, when the server produced a response.
    public let body: String?
    /// Machine-readable error code decoded from the body, when present
    /// (top-level `code`, or `detail.code` for FastAPI error envelopes).
    public let errorCode: String?

    public init(message: String, statusCode: Int? = nil, body: String? = nil, errorCode: String? = nil) {
        self.message = message
        self.statusCode = statusCode
        self.body = body
        self.errorCode = errorCode ?? ThalovantApiError.decodeErrorCode(from: body)
    }

    public var description: String { message }
    public var errorDescription: String? { message }

    static func decodeErrorCode(from body: String?) -> String? {
        guard let body, let object = try? ThalovantJSON.decodeObject(body) else { return nil }
        if let code = object["code"]?.stringValue { return code }
        if let code = object["detail"]?["code"]?.stringValue { return code }
        return nil
    }
}

/// The provided identity document is missing fields or unreadable.
public struct ThalovantIdentityError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// The hub data-plane connection could not be established or was lost.
public struct ThalovantConnectionError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// The hub reported a runtime failure while handling a request.
public struct ThalovantRuntimeError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// The hub did not respond within the allotted time.
public struct ThalovantTimeoutError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// The requested data-plane protocol is not usable with this identity or SDK.
public struct ThalovantUnsupportedProtocolError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}
