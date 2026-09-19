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

    /// Builds the error for a non-2xx control API response. The human-facing
    /// `message` — and therefore `description`/`errorDescription`, which a
    /// SwiftUI alert renders — carries only the status and a short, single-line
    /// server detail, never the full raw body. A raw body can echo submitted
    /// secrets (`POST /v1/clients` is sent apiKey/password/cryptoKey, and
    /// auth/token and device/token carry credentials). The complete body is
    /// still retained in `body` for programmatic `errorCode` decoding.
    static func httpFailure(statusCode: Int, body: String) -> ThalovantApiError {
        let detail = serverErrorDetail(from: body)
        let message = detail.isEmpty
            ? "Thalovant API request failed with HTTP \(statusCode)."
            : "Thalovant API request failed with HTTP \(statusCode): \(detail)"
        return ThalovantApiError(message: message, statusCode: statusCode, body: body)
    }
}

/// A short, non-sensitive server detail for a human-facing error message. For a
/// JSON error envelope it is built only from allowlisted fields — the machine
/// `code` and the server's own `message`/`detail`/`title` summary — never the
/// echoed request `input` or arbitrary body content, so submitted credentials
/// (`POST /v1/clients` sends apiKey/password/cryptoKey, which FastAPI repeats in
/// a validation error's `input`) can never reach `message`, `description`, or
/// `errorDescription`. A non-JSON body is retained only on
/// `ThalovantApiError.body`, never echoed into ordinary exception messages.
func serverErrorDetail(from body: String) -> String {
    guard let object = try? ThalovantJSON.decodeObject(body) else {
        return ""
    }
    var parts: [String] = []
    if let code = ThalovantApiError.decodeErrorCode(from: body) {
        parts.append(code)
    }
    if let message = allowlistedServerMessage(object) {
        parts.append(message)
    }
    return boundedServerDetail(parts.joined(separator: ": "))
}

/// The server's own human-readable summary, taken only from an allowlisted set
/// of fields. Deliberately ignores a `detail` array — FastAPI validation
/// errors, whose entries echo the submitted request `input`.
private func allowlistedServerMessage(_ object: JSONObject) -> String? {
    if let message = object["message"]?.stringValue { return message }
    if let detail = object["detail"]?.stringValue { return detail }
    if let detail = object["detail"]?["message"]?.stringValue { return detail }
    if let title = object["title"]?.stringValue { return title }
    return nil
}

/// Reduces a string to a short, single-line detail safe to surface in an error
/// message or UI alert: collapses every run of whitespace and newlines to a
/// single space and caps the length, so large bodies are never dumped verbatim.
func boundedServerDetail(_ body: String, limit: Int = 200) -> String {
    let collapsed = body
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard collapsed.count > limit else { return collapsed }
    return String(collapsed.prefix(limit)) + "…"
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

/// The numbers behind a refusal that is a spent allowance, not a policy.
///
/// The intent-quota policy denies with `intent_quota_exceeded` and sends which
/// counter ran out (`daily`, `monthly`), what it allows, how much was used, and
/// how many seconds until it resets. Without them a caller can only say
/// "refused", which is what an app showed somebody who had used up the day.
public struct ThalovantQuota: Equatable, Sendable {
    /// The counter that ran out, as the hub names it.
    public let period: String
    /// What that counter allows in its period.
    public let limit: Int
    /// How much of it was used.
    public let used: Int
    /// Seconds until the counter resets, or 0 when the hub did not say.
    public let resetAfter: Int

    public init(period: String, limit: Int, used: Int, resetAfter: Int) {
        self.period = period
        self.limit = limit
        self.used = used
        self.resetAfter = resetAfter
    }
}

/// The hub refused a message, the instant it did.
///
/// Three different things arrive as `hive.policy.denied`, and each needs
/// something different said about it: an allow-list refusal
/// (`acl_disallowed_type`, with `allowed`), a spent allowance
/// (`intent_quota_exceeded`, with `quota`), and a hub whose agent bus is down
/// (`backend_unavailable`), which nothing the caller does will fix. It is the
/// policy-shaped sibling of `ThalovantRuntimeError`, the SDK's errors being
/// distinct value types rather than a class hierarchy.
public struct ThalovantPolicyDeniedError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The hub's code for a refusal that is a spent quota, not a policy.
    public static let quotaExceededCode = "intent_quota_exceeded"
    /// The hub's code for a refusal because its own agent bus is down.
    public static let backendUnavailableCode = "backend_unavailable"

    /// The message type the hub refused, for example `recognizer_loop:utterance`.
    public let deniedType: String
    /// The hub's machine-readable code.
    public let code: String
    /// The hub's human-readable reason, when it gave one.
    public let reason: String
    /// The message types the connection is allowed to publish, when the hub listed them.
    public let allowed: [String]
    /// The numbers behind a spent allowance; nil for any other refusal.
    public let quota: ThalovantQuota?
    public let message: String

    public init(
        deniedType: String,
        code: String = "",
        reason: String = "",
        allowed: [String] = [],
        quota: ThalovantQuota? = nil
    ) {
        self.deniedType = deniedType
        self.code = code
        self.reason = reason
        self.allowed = allowed
        self.quota = quota
        // Advice follows the kind of refusal. Telling somebody who used up
        // their day to "allow this connection to publish
        // recognizer_loop:utterance" sent them to a page that could not help.
        if let quota {
            let used = quota.limit > 0 ? "\(quota.used) of \(quota.limit)" : "all"
            let period = quota.period.isEmpty ? "" : " \(quota.period)"
            let resets = quota.resetAfter > 0 ? "; it resets in \(quota.resetAfter)s" : ""
            self.message = "The hub refused '\(deniedType)': \(used)\(period) questions used\(resets)."
        } else if code == Self.backendUnavailableCode {
            let detail = reason.isEmpty ? "" : ": \(reason)"
            self.message = "The hub could not reach its assistant\(detail). Try again shortly."
        } else {
            let detail = !reason.isEmpty ? reason : (!code.isEmpty ? code : "refused by the hub's policy")
            self.message = "The hub refused '\(deniedType)': \(detail). Allow this connection to "
                + "publish '\(deniedType)' in the dashboard's connection settings."
        }
    }

    /// Builds the error from a `hive.policy.denied` event. The policy's own
    /// detail rides nested under `data.data` (hivemind-core
    /// `_send_policy_denied`: `"data": verdict.data`).
    public static func fromEvent(_ event: ThalovantEvent) -> ThalovantPolicyDeniedError {
        let inner = event.data["data"]
        // Only non-blank strings, trimmed: a number or a null in the hub's list
        // is not a message type, and carrying one through would put "3" or
        // "null" in front of an operator reading which types to allow.
        let allowed = inner?["allowed"]?.arrayValue?
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let code = event.data["code"]?.stringValue ?? ""
        var quota: ThalovantQuota?
        if code == quotaExceededCode {
            quota = ThalovantQuota(
                period: inner?["period"]?.stringValue ?? "",
                limit: wholeCount(inner?["limit"]),
                used: wholeCount(inner?["used"]),
                resetAfter: wholeCount(inner?["reset_after"])
            )
        }
        return ThalovantPolicyDeniedError(
            deniedType: event.data["denied_type"]?.stringValue ?? "",
            code: code,
            reason: event.data["reason"]?.stringValue ?? "",
            allowed: allowed,
            quota: quota
        )
    }

    /// A whole, non-negative count from the wire, or 0: never a bool, never a
    /// guess. A negative limit, usage or reset time is not something a policy
    /// can mean, and passing one through would have an app say "-1 of -5
    /// questions used".
    private static func wholeCount(_ value: JSONValue?) -> Int {
        // `.integer` as well as `.number`: JSONValue keeps them apart, and a
        // whole number off the wire decodes as the former -- reading only
        // `.number` made every quota come back as zeros.
        switch value {
        case .integer(let number):
            return max(number, 0)
        case .number(let number) where number.isFinite && number == number.rounded():
            return max(Int(number), 0)
        case .string(let text):
            return max(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, 0)
        default:
            return 0
        }
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// The hub understood a question and has nothing for it.
///
/// `ovos.intent.unmatched` (`complete_intent_failure` from older hubs) is
/// neither a refusal nor a fault: nothing went wrong, the question is outside
/// what this hub can do. As a bare runtime error a caller could only report
/// that something failed.
public struct ThalovantUnansweredError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The hub's own words, when it sent any.
    public let said: String
    public let message: String

    public init(said: String = "") {
        self.said = said
        self.message = said.isEmpty ? "The hub has no skill that answers this." : said
    }

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
