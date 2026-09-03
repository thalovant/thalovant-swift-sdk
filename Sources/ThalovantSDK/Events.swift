import Foundation

public enum ThalovantEvents {
    public static let recognizerLoopUtterance = "recognizer_loop:utterance"
    public static let speak = "speak"
    public static let ovosUtteranceSpeak = "ovos.utterance.speak"
    public static let utteranceHandled = "ovos.utterance.handled"
    /// Legacy Mycroft name for the no-intent-matched failure. Retained for
    /// backwards compatibility with older hubs.
    public static let intentFailure = "complete_intent_failure"
    /// Current OVOS name for the no-intent-matched failure. OVOS renamed the
    /// bus event from `complete_intent_failure`; without this an unmatched
    /// utterance is never terminal and `ask` waits out its full timeout (#22).
    public static let intentUnmatched = "ovos.intent.unmatched"
    public static let policyDenied = "hive.policy.denied"
    public static let queryTimeout = "hive.query.timeout"

    public static let failureEvents: Set<String> = [
        intentFailure,
        intentUnmatched,
        policyDenied,
        queryTimeout,
    ]
}

/// A bus event emitted by the hub (`{type, data, context}` payloads on
/// `msg_type: "bus"` frames).
public struct ThalovantEvent: Equatable, Sendable {
    public let name: String
    public let data: JSONObject
    public let context: JSONObject

    public init(name: String, data: JSONObject = [:], context: JSONObject = [:]) {
        self.name = name
        self.data = data
        self.context = context
    }

    /// Builds an event from a bus payload, or `nil` when the payload has no `type`.
    public static func fromBusPayload(_ payload: JSONObject) -> ThalovantEvent? {
        guard let type = payload["type"]?.stringValue else { return nil }
        return ThalovantEvent(
            name: type,
            data: payload["data"]?.objectValue ?? [:],
            context: payload["context"]?.objectValue ?? [:]
        )
    }

    public var text: String {
        if let direct = data["utterance"]?.stringValue ?? data["text"]?.stringValue {
            return direct
        }
        return utterances.first ?? ""
    }

    public var utterances: [String] {
        if let single = data["utterances"]?.stringValue {
            return [single]
        }
        if let list = data["utterances"]?.arrayValue {
            return list.compactMap { $0.stringValue }
        }
        if let utterance = data["utterance"]?.stringValue {
            return [utterance]
        }
        return []
    }

    public var displayText: String {
        stripSsml(text)
    }

    public var sessionId: String? {
        sessionIdFromContext(context)
    }

    public var requestId: String? {
        requestIdFromContext(context) ?? requestIdFromMapping(data)
    }

    public var isFailure: Bool {
        ThalovantEvents.failureEvents.contains(name)
    }

    public func asJSON() -> JSONObject {
        [
            "name": .string(name),
            "data": .object(data),
            "context": .object(context),
            "text": .string(text),
            "display_text": .string(displayText),
            "session_id": sessionId.map { .string($0) } ?? .null,
            "request_id": requestId.map { .string($0) } ?? .null,
        ]
    }
}

/// The aggregated reply produced by `ThalovantClient.ask`.
public struct ThalovantReply: Sendable {
    public let text: String
    public let displayText: String
    public let utterances: [String]
    public let handled: Bool
    public let ok: Bool
    public let sessionId: String?
    public let requestId: String?
    public let events: [ThalovantEvent]
    public let failureEvent: ThalovantEvent?
}

public func newSessionId() -> String {
    "thalovant-session-" + compactUUID()
}

public func newRequestId() -> String {
    "thalovant-request-" + compactUUID()
}

func compactUUID() -> String {
    UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
}

/// Removes SSML/XML tags, mirroring the sibling SDKs.
public func stripSsml(_ text: String) -> String {
    var result = ""
    var insideTag = false
    for character in text {
        if character == "<" {
            insideTag = true
        } else if character == ">" {
            insideTag = false
        } else if !insideTag {
            result.append(character)
        }
    }
    return result
}

public func utterancePayload(text: String, lang: String) -> JSONObject {
    ["utterances": .array([.string(text)]), "lang": .string(lang)]
}

/// Merges correlation identifiers into an event context, matching the
/// structure produced by the sibling SDKs (`request_id`,
/// `thalovant_request_id`, and a `session` block).
public func contextWithCorrelation(
    _ context: JSONObject,
    sessionId: String? = nil,
    siteId: String? = nil,
    lang: String? = nil,
    requestId: String? = nil
) -> JSONObject {
    var next = context
    var session = next["session"]?.objectValue ?? [:]
    if let sessionId {
        session["session_id"] = .string(sessionId)
    }
    if let siteId, session["site_id"] == nil {
        session["site_id"] = .string(siteId)
    }
    if let lang, session["lang"] == nil {
        session["lang"] = .string(lang)
    }
    if let requestId {
        next["request_id"] = .string(requestId)
        next["thalovant_request_id"] = .string(requestId)
        session["request_id"] = .string(requestId)
    }
    if !session.isEmpty {
        next["session"] = .object(session)
    }
    return next
}

func sessionIdFromContext(_ context: JSONObject) -> String? {
    if let value = context["session"]?["session_id"], !value.isNull {
        return coerceIdentifier(value)
    }
    if let value = context["session_id"], !value.isNull {
        return coerceIdentifier(value)
    }
    return nil
}

func requestIdFromContext(_ context: JSONObject) -> String? {
    if let id = requestIdFromMapping(context) {
        return id
    }
    if let session = context["session"]?.objectValue {
        return requestIdFromMapping(session)
    }
    return nil
}

func requestIdFromMapping(_ mapping: JSONObject) -> String? {
    for key in ["request_id", "thalovant_request_id", "correlation_id"] {
        if let value = mapping[key], !value.isNull, let id = coerceIdentifier(value) {
            return id
        }
    }
    return nil
}

private func coerceIdentifier(_ value: JSONValue) -> String? {
    switch value {
    case .string(let text): return text
    case .integer(let number): return String(number)
    case .number(let number): return String(number)
    default: return nil
    }
}

/// True when a reply's session id is the one we asked for.
///
/// A hub rewrites a client-declared session id before the orchestrator sees it:
/// hivemind-core derives a Layer-1 identity as `{conn_nonce}:{declared}` so two
/// clients cannot collide on the same declared name (HIVEMIND-BRIDGE-1 §4), and
/// only admin connections are exempt. Replies can therefore carry either form,
/// and comparing for equality rejected every one of them — `ask()` timed out
/// while the hub had already answered and emitted `ovos.utterance.handled`.
///
/// Matching the part after the first `:` mirrors what the hub does on the way
/// out. Deliberately not a bare `hasSuffix`: a declared id of "b" must not
/// match a reply for "a:xb".
public func sessionIdsMatch(expected: String, actual: String) -> Bool {
    if actual == expected { return true }
    guard let separator = actual.firstIndex(of: ":") else { return false }
    return String(actual[actual.index(after: separator)...]) == expected
}
