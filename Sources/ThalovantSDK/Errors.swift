import Foundation

/// The Thalovant control API rejected a request or returned an unusable response.
///
/// `statusCode` is the HTTP status when the API answered. Everything else the
/// API said rides beside the message rather than inside it:
///
/// - `problem` is the whole error body, parsed, when it is a JSON object --
///   the Problem+JSON document every Thalovant API refusal is. A structured
///   field the API adds is reachable here without a new SDK release:
///   `refused_images`, `allowed_images` and `allowed_repositories` on a
///   `platform_image_required` refusal, `resource`, `limit` and `used` on a
///   `plan_limit` one.
/// - `errorCode` is the body's machine-readable code, for branching without
///   reading the prose.
/// - `detail` is the API's own sentence, whole, exactly as sent.
///
/// The message is a single bounded line for display; it can be shortened, so
/// it is never where to read what the API said. A value the body echoed back
/// from the request never reaches the message, only `problem` and `body`.
///
/// All three are nil for a failure with no response body, such as a missing
/// token or a transport error.
///
/// `kind` says what sort of refusal it is -- sign in again, a plan limit, a hub
/// already linked, a connection type the API does not know, a device sign-in
/// still waiting -- so a caller can branch without reading codes. Every kind
/// is still this one type, so a `catch let error as ThalovantApiError` written
/// before `kind` existed matches all of them, with every field above on each.
public struct ThalovantApiError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    /// HTTP status code, when the server produced a response.
    public let statusCode: Int?
    /// Raw response body, when the server produced a response.
    public let body: String?
    /// The body's machine-readable code: its `code` when that is a string with
    /// something other than whitespace in it, else the `code` inside a
    /// `detail` that is itself an object (FastAPI's own envelope). Exactly as
    /// sent; nil when there is none.
    public let errorCode: String?
    /// The API's own sentence: the body's `detail` when that is a string with
    /// something other than whitespace in it, else the `detail` inside a
    /// `detail` that is itself an object. The whole string exactly as sent --
    /// never trimmed, collapsed or shortened, unlike `message`. Nil when there
    /// is none, including for a validation error, whose `detail` is a list.
    public let detail: String?
    /// The whole response body, parsed, when it is a JSON object; nil for an
    /// empty body, a body that is not JSON, or JSON that is not an object.
    /// Whole numbers stay `.integer`.
    public let problem: JSONObject?
    /// What kind of refusal this is. Read from the status and the body when
    /// the API answered: 401, 423 and a 403 `Insufficient scopes` are `.auth`;
    /// 402 and a 403 `plan_limit` are `.plan`; a 409
    /// `home_assistant_already_linked` is `.alreadyLinked`. The calls that
    /// know more say so: a device-login poll, and a create whose connection
    /// type the API does not know. `.unreachable` when the API never
    /// answered, `.other` for everything else, including a local failure. New
    /// kinds may be added, so a `switch` over it needs a `default`.
    public let kind: Kind
    /// How long the API asked the caller to wait before trying again, in
    /// seconds, when it said: a 429's `retry_after_seconds` (at the top of
    /// the problem or inside its `detail` object), else its `Retry-After` or
    /// `RateLimit-Reset` header when either is a whole number of seconds.
    /// Nil otherwise. The API's own rate limiter answers a 429 in plain text
    /// with only `RateLimit-*` headers, which is why the headers count.
    public let retryAfterSeconds: TimeInterval?

    /// Values passed here win over what `body` says. Given `body` and no
    /// `problem`, `problem` is `body` parsed; `errorCode` and `detail` are then
    /// read from `problem`. Without `kind`, the kind is read from the status
    /// and the problem.
    public init(
        message: String,
        statusCode: Int? = nil,
        body: String? = nil,
        errorCode: String? = nil,
        detail: String? = nil,
        problem: JSONObject? = nil,
        kind: Kind? = nil,
        retryAfterSeconds: TimeInterval? = nil
    ) {
        self.init(
            message: message,
            statusCode: statusCode,
            body: body,
            errorCode: errorCode,
            detail: detail,
            parsed: problem ?? Self.problem(from: body),
            kind: kind,
            retryAfterSeconds: retryAfterSeconds
        )
    }

    private init(
        message: String,
        statusCode: Int?,
        body: String?,
        errorCode: String?,
        detail: String?,
        parsed problem: JSONObject?,
        kind: Kind?,
        retryAfterSeconds: TimeInterval?
    ) {
        self.message = message
        self.statusCode = statusCode
        self.body = body
        self.problem = problem
        let read = Self.problemFields(problem)
        self.errorCode = errorCode ?? read.code
        self.detail = detail ?? read.detail
        self.kind = kind ?? Self.kind(
            statusCode: statusCode, errorCode: self.errorCode, detail: self.detail, problem: problem)
        self.retryAfterSeconds = retryAfterSeconds ?? Self.retryAfter(problem)
    }

    /// A problem's `retry_after_seconds`, at its top or inside a `detail`
    /// object: the API's per-token 429 is FastAPI's envelope around a
    /// structured refusal, so the number sits inside `detail`, as `code` does.
    static func retryAfter(_ problem: JSONObject?) -> TimeInterval? {
        guard let problem else { return nil }
        for source in [problem, problem["detail"]?.objectValue ?? [:]] {
            switch source["retry_after_seconds"] {
            case .integer(let seconds)? where seconds >= 0: return TimeInterval(seconds)
            case .number(let seconds)? where seconds.isFinite && seconds >= 0: return seconds
            default: continue
            }
        }
        return nil
    }

    /// `Retry-After` in whole seconds, else `RateLimit-Reset`. An HTTP-date
    /// `Retry-After` is not read.
    static func retryAfter(header: (String) -> String?) -> TimeInterval? {
        for name in ["Retry-After", "RateLimit-Reset"] {
            let value = header(name)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !value.isEmpty, value.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }), let seconds = Int(value) {
                return TimeInterval(seconds)
            }
        }
        return nil
    }

    /// The same error, told apart as `kind`, with its own message: everything
    /// the API said -- status, body, code, detail, problem -- is kept.
    func reclassified(as kind: Kind, message: String? = nil) -> ThalovantApiError {
        ThalovantApiError(
            message: message ?? self.message,
            statusCode: statusCode,
            body: body,
            errorCode: errorCode,
            detail: detail,
            parsed: problem,
            kind: kind,
            retryAfterSeconds: retryAfterSeconds
        )
    }

    /// The kind an answer's status and problem make it.
    static func kind(statusCode: Int?, errorCode: String?, detail: String?, problem: JSONObject?) -> Kind {
        guard let statusCode else { return .other }
        if statusCode == 401 || statusCode == 423 || (statusCode == 403 && detail == "Insufficient scopes") {
            // A token unknown, expired or revoked; an account locked; or a token
            // without the scope: signing in again is the way out of each.
            return .auth
        }
        if statusCode == 402 || (statusCode == 403 && errorCode == "plan_limit") {
            return .plan
        }
        if statusCode == 409 && errorCode == "home_assistant_already_linked" {
            return .alreadyLinked(clientId: linkedClientId(problem))
        }
        return .other
    }

    /// The connection that holds a link, when the refusal names it: at the top
    /// of the body or inside a `detail` object, under any of the spellings
    /// the API has used.
    private static func linkedClientId(_ problem: JSONObject?) -> String? {
        guard let problem else { return nil }
        let nested = problem["detail"]?.objectValue ?? [:]
        for source in [problem, nested] {
            for key in ["client_id", "existing_client_id", "connection_id"] {
                if let value = source[key]?.stringValue, !value.isEmpty { return value }
            }
        }
        return nil
    }

    public var description: String { message }
    public var errorDescription: String? { message }

    /// The body as a JSON object, decoded as UTF-8 whatever the response's
    /// Content-Type said; nil when it is not one.
    static func problem(from body: String?) -> JSONObject? {
        guard let body else { return nil }
        return try? ThalovantJSON.decodeObject(body)
    }

    /// The `code` and `detail` of an API error body.
    ///
    /// Read from the body's own members first. When `detail` is itself an
    /// object, it is FastAPI's envelope around a structured refusal -- what the
    /// API sends when its Problem+JSON handler has not lifted that object's
    /// members to the top -- so the code and the sentence are read from inside
    /// it. Nothing is trimmed or shortened.
    static func problemFields(_ problem: JSONObject?) -> (code: String?, detail: String?) {
        guard let problem else { return (nil, nil) }
        let nested = problem["detail"]?.objectValue ?? [:]
        let code = problemText(problem["code"]) ?? problemText(nested["code"])
        let detail = problemText(problem["detail"]) ?? problemText(nested["detail"])
        return (code, detail)
    }

    /// A string with something other than whitespace in it, exactly as sent;
    /// anything else is absent.
    private static func problemText(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue, text.contains(where: { !$0.isWhitespace }) else { return nil }
        return text
    }

    /// Builds the error for a non-2xx control API response, parsing the body
    /// once. The human-facing `message` — and therefore
    /// `description`/`errorDescription`, which a SwiftUI alert renders —
    /// carries only the status and a short, single-line server detail, never
    /// the full raw body. A raw body can echo submitted secrets
    /// (`POST /v1/clients` is sent apiKey/password/cryptoKey, and auth/token
    /// and device/token carry credentials). The complete body is still
    /// retained in `body`, and parsed in `problem`, with `errorCode` and the
    /// whole `detail` read from it.
    static func httpFailure(
        statusCode: Int, body: String, header: (String) -> String? = { _ in nil }
    ) -> ThalovantApiError {
        let problem = Self.problem(from: body)
        let summary = serverErrorDetail(problem)
        let message = summary.isEmpty
            ? "Thalovant API request failed with HTTP \(statusCode)."
            : "Thalovant API request failed with HTTP \(statusCode): \(summary)"
        return ThalovantApiError(
            message: message,
            statusCode: statusCode,
            body: body,
            errorCode: nil,
            detail: nil,
            parsed: problem,
            kind: nil,
            retryAfterSeconds: Self.retryAfter(problem) ?? Self.retryAfter(header: header)
        )
    }
}

extension ThalovantApiError {
    /// The kinds of refusal a caller branches on. See `ThalovantApiError.kind`.
    public enum Kind: Equatable, Sendable {
        /// An ordinary API error, or a local failure with no answer behind it.
        case other
        /// The token is unknown, expired, revoked or lacks the scope, or the
        /// account is locked: sign in again.
        case auth
        /// The account's plan does not allow it: a 402, or a 403 `plan_limit`
        /// whose `problem` carries `resource`, `limit` and `used`.
        case plan
        /// A hub takes one connection of this kind and already has it (409
        /// `home_assistant_already_linked`). `clientId` is the connection that
        /// holds the link, when the API said which.
        case alreadyLinked(clientId: String?)
        /// The API does not know the connection type asked for: a 422 about
        /// `connection_type`, or a created connection that came back of
        /// another type -- which the SDK deleted before throwing.
        case unsupportedConnectionType
        /// A device sign-in nobody has approved yet. Poll again after
        /// `interval` seconds, already five seconds longer for every
        /// `slow_down` the API sent for this code.
        case deviceLoginPending(interval: TimeInterval)
        /// The device code expired before anybody approved it; begin again.
        case deviceLoginExpired
        /// The person declined the sign-in.
        case deviceLoginDenied
        /// The API could not be reached at all -- DNS, the connection, TLS,
        /// a proxy -- so there is no status, code or detail. Trying again
        /// later can work; nothing was refused.
        case unreachable
    }
}

/// An error that means the hub connection could not be made or kept.
///
/// The SDK's errors are distinct value types rather than a class hierarchy,
/// so an error that is two things at once -- the admission timeout is both a
/// connection error and a timeout -- conforms to a protocol for each.
/// `ThalovantConnectionError` conforms, and so do
/// `ThalovantAdmissionFailedError` and `ThalovantAdmissionTimeoutError`:
/// `catch let error as any ThalovantConnectionFailure` takes all of them.
public protocol ThalovantConnectionFailure: Error {
    var message: String { get }
}

/// An error that means something did not happen within its deadline.
///
/// `ThalovantTimeoutError` conforms, and so does
/// `ThalovantAdmissionTimeoutError`: `catch let error as any
/// ThalovantTimeoutFailure` takes both.
public protocol ThalovantTimeoutFailure: Error {
    var message: String { get }
}

extension ThalovantConnectionError: ThalovantConnectionFailure {}
extension ThalovantTimeoutError: ThalovantTimeoutFailure {}

/// A hub did not admit a new connection within the wait.
///
/// Both a connection error and a timeout: the connection exists and may still
/// be admitted, so waiting longer, or connecting later, can succeed. Match it
/// by its own type, or as `any ThalovantConnectionFailure` or `any
/// ThalovantTimeoutFailure`.
public struct ThalovantAdmissionTimeoutError: ThalovantConnectionFailure, ThalovantTimeoutFailure,
    CustomStringConvertible, LocalizedError
{
    public let message: String
    /// The seconds waited.
    public let timeout: TimeInterval
    public init(_ message: String, timeout: TimeInterval) {
        self.message = message
        self.timeout = timeout
    }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// A new connection will not be admitted.
///
/// Either the operation that admits it failed or the platform gave up on it
/// -- `errorCode` is the operation's own code, and `apiError` is nil -- or the
/// API refused the wait itself, and then `apiError` keeps what it answered:
/// `statusCode`, `errorCode`, `detail` and `problem`, as any refusal does. An
/// authentication refusal is not this: it comes as the `ThalovantApiError`
/// it is, of kind `.auth`.
public struct ThalovantAdmissionFailedError: ThalovantConnectionFailure, CustomStringConvertible, LocalizedError {
    public let message: String
    /// The operation's own error code, for a failure on the platform.
    public let errorCode: String?
    /// The API's answer, when it refused the wait itself.
    public let apiError: ThalovantApiError?
    public init(_ message: String, errorCode: String? = nil, apiError: ThalovantApiError? = nil) {
        self.message = message
        self.errorCode = errorCode
        self.apiError = apiError
    }
    /// The HTTP status of the API's refusal; nil for a failure on the platform.
    public var statusCode: Int? { apiError?.statusCode }
    /// The API's own sentence, when it refused the wait.
    public var detail: String? { apiError?.detail }
    /// The API's whole error body, when it refused the wait.
    public var problem: JSONObject? { apiError?.problem }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// A short, non-sensitive server detail for a human-facing error message. For a
/// JSON error envelope it is built only from allowlisted fields — the machine
/// `code` and the server's own `message`/`detail`/`title` summary — never the
/// echoed request `input` or arbitrary body content, so submitted credentials
/// (`POST /v1/clients` sends apiKey/password/cryptoKey, which FastAPI repeats in
/// a validation error's `input`) can never reach `message`, `description`, or
/// `errorDescription`. A non-JSON body is retained only on
/// `ThalovantApiError.body`, never echoed into ordinary exception messages.
func serverErrorDetail(_ object: JSONObject?) -> String {
    guard let object else {
        return ""
    }
    var parts: [String] = []
    // The message's own reading of the code, unchanged: any string at the top,
    // else `detail.code`. `errorCode` is stricter (see `problemFields`); the
    // display line is kept exactly as it was.
    if let code = object["code"]?.stringValue ?? object["detail"]?["code"]?.stringValue {
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
///
/// `kind` tells the two verdicts that retrying will not change apart from a
/// connection that simply failed: `.refused`, the hub turning these
/// credentials away, and `.keyChanged`, a hub whose Noise key is not the one
/// pinned for it. Both are still this type, so a `catch let error as
/// ThalovantConnectionError` written before `kind` existed matches them.
public struct ThalovantConnectionError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public let kind: Kind
    public init(_ message: String, kind: Kind = .other) {
        self.message = message
        self.kind = kind
    }
    public var description: String { message }
    public var errorDescription: String? { message }

    public enum Kind: Equatable, Sendable {
        /// The connection could not be made or was lost; trying again can work.
        case other
        /// The hub turned these credentials away: it closed the socket during
        /// the handshake without a status, with 1000 or with 1008, answered the
        /// WebSocket upgrade 401 or 403, or sent a Noise handshake message that
        /// does not authenticate under the key the password derives. A
        /// connection just created is refused until its hub admits it, so a
        /// refusal can still clear up; `HubSession.run()` retries refusals for
        /// `HubSessionPolicy.refusalGraceSeconds`, then throws.
        case refused
        /// The hub answered with a different Noise key than the one pinned for
        /// it: the hub was replaced, or somebody is in between, and the SDK
        /// cannot tell which. It never connects and never replaces the pin by
        /// itself. Retrying changes nothing, so `HubSession.run()` stops on it
        /// at once. Remove the pin only once the new key is known to be the
        /// hub's.
        case keyChanged
    }
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
            if quota.limit == 0, quota.used == 0, quota.resetAfter == 0, quota.period.isEmpty {
                // Refused on a quota, with none of the numbers. "All questions
                // used" would be inventing one.
                self.message = "The hub refused '\(deniedType)': a quota has run out."
                return
            }
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
    /// The largest count the wire can carry, being the largest whole number
    /// every JSON decoder holds exactly. Above it a decoder backed by a double
    /// can no longer tell one whole number from the next, so two SDKs would
    /// report different allowances for the same denial -- and a count nobody
    /// can agree on is worse than none.
    static let maxCount = (1 << 53) - 1

    private static func wholeCount(_ value: JSONValue?) -> Int {
        // `.integer` as well as `.number`: JSONValue keeps them apart, and a
        // whole number off the wire decodes as the former -- reading only
        // `.number` made every quota come back as zeros.
        let whole: Int
        switch value {
        case .integer(let number):
            whole = number
        case .number(let number):
            // Whole, and inside what an Int holds: a finite 1e20 passes every
            // other guard and traps on conversion. Compared as a Double
            // against exact bounds, since Int.max is not representable.
            guard number.isFinite, number == number.rounded(),
                  number >= 0, number < 9_223_372_036_854_775_808.0
            else { return 0 }
            whole = Int(number)
        case .string(let text):
            whole = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        default:
            return 0
        }
        return (0...maxCount).contains(whole) ? whole : 0
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
