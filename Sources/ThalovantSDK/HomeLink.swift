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
/// that is a list). A hub routes the answer back by it, across bridges and
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

/// Speech a device can say as it is: markup removed, entities decoded,
/// whitespace collapsed.
///
/// References decode by Python's `html.unescape` rules: numeric ones
/// (`&#233;`, `&#xE9;`, with or without the `;`), and named ones from HTML 4's
/// 252 -- `&amp;`, `&nbsp;`, `&eacute;`, `&mdash;`, `&euro;` and the rest -- plus
/// `&apos;`, including the old unterminated forms (`&amp chips`). A name only
/// HTML5 added stays as written.
public func plainSpeech(_ text: String?) -> String {
    guard let text, !text.isEmpty else { return "" }
    let stripped = markupPattern.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    let decoded = decodeEntities(stripped)
    var out = ""
    var pendingSpace = false
    for scalar in decoded.unicodeScalars {
        if isSpeechSpace(scalar) {
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
    /// whatever happened, and returns the payload it sent.
    ///
    /// The handler has `timeout` seconds. The answer goes out when it is up
    /// even if the handler ignores being cancelled -- the hub stops waiting at
    /// ten seconds, so the SDK does not wait on a handler that will not stop.
    /// A handler that throws is answered `failed_to_handle`, one too slow
    /// `timeout`, and one outside the contract `unknown`. Cancelling the task
    /// that called this cancels the handler and sends nothing.
    @discardableResult
    public func answerHomeRequest(
        _ event: ThalovantEvent,
        timeout: TimeInterval = HomeLink.handlerTimeout,
        handler: @escaping HomeHandler
    ) async throws -> JSONObject {
        let request = HomeRequest(event: event)
        let answer = try await boundedHomeAnswer(request, timeout: timeout, handler: handler)
        let payload = homeResponse(to: request, answer: answer)
        try await reply(to: event, type: HomeLink.responseMessageType, data: payload, context: [:])
        return payload
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
            answers.start { _ = try? await self.answerHomeRequest(event, timeout: timeout, handler: handler) }
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
            answers.start { _ = try? await self.answerHomeRequest(event, timeout: timeout, handler: handler) }
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
/// left to end in its own time.
func boundedHomeAnswer(
    _ request: HomeRequest,
    timeout: TimeInterval,
    handler: @escaping HomeHandler
) async throws -> HomeAnswer {
    let finished = AsyncGate()
    let outcome = HomeOutcome()
    let work = Task {
        do {
            outcome.keep(.success(try await handler(request)))
        } catch {
            outcome.keep(.failure(error))
        }
        finished.open()
    }
    do {
        try await finished.wait(
            timeout: timeout.isFinite ? max(0, timeout) : HomeLink.handlerTimeout,
            timeoutError: HomeHandlerTimedOut())
    } catch is HomeHandlerTimedOut {
        work.cancel()
        return .error(.timeout)
    } catch {
        work.cancel()
        throw error
    }
    switch outcome.value {
    case .success(let answer):
        return answer
    case .failure, .none:
        return .error(.failedToHandle)
    }
}

private struct HomeHandlerTimedOut: Error {}

private final class HomeOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<HomeAnswer, Error>?
    var value: Result<HomeAnswer, Error>? { lock.locked { stored } }
    func keep(_ result: Result<HomeAnswer, Error>) { lock.locked { stored = result } }
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

/// `<...>`, as the reference's `strip_ssml` removes it: a `<` with no closing
/// `>` is not markup and stays.
private let markupPattern = try! NSRegularExpression(pattern: "</?[^>]*>")

/// What Python's `\s` matches: Unicode white space, and the four information
/// separators it counts as space too.
private func isSpeechSpace(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
}

/// HTML 4's named character references -- every one `html.unescape` knows,
/// which covers what speech carries -- with `&apos;` and the six uppercase
/// spellings HTML5 added for the oldest ones.
private let namedEntities: [String: String] = [
    "apos": "'", "AMP": "&", "COPY": "\u{A9}", "GT": ">", "LT": "<", "QUOT": "\"", "REG": "\u{AE}",
    "AElig": "\u{C6}", "Aacute": "\u{C1}", "Acirc": "\u{C2}", "Agrave": "\u{C0}", "Alpha": "\u{391}",
    "Aring": "\u{C5}", "Atilde": "\u{C3}", "Auml": "\u{C4}", "Beta": "\u{392}", "Ccedil": "\u{C7}",
    "Chi": "\u{3A7}", "Dagger": "\u{2021}", "Delta": "\u{394}", "ETH": "\u{D0}", "Eacute": "\u{C9}",
    "Ecirc": "\u{CA}", "Egrave": "\u{C8}", "Epsilon": "\u{395}", "Eta": "\u{397}", "Euml": "\u{CB}",
    "Gamma": "\u{393}", "Iacute": "\u{CD}", "Icirc": "\u{CE}", "Igrave": "\u{CC}", "Iota": "\u{399}",
    "Iuml": "\u{CF}", "Kappa": "\u{39A}", "Lambda": "\u{39B}", "Mu": "\u{39C}", "Ntilde": "\u{D1}",
    "Nu": "\u{39D}", "OElig": "\u{152}", "Oacute": "\u{D3}", "Ocirc": "\u{D4}", "Ograve": "\u{D2}",
    "Omega": "\u{3A9}", "Omicron": "\u{39F}", "Oslash": "\u{D8}", "Otilde": "\u{D5}", "Ouml": "\u{D6}",
    "Phi": "\u{3A6}", "Pi": "\u{3A0}", "Prime": "\u{2033}", "Psi": "\u{3A8}", "Rho": "\u{3A1}",
    "Scaron": "\u{160}", "Sigma": "\u{3A3}", "THORN": "\u{DE}", "Tau": "\u{3A4}", "Theta": "\u{398}",
    "Uacute": "\u{DA}", "Ucirc": "\u{DB}", "Ugrave": "\u{D9}", "Upsilon": "\u{3A5}", "Uuml": "\u{DC}",
    "Xi": "\u{39E}", "Yacute": "\u{DD}", "Yuml": "\u{178}", "Zeta": "\u{396}", "aacute": "\u{E1}",
    "acirc": "\u{E2}", "acute": "\u{B4}", "aelig": "\u{E6}", "agrave": "\u{E0}", "alefsym": "\u{2135}",
    "alpha": "\u{3B1}", "amp": "&", "and": "\u{2227}", "ang": "\u{2220}", "aring": "\u{E5}", "asymp": "\u{2248}",
    "atilde": "\u{E3}", "auml": "\u{E4}", "bdquo": "\u{201E}", "beta": "\u{3B2}", "brvbar": "\u{A6}",
    "bull": "\u{2022}", "cap": "\u{2229}", "ccedil": "\u{E7}", "cedil": "\u{B8}", "cent": "\u{A2}",
    "chi": "\u{3C7}", "circ": "\u{2C6}", "clubs": "\u{2663}", "cong": "\u{2245}", "copy": "\u{A9}",
    "crarr": "\u{21B5}", "cup": "\u{222A}", "curren": "\u{A4}", "dArr": "\u{21D3}", "dagger": "\u{2020}",
    "darr": "\u{2193}", "deg": "\u{B0}", "delta": "\u{3B4}", "diams": "\u{2666}", "divide": "\u{F7}",
    "eacute": "\u{E9}", "ecirc": "\u{EA}", "egrave": "\u{E8}", "empty": "\u{2205}", "emsp": "\u{2003}",
    "ensp": "\u{2002}", "epsilon": "\u{3B5}", "equiv": "\u{2261}", "eta": "\u{3B7}", "eth": "\u{F0}",
    "euml": "\u{EB}", "euro": "\u{20AC}", "exist": "\u{2203}", "fnof": "\u{192}", "forall": "\u{2200}",
    "frac12": "\u{BD}", "frac14": "\u{BC}", "frac34": "\u{BE}", "frasl": "\u{2044}", "gamma": "\u{3B3}",
    "ge": "\u{2265}", "gt": ">", "hArr": "\u{21D4}", "harr": "\u{2194}", "hearts": "\u{2665}",
    "hellip": "\u{2026}", "iacute": "\u{ED}", "icirc": "\u{EE}", "iexcl": "\u{A1}", "igrave": "\u{EC}",
    "image": "\u{2111}", "infin": "\u{221E}", "int": "\u{222B}", "iota": "\u{3B9}", "iquest": "\u{BF}",
    "isin": "\u{2208}", "iuml": "\u{EF}", "kappa": "\u{3BA}", "lArr": "\u{21D0}", "lambda": "\u{3BB}",
    "lang": "\u{2329}", "laquo": "\u{AB}", "larr": "\u{2190}", "lceil": "\u{2308}", "ldquo": "\u{201C}",
    "le": "\u{2264}", "lfloor": "\u{230A}", "lowast": "\u{2217}", "loz": "\u{25CA}", "lrm": "\u{200E}",
    "lsaquo": "\u{2039}", "lsquo": "\u{2018}", "lt": "<", "macr": "\u{AF}", "mdash": "\u{2014}", "micro": "\u{B5}",
    "middot": "\u{B7}", "minus": "\u{2212}", "mu": "\u{3BC}", "nabla": "\u{2207}", "nbsp": "\u{A0}",
    "ndash": "\u{2013}", "ne": "\u{2260}", "ni": "\u{220B}", "not": "\u{AC}", "notin": "\u{2209}",
    "nsub": "\u{2284}", "ntilde": "\u{F1}", "nu": "\u{3BD}", "oacute": "\u{F3}", "ocirc": "\u{F4}",
    "oelig": "\u{153}", "ograve": "\u{F2}", "oline": "\u{203E}", "omega": "\u{3C9}", "omicron": "\u{3BF}",
    "oplus": "\u{2295}", "or": "\u{2228}", "ordf": "\u{AA}", "ordm": "\u{BA}", "oslash": "\u{F8}",
    "otilde": "\u{F5}", "otimes": "\u{2297}", "ouml": "\u{F6}", "para": "\u{B6}", "part": "\u{2202}",
    "permil": "\u{2030}", "perp": "\u{22A5}", "phi": "\u{3C6}", "pi": "\u{3C0}", "piv": "\u{3D6}",
    "plusmn": "\u{B1}", "pound": "\u{A3}", "prime": "\u{2032}", "prod": "\u{220F}", "prop": "\u{221D}",
    "psi": "\u{3C8}", "quot": "\"", "rArr": "\u{21D2}", "radic": "\u{221A}", "rang": "\u{232A}", "raquo": "\u{BB}",
    "rarr": "\u{2192}", "rceil": "\u{2309}", "rdquo": "\u{201D}", "real": "\u{211C}", "reg": "\u{AE}",
    "rfloor": "\u{230B}", "rho": "\u{3C1}", "rlm": "\u{200F}", "rsaquo": "\u{203A}", "rsquo": "\u{2019}",
    "sbquo": "\u{201A}", "scaron": "\u{161}", "sdot": "\u{22C5}", "sect": "\u{A7}", "shy": "\u{AD}",
    "sigma": "\u{3C3}", "sigmaf": "\u{3C2}", "sim": "\u{223C}", "spades": "\u{2660}", "sub": "\u{2282}",
    "sube": "\u{2286}", "sum": "\u{2211}", "sup": "\u{2283}", "sup1": "\u{B9}", "sup2": "\u{B2}", "sup3": "\u{B3}",
    "supe": "\u{2287}", "szlig": "\u{DF}", "tau": "\u{3C4}", "there4": "\u{2234}", "theta": "\u{3B8}",
    "thetasym": "\u{3D1}", "thinsp": "\u{2009}", "thorn": "\u{FE}", "tilde": "\u{2DC}", "times": "\u{D7}",
    "trade": "\u{2122}", "uArr": "\u{21D1}", "uacute": "\u{FA}", "uarr": "\u{2191}", "ucirc": "\u{FB}",
    "ugrave": "\u{F9}", "uml": "\u{A8}", "upsih": "\u{3D2}", "upsilon": "\u{3C5}", "uuml": "\u{FC}",
    "weierp": "\u{2118}", "xi": "\u{3BE}", "yacute": "\u{FD}", "yen": "\u{A5}", "yuml": "\u{FF}",
    "zeta": "\u{3B6}", "zwj": "\u{200D}", "zwnj": "\u{200C}",
]

/// The names `html.unescape` also takes without a `;` -- `&amp chips` is
/// `& chips` -- and the longest of which it reads at the start of a name it
/// does not know: `&notit;` is `¬it;`.
private let legacyEntities: Set<String> = [
    "AElig", "AMP", "Aacute", "Acirc", "Agrave", "Aring", "Atilde", "Auml", "COPY", "Ccedil", "ETH", "Eacute",
    "Ecirc", "Egrave", "Euml", "GT", "Iacute", "Icirc", "Igrave", "Iuml", "LT", "Ntilde", "Oacute", "Ocirc",
    "Ograve", "Oslash", "Otilde", "Ouml", "QUOT", "REG", "THORN", "Uacute", "Ucirc", "Ugrave", "Uuml", "Yacute",
    "aacute", "acirc", "acute", "aelig", "agrave", "amp", "aring", "atilde", "auml", "brvbar", "ccedil", "cedil",
    "cent", "copy", "curren", "deg", "divide", "eacute", "ecirc", "egrave", "eth", "euml", "frac12", "frac14",
    "frac34", "gt", "iacute", "icirc", "iexcl", "igrave", "iquest", "iuml", "laquo", "lt", "macr", "micro",
    "middot", "nbsp", "not", "ntilde", "oacute", "ocirc", "ograve", "ordf", "ordm", "oslash", "otilde", "ouml",
    "para", "plusmn", "pound", "quot", "raquo", "reg", "sect", "shy", "sup1", "sup2", "sup3", "szlig", "thorn",
    "times", "uacute", "ucirc", "ugrave", "uml", "uuml", "yacute", "yen", "yuml",
]

/// Windows-1252 for the C1 references, as `html.unescape` reads them; the five
/// it leaves undefined stand for themselves.
private let windows1252: [UInt32: UInt32] = [
    0x81: 0x81, 0x8D: 0x8D, 0x8F: 0x8F, 0x90: 0x90, 0x9D: 0x9D,
    0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
    0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018,
    0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC,
    0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
]

/// A numeric reference as `html.unescape` decodes it.
private func numericEntity(_ value: UInt32) -> String {
    if value == 0 { return "\u{FFFD}" }
    if value == 0x0D { return "\r" }
    if let mapped = windows1252[value] { return String(Unicode.Scalar(mapped).map(Character.init) ?? "\u{FFFD}") }
    if (0xD800...0xDFFF).contains(value) || value > 0x10FFFF { return "\u{FFFD}" }
    let dropped = (0x1...0x8).contains(value) || (0xE...0x1F).contains(value) || (0x7F...0x9F).contains(value)
        || (0xFDD0...0xFDEF).contains(value) || value == 0xB || (value & 0xFFFE) == 0xFFFE
    if dropped { return "" }
    return Unicode.Scalar(value).map { String(Character($0)) } ?? "\u{FFFD}"
}

/// What ends a named reference's name.
private let referenceStops: Set<Unicode.Scalar> = ["\t", "\n", "\u{0C}", " ", "<", "&", "#", ";"]

private func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    let scalars = Array(text.unicodeScalars)
    var out = String.UnicodeScalarView()
    var index = 0
    while index < scalars.count {
        let scalar = scalars[index]
        guard scalar == "&" else {
            out.append(scalar)
            index += 1
            continue
        }
        var cursor = index + 1
        if cursor < scalars.count, scalars[cursor] == "#" {
            cursor += 1
            let hex = cursor < scalars.count && (scalars[cursor] == "x" || scalars[cursor] == "X")
            if hex { cursor += 1 }
            let start = cursor
            while cursor < scalars.count, hex ? scalars[cursor].properties.isASCIIHexDigit : ("0"..."9").contains(scalars[cursor]) {
                cursor += 1
            }
            if cursor > start {
                let digits = String(String.UnicodeScalarView(scalars[start..<cursor]))
                    .drop { $0 == "0" }
                // Anything past eight digits is past U+10FFFF in either base.
                let value = digits.isEmpty ? 0 : digits.count > 8 ? nil
                    : UInt64(digits, radix: hex ? 16 : 10).map { $0 > 0x10FFFF ? 0x110000 : UInt32($0) }
                if cursor < scalars.count, scalars[cursor] == ";" { cursor += 1 }
                out.append(contentsOf: numericEntity(value ?? 0x110000).unicodeScalars)
                index = cursor
                continue
            }
        } else {
            // `html.unescape`: up to 32 characters that are not white space,
            // `<`, `&`, `#` or `;`, then an optional `;`.
            let start = cursor
            while cursor < scalars.count, cursor - start < 32, !referenceStops.contains(scalars[cursor]) {
                cursor += 1
            }
            if cursor > start {
                let name = String(String.UnicodeScalarView(scalars[start..<cursor]))
                let terminated = cursor < scalars.count && scalars[cursor] == ";"
                if terminated, let decoded = namedEntities[name] {
                    out.append(contentsOf: decoded.unicodeScalars)
                    index = cursor + 1
                    continue
                }
                if !terminated, legacyEntities.contains(name), let decoded = namedEntities[name] {
                    out.append(contentsOf: decoded.unicodeScalars)
                    index = cursor
                    continue
                }
                // The longest legacy name the reference starts with, the rest
                // kept as written.
                let characters = Array(name.unicodeScalars)
                var length = characters.count - (terminated ? 0 : 1)
                var matched = false
                while length >= 2 {
                    let prefix = String(String.UnicodeScalarView(characters[0..<length]))
                    if legacyEntities.contains(prefix), let decoded = namedEntities[prefix] {
                        out.append(contentsOf: decoded.unicodeScalars)
                        index = start + length
                        matched = true
                        break
                    }
                    length -= 1
                }
                if matched { continue }
            }
        }
        out.append(scalar)
        index += 1
    }
    return String(out)
}
