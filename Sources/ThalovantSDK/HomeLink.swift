import Foundation

// The Home Assistant link: a hub asks a home, and the home always answers.
//
// A home skill on the hub sends `thalovant.home.request` to the account's
// Home Assistant connection; the integration hands the utterance to Home
// Assistant's conversation agent and answers with `thalovant.home.response`.
// The rules every SDK keeps (`home-link-vectors.json`):
//
// - every request gets exactly one answer, within the hub's 10 seconds;
// - the answer is a reply (OVOS-MSG-1 §5.2), so it goes back the way the
//   request came;
// - `speech` is plain text, never markup;
// - `response_type` is `action_done`, `query_answer` or `error`, and an
//   `error` names one `error_code`. When the SDK has to answer for a handler
//   -- it threw, it was too slow, it answered outside the contract -- the
//   speech is empty: the hub speaks its own sentence for the code, in the
//   device's language, which the SDK does not know.

/// The context of a reply to a message that carried `context` (OVOS-MSG-1 §5.2).
///
/// A copy, so the reply keeps the request's session and everything else it
/// said, with the routing turned round: the reply goes to whoever sent the
/// request (`destination` becomes the old `source`) and comes from whoever it
/// was sent to (`source` becomes the old `destination`, its first entry when
/// that is a list). A context with a destination and no source gets a reply
/// with no destination at all: keeping the old one would address the reply
/// to its own sender. A hub routes the answer back by it, across bridges and
/// NAT. An event this SDK delivers carries the context exactly as the hub
/// sent it, so this is built from that.
public func replyContext(_ context: JSONObject?) -> JSONObject {
    var swapped = context ?? [:]
    let source = swapped["source"].flatMap { $0.isNull ? nil : $0 }
    let destination = swapped["destination"].flatMap { $0.isNull ? nil : $0 }
    if let destination {
        if case .array(let peers) = destination, let first = peers.first {
            swapped["source"] = first
        } else {
            swapped["source"] = destination
        }
    }
    if let source {
        swapped["destination"] = source
    } else if destination != nil {
        swapped.removeValue(forKey: "destination")
    }
    return swapped
}

/// Anything that can answer a message the hub sent, back along the route it
/// came: a `ThalovantClient` or a `HubSession`.
public protocol ThalovantReplying: AnyObject, Sendable {
    func reply(to event: ThalovantEvent, type: String, data: JSONObject, context: JSONObject) async throws
}

extension ThalovantClient: ThalovantReplying {
    /// Answers a message the hub sent, back along the route it came.
    ///
    /// The reply carries a copy of the request's context -- its session, its
    /// request id, everything a skill waiting on it matches -- with `source`
    /// and `destination` swapped (`replyContext`). `context` entries are laid
    /// over the copy before the swap.
    public func reply(
        to event: ThalovantEvent,
        type: String,
        data: JSONObject = [:],
        context: JSONObject = [:]
    ) async throws {
        let name = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw ThalovantRuntimeError("A reply needs a non-empty message type.")
        }
        var base = event.context
        for (key, value) in context { base[key] = value }
        try await emit(name, data: data, context: replyContext(base))
    }
}

/// The Home Assistant link's message types and deadlines.
public enum HomeLink {
    /// What a hub sends: `{request_id, utterance, lang, conversation_id?}`.
    public static let requestMessageType = "thalovant.home.request"
    /// What the SDK answers with: `{request_id, speech, response_type,
    /// error_code?, continue_conversation, conversation_id?}`.
    public static let responseMessageType = "thalovant.home.response"
    /// The hub treats silence after this many seconds as `timeout`.
    public static let hubTimeout: TimeInterval = 10
    /// How long a handler has by default: a second inside the hub's bound, so
    /// the SDK's own `timeout` answer still lands before the hub gives up.
    public static let handlerTimeout: TimeInterval = hubTimeout - 1
}

/// `response_type` of a home response. The contract's three are named; any
/// other value a handler gives is answered as `error` / `unknown`.
public struct HomeResponseType: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    /// Home Assistant did something.
    public static let actionDone: HomeResponseType = "action_done"
    /// Home Assistant answered a question.
    public static let queryAnswer: HomeResponseType = "query_answer"
    /// Home Assistant could not; `errorCode` says why.
    public static let error: HomeResponseType = "error"
    /// The contract's set, in its order.
    public static let all: [HomeResponseType] = [.actionDone, .queryAnswer, .error]
}

/// `error_code` of an `error` home response. The contract's six are named; any
/// other value a handler gives is answered as `unknown`.
public struct HomeErrorCode: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let noIntentMatch: HomeErrorCode = "no_intent_match"
    public static let noValidTargets: HomeErrorCode = "no_valid_targets"
    /// What the SDK answers when the handler throws.
    public static let failedToHandle: HomeErrorCode = "failed_to_handle"
    /// What the SDK answers when the handler answers outside the contract.
    public static let unknown: HomeErrorCode = "unknown"
    /// What the SDK answers when the handler is too slow.
    public static let timeout: HomeErrorCode = "timeout"
    public static let agentUnavailable: HomeErrorCode = "agent_unavailable"
    /// The contract's set, in its order.
    public static let all: [HomeErrorCode] = [
        .noIntentMatch, .noValidTargets, .failedToHandle, .unknown, .timeout, .agentUnavailable,
    ]
}

/// One `thalovant.home.request`: what was said, in which language.
public struct HomeRequest: Sendable {
    /// The hub's id for the request; `""` when it sent none.
    public let requestId: String
    public let utterance: String
    public let lang: String?
    /// The conversation the request continues, when it continues one.
    public let conversationId: String?
    /// The event it arrived as; the answer is a reply to it.
    public let event: ThalovantEvent

    public init(event: ThalovantEvent) {
        func text(_ key: String) -> String? {
            guard let value = event.data[key]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        self.requestId = text("request_id") ?? ""
        self.utterance = text("utterance") ?? ""
        self.lang = text("lang")
        self.conversationId = text("conversation_id")
        self.event = event
    }
}

/// What a handler says back. `speech` may carry markup; it is sent as plain text.
public struct HomeAnswer: Equatable, Sendable {
    public var speech: String
    public var responseType: HomeResponseType
    /// Only with `.error`; ignored with any other `responseType`.
    public var errorCode: HomeErrorCode?
    public var continueConversation: Bool
    /// Echoes the request's own when nil.
    public var conversationId: String?

    public init(
        speech: String = "",
        responseType: HomeResponseType = .actionDone,
        errorCode: HomeErrorCode? = nil,
        continueConversation: Bool = false,
        conversationId: String? = nil
    ) {
        self.speech = speech
        self.responseType = responseType
        self.errorCode = errorCode
        self.continueConversation = continueConversation
        self.conversationId = conversationId
    }

    /// An `error` answer. Leave `speech` empty for the hub to say its own
    /// sentence for the code, in the device's language.
    public static func error(_ code: HomeErrorCode, speech: String = "") -> HomeAnswer {
        HomeAnswer(speech: speech, responseType: .error, errorCode: code)
    }
}

/// Answers a home request: `@Sendable (HomeRequest) async throws -> HomeAnswer`.
public typealias HomeHandler = @Sendable (HomeRequest) async throws -> HomeAnswer

/// Speech a device can say as it is, made in this order -- the rules every SDK
/// keeps, with nothing from a platform's HTML library, whose entity tables
/// differ:
///
/// 1. Markup goes (`stripSsml`): a tag -- `<` or `</` right before an ASCII
///    letter, up to the next `>` outside a quoted attribute value -- a
///    comment and a processing instruction. Any other `<` is text, so
///    "5 < 6 and 7 > 3" stays whole.
/// 2. Character references are decoded once, left to right: numeric ones
///    (`&#72;`, `&#x48;`) other than 0, surrogates and anything above
///    U+10FFFF, the five XML entities, and `&nbsp;`. Nothing else: `&eacute;`
///    stays as written, and a reference needs its `;`.
/// 3. Every run of Unicode White_Space becomes one space, and the ends are
///    trimmed.
public func plainSpeech(_ text: String?) -> String {
    guard let text, !text.isEmpty else { return "" }
    var out = ""
    var pendingSpace = false
    for scalar in decodeReferences(stripSsml(text)).unicodeScalars {
        if scalar.properties.isWhitespace {
            pendingSpace = true
            continue
        }
        if pendingSpace && !out.isEmpty { out.append(" ") }
        pendingSpace = false
        out.unicodeScalars.append(scalar)
    }
    return out
}

/// The `thalovant.home.response` payload for `answer`, held to the contract.
///
/// An answer outside it -- an unknown `responseType`, or an `error` without a
/// known `errorCode` -- becomes `error` / `unknown`, keeping its speech.
/// `conversation_id` is the answer's, else the request's, and absent when
/// neither has one.
public func homeResponse(to request: HomeRequest, answer: HomeAnswer) -> JSONObject {
    var responseType = answer.responseType
    var errorCode = responseType == .error ? answer.errorCode : nil
    if !HomeResponseType.all.contains(responseType)
        || (responseType == .error && !(errorCode.map(HomeErrorCode.all.contains) ?? false))
    {
        responseType = .error
        errorCode = .unknown
    }
    var payload: JSONObject = [
        "request_id": .string(request.requestId),
        "speech": .string(plainSpeech(answer.speech)),
        "response_type": .string(responseType.rawValue),
        "continue_conversation": .bool(answer.continueConversation),
    ]
    if let errorCode {
        payload["error_code"] = .string(errorCode.rawValue)
    }
    if let conversationId = answer.conversationId.flatMap({ $0.isEmpty ? nil : $0 }) ?? request.conversationId {
        payload["conversation_id"] = .string(conversationId)
    }
    return payload
}

extension ThalovantReplying {
    /// Answers one `thalovant.home.request`: runs `handler`, then replies
    /// whatever happened. Returns the payload it sent, or nil when there was
    /// no time left to send one.
    ///
    /// Everything happens inside `hubTimeout`, counted from this call: the hub
    /// gives up on a request after that, and an answer it has given up on only
    /// confuses the next one. The handler gets `timeout` or what is left of
    /// the bound, whichever is less, and the answer goes out when that is up
    /// even if the handler ignores being cancelled. The reply gets what the
    /// handler left: it is never started after the bound, and one still queued
    /// behind other frames when the bound passes is withdrawn. A handler that
    /// throws is answered `failed_to_handle`, one too slow `timeout`, and one
    /// outside the contract `unknown`. Cancelling the task that called this
    /// cancels the handler and sends nothing.
    @discardableResult
    public func answerHomeRequest(
        _ event: ThalovantEvent,
        timeout: TimeInterval = HomeLink.handlerTimeout,
        hubTimeout: TimeInterval = HomeLink.hubTimeout,
        handler: @escaping HomeHandler
    ) async throws -> JSONObject? {
        try await answerHomeRequest(
            event, arrivedAt: ProcessInfo.processInfo.systemUptime, timeout: timeout, hubTimeout: hubTimeout,
            handler: handler)
    }

    /// `answerHomeRequest` with the bound counted from when the request
    /// arrived rather than from the call.
    func answerHomeRequest(
        _ event: ThalovantEvent,
        arrivedAt: TimeInterval,
        timeout: TimeInterval,
        hubTimeout: TimeInterval,
        handler: @escaping HomeHandler
    ) async throws -> JSONObject? {
        func left() -> TimeInterval {
            hubTimeout.isFinite ? hubTimeout - (ProcessInfo.processInfo.systemUptime - arrivedAt) : HomeLink.hubTimeout
        }
        let request = HomeRequest(event: event)
        let bound = timeout.isFinite ? min(timeout, left()) : left()
        let answer = try await boundedHomeAnswer(request, timeout: max(0, bound), handler: handler)
        let payload = homeResponse(to: request, answer: answer)
        let remaining = left()
        // No time left: the hub has given up on it.
        guard remaining > 0 else { return nil }
        let sent = try await firstWithin(remaining) {
            try await self.reply(to: event, type: HomeLink.responseMessageType, data: payload, context: [:])
            return true
        }
        // Withdrawn: it could only have arrived after the hub gave up.
        return sent == true ? payload : nil
    }
}

extension ThalovantClient {
    /// Answers every `thalovant.home.request` this client receives, each on a
    /// task of its own so a slow one does not hold up the next. Closing the
    /// subscription cancels the answers still running.
    @discardableResult
    public func answerHomeRequests(
        timeout: TimeInterval = HomeLink.handlerTimeout,
        handler: @escaping HomeHandler
    ) -> ThalovantSubscription {
        let answers = HomeAnswers()
        let subscription = on(HomeLink.requestMessageType) { [weak self] event in
            guard let self else { return }
            let arrived = ProcessInfo.processInfo.systemUptime
            answers.start {
                _ = try? await self.answerHomeRequest(
                    event, arrivedAt: arrived, timeout: timeout, hubTimeout: HomeLink.hubTimeout, handler: handler)
            }
        }
        return ThalovantSubscription {
            subscription.close()
            answers.cancelAll()
        }
    }
}

extension HubSession {
    /// Answers every `thalovant.home.request` any client of this session
    /// receives, on the live link at once even while an `ask` holds the
    /// session. Each answer runs on a task of its own; closing the
    /// subscription cancels the answers still running.
    @discardableResult
    public func answerHomeRequests(
        timeout: TimeInterval = HomeLink.handlerTimeout,
        handler: @escaping HomeHandler
    ) throws -> ThalovantSubscription {
        let answers = HomeAnswers()
        let subscription = try on(HomeLink.requestMessageType) { [weak self] event in
            guard let self else { return }
            let arrived = ProcessInfo.processInfo.systemUptime
            answers.start {
                _ = try? await self.answerHomeRequest(
                    event, arrivedAt: arrived, timeout: timeout, hubTimeout: HomeLink.hubTimeout, handler: handler)
            }
        }
        return ThalovantSubscription {
            subscription.close()
            answers.cancelAll()
        }
    }
}

extension HubSession: ThalovantReplying {}

// MARK: - Internals

/// Runs `handler` for at most `timeout` seconds and turns whatever happened
/// into an answer. Throws only when the calling task is cancelled.
///
/// Not a task group: a group waits for every child to finish, so a handler
/// that ignores cancellation would hold the answer past the hub's deadline.
/// The handler runs on a task of its own, cancelled when the time is up and
/// left to end in its own time; its late result is dropped.
func boundedHomeAnswer(
    _ request: HomeRequest,
    timeout: TimeInterval,
    handler: @escaping HomeHandler
) async throws -> HomeAnswer {
    do {
        guard let answer = try await firstWithin(timeout, { try await handler(request) }) else {
            return .error(.timeout)
        }
        return answer
    } catch is CancellationError where Task.isCancelled {
        throw CancellationError()
    } catch {
        return .error(.failedToHandle)
    }
}

/// The answers one subscription has running.
final class HomeAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [UUID: Task<Void, Never>] = [:]
    private var closed = false

    func start(_ body: @escaping @Sendable () async -> Void) {
        let id = UUID()
        lock.locked {
            guard !closed else { return }
            running[id] = Task { [weak self] in
                await body()
                self?.finish(id)
            }
        }
    }

    private func finish(_ id: UUID) {
        _ = lock.locked { running.removeValue(forKey: id) }
    }

    func cancelAll() {
        let tasks = lock.locked { () -> [Task<Void, Never>] in
            closed = true
            let tasks = Array(running.values)
            running.removeAll()
            return tasks
        }
        for task in tasks { task.cancel() }
    }
}

/// The portable set of character references: numeric (decimal and
/// hexadecimal), the five XML entities, and `&nbsp;`, each with its `;`.
private let referencePattern = try! NSRegularExpression(
    pattern: "&(?:#([0-9]{1,7})|#[xX]([0-9A-Fa-f]{1,6})|(amp|lt|gt|quot|apos|nbsp));")
private let namedReferences: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
]

/// Decodes the portable set of character references, once, left to right. A
/// numeric reference to no character -- 0, a surrogate, anything above
/// U+10FFFF -- stays as written.
func decodeReferences(_ text: String) -> String {
    guard text.contains("&") else { return text }
    let source = text as NSString
    var out = ""
    var cursor = 0
    for match in referencePattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        out += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        cursor = match.range.location + match.range.length
        let whole = source.substring(with: match.range)
        if match.range(at: 3).location != NSNotFound {
            out += namedReferences[source.substring(with: match.range(at: 3))] ?? whole
            continue
        }
        let decimal = match.range(at: 1).location != NSNotFound
        let digits = source.substring(with: match.range(at: decimal ? 1 : 2))
        guard let value = UInt32(digits, radix: decimal ? 10 : 16), value != 0,
              !(0xD800...0xDFFF).contains(value), value <= 0x10FFFF,
              let scalar = Unicode.Scalar(value) else {
            out += whole
            continue
        }
        out.unicodeScalars.append(scalar)
    }
    out += source.substring(from: cursor)
    return out
}
