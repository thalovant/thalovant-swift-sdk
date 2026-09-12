import Foundation

// What a hub can be asked: the intent inventory, over the client's own session.
//
// The hub runtime keeps an intent manifest (OVOS-INTENT-4 section 10): every
// intent a skill registered, per language, and on request the registration
// itself, which for a template intent carries the sentences from the skill's
// locale files, slots and all -- `what is the weather in {location}`. This file
// asks that manifest and shapes the answer, so an app shows a person what they
// can say without a control-plane token.
//
// Two queries, correlated by `context.request_id` like every other request:
//
// - `ovos.intent.list` `{"lang": <tag>}` -> `ovos.intent.list.response`
//   `{"ok", "intents": [{skill_id, intent_name, lang, method, enabled,
//   session_id}]}`. `method` is `template` (sample sentences) or `keyword`
//   (keyword sets). A runtime may attach each entry's `definition` when asked
//   with `include_definitions`; when it does not, the client describes each
//   intent individually. `{"ok": false}` here is a failed query, not an empty
//   hub, and throws `ThalovantRuntimeError`.
// - `ovos.intent.describe` `{"skill_id", "intent_name", "lang"}` ->
//   `ovos.intent.describe.response` `{"ok", "definitions": [{method,
//   definition}]}` or `{"ok": false, "error"}`.
//
// A hub whose connection may not publish a type answers `hive.policy.denied`
// naming it; that becomes `ThalovantPolicyDeniedError` at once rather than a
// timeout. The engines' own manifests (`intent.service.adapt.manifest.get` and
// `intent.service.padatious.manifest.get`, names only, no language) are the
// fallback for a hub allowed for those alone.

/// The language the intent queries ask about when the caller names none.
let defaultIntentLanguage = "en-us"

/// How many describes may be in flight at once. A hub with 69 intents in two
/// languages is 138 requests and, with every reply delivered twice, 276 inbound
/// events; an SDK whose reply queue is bounded drops replies past its capacity
/// and the inventory comes back missing sentences. Batching also spares the hub
/// a burst it never asked for.
public let defaultDescribeBatchSize = 32

// MARK: - Options

/// Options for `ThalovantClient.intents`.
public struct IntentInventoryOptions: Sendable {
    /// Deadline, in seconds, for each listing and for the describe batch as a whole.
    public var timeout: TimeInterval
    /// Ask for the sentences behind each intent. Off, the inventory carries
    /// names and engines only.
    public var describe: Bool
    /// When the hub refuses `ovos.intent.list`, fall back to the engines' own
    /// manifests and return names only, marked `source: .engineManifests`.
    public var fallback: Bool

    public init(timeout: TimeInterval = 5, describe: Bool = true, fallback: Bool = true) {
        self.timeout = timeout
        self.describe = describe
        self.fallback = fallback
    }
}

/// Options for `ThalovantClient.listIntents`.
public struct ListIntentsOptions: Sendable {
    /// Deadline, in seconds, for the reply.
    public var timeout: TimeInterval
    /// Send `include_definitions: true`, so a runtime that honours it attaches
    /// each row's `definition`.
    public var includeDefinitions: Bool

    public init(timeout: TimeInterval = 5, includeDefinitions: Bool = false) {
        self.timeout = timeout
        self.includeDefinitions = includeDefinitions
    }
}

/// Options for `ThalovantClient.describeIntent`.
public struct DescribeIntentOptions: Sendable {
    /// Deadline, in seconds, for the reply.
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }
}

// MARK: - Language tags and engines

/// `fr-fr` and `fr_FR` are the same language tag.
public func sameLanguage(_ a: String, _ b: String) -> Bool {
    normalizedLanguageTag(a) == normalizedLanguageTag(b)
}

func normalizedLanguageTag(_ tag: String) -> String {
    tag.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "_", with: "-")
}

/// The engine behind a manifest `method`: `template` is padatious, `keyword`
/// is adapt; anything else is reported as the runtime named it.
func intentEngine(forMethod method: String) -> String {
    switch method {
    case "template": return "padatious"
    case "keyword": return "adapt"
    default: return method.isEmpty ? "unknown" : method
    }
}

/// The sample sentences of a template definition, as the skill's locale files
/// wrote them, blank ones dropped.
func intentSamples(from definition: JSONObject) -> [String] {
    (definition["samples"]?.arrayValue ?? [])
        .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// How an inventory was read.
public enum HubIntentSource: String, Codable, Equatable, Sendable {
    /// The runtime's intent manifest: sentences per language.
    case intentManifest = "intent-manifest"
    /// The engines' own manifests: names only, the fallback for a hub that
    /// refuses `ovos.intent.list`.
    case engineManifests = "engine-manifests"
}

// MARK: - Wire rows

/// One row of the hub's intent manifest (`ovos.intent.list.response`).
public struct IntentRegistration: Codable, Equatable, Sendable {
    public let skillId: String
    public let intentName: String
    public let lang: String
    /// `template` (sample sentences) or `keyword` (keyword sets).
    public let method: String
    public let enabled: Bool
    public let sessionId: String
    /// The registration itself, when the runtime attached it to the listing
    /// (`include_definitions`).
    public let definition: JSONObject?

    enum CodingKeys: String, CodingKey {
        case skillId = "skill_id"
        case intentName = "intent_name"
        case lang
        case method
        case enabled
        case sessionId = "session_id"
        case definition
    }

    public init(
        skillId: String,
        intentName: String,
        lang: String = "",
        method: String = "",
        enabled: Bool = true,
        sessionId: String = "default",
        definition: JSONObject? = nil
    ) {
        self.skillId = skillId
        self.intentName = intentName
        self.lang = lang
        self.method = method
        self.enabled = enabled
        self.sessionId = sessionId
        self.definition = definition
    }

    /// `padatious` for a template registration, `adapt` for a keyword one.
    public var engine: String { intentEngine(forMethod: method) }

    /// Parses one manifest row; `nil` when it names no skill or no intent.
    /// A missing `enabled` is true, a missing `session_id` is `default`.
    public static func fromJSON(_ raw: JSONObject) -> IntentRegistration? {
        let skillId = raw["skill_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let intentName = raw["intent_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !skillId.isEmpty, !intentName.isEmpty else { return nil }
        let sessionId = raw["session_id"]?.stringValue ?? ""
        return IntentRegistration(
            skillId: skillId,
            intentName: intentName,
            lang: raw["lang"]?.stringValue ?? "",
            method: raw["method"]?.stringValue ?? "",
            enabled: raw["enabled"]?.boolValue != false,
            sessionId: sessionId.isEmpty ? "default" : sessionId,
            definition: raw["definition"]?.objectValue
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let object = try container.decode(JSONObject.self)
        guard let parsed = IntentRegistration.fromJSON(object) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "An intent registration needs a skill_id and an intent_name."
            )
        }
        self = parsed
    }
}

/// A registration as the skill made it, from `ovos.intent.describe`.
public struct IntentDefinition: Codable, Equatable, Sendable {
    public let skillId: String
    public let intentName: String
    public let lang: String
    /// `template` (sample sentences) or `keyword` (keyword sets).
    public let method: String
    /// A template definition's sentences, slots in braces.
    public let samples: [String]
    /// The definition exactly as the hub sent it.
    public let raw: JSONObject

    enum CodingKeys: String, CodingKey {
        case skillId = "skill_id"
        case intentName = "intent_name"
        case lang
        case method
        case samples
        case raw
    }

    public init(
        skillId: String,
        intentName: String,
        lang: String = "",
        method: String = "",
        samples: [String] = [],
        raw: JSONObject = [:]
    ) {
        self.skillId = skillId
        self.intentName = intentName
        self.lang = lang
        self.method = method
        self.samples = samples
        self.raw = raw
    }

    /// `padatious` for a template definition, `adapt` for a keyword one.
    public var engine: String { intentEngine(forMethod: method) }

    /// Parses one `{method, definition}` entry of a describe reply's
    /// `definitions`; `nil` when the definition names no skill or no intent.
    public static func fromDescribeItem(_ item: JSONObject) -> IntentDefinition? {
        guard let definition = item["definition"]?.objectValue else { return nil }
        let skillId = definition["skill_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let intentName = definition["intent_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !skillId.isEmpty, !intentName.isEmpty else { return nil }
        return IntentDefinition(
            skillId: skillId,
            intentName: intentName,
            lang: definition["lang"]?.stringValue ?? "",
            method: item["method"]?.stringValue ?? definition["method"]?.stringValue ?? "",
            samples: intentSamples(from: definition),
            raw: definition
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.skillId = try container.decode(String.self, forKey: .skillId)
        self.intentName = try container.decode(String.self, forKey: .intentName)
        self.lang = try container.decodeIfPresent(String.self, forKey: .lang) ?? ""
        self.method = try container.decodeIfPresent(String.self, forKey: .method) ?? ""
        self.samples = try container.decodeIfPresent([String].self, forKey: .samples) ?? []
        self.raw = try container.decodeIfPresent(JSONObject.self, forKey: .raw) ?? [:]
    }
}

// MARK: - The inventory

/// One thing a hub can be asked, with the sentences that ask it, per language.
public struct HubIntent: Codable, Equatable, Sendable {
    /// `<skill_id>:<name>`.
    public let id: String
    public let skillId: String
    public let name: String
    /// `padatious`, `adapt`, or the method as the runtime named it.
    public let engine: String
    public let enabled: Bool
    /// The sentences that reach this intent, keyed by language tag as the
    /// inventory asked for it. An intent listed for a language with no
    /// sentences has an empty entry.
    public let phrases: [String: [String]]
    /// The languages this intent was listed in, in the order asked.
    public let languages: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case skillId = "skill_id"
        case name
        case engine
        case enabled
        case phrases
        case languages
    }

    public init(
        skillId: String,
        name: String,
        engine: String,
        phrases: [String: [String]] = [:],
        languages: [String]? = nil,
        enabled: Bool = true
    ) {
        self.id = "\(skillId):\(name)"
        self.skillId = skillId
        self.name = name
        self.engine = engine
        self.enabled = enabled
        self.phrases = phrases
        self.languages = languages ?? phrases.keys.sorted()
    }

    /// The sentences for one language, matched case-insensitively with `_`
    /// and `-` folded (`fr-FR` finds `fr-fr`). Empty when the intent was not
    /// listed for that language.
    public func phrasesFor(_ lang: String) -> [String] {
        var candidates = languages
        for key in phrases.keys.sorted() where !candidates.contains(key) {
            candidates.append(key)
        }
        for candidate in candidates where sameLanguage(candidate, lang) {
            return phrases[candidate] ?? []
        }
        return []
    }

    /// A few sentences worth showing: whole ones before ones with a slot,
    /// shorter ones first. `lang` defaults to the first language listed;
    /// a `limit` of zero or less returns them all in their original order.
    public func examples(lang: String? = nil, limit: Int = 2, speakable render: Bool = false, slots: [String: String] = [:]) -> [String] {
        var pool: [String]
        if let lang {
            pool = phrasesFor(lang)
        } else {
            pool = languages.first.map { phrasesFor($0) } ?? []
        }
        var ranks: [String: Bool] = [:]
        if render {
            var rendered: [String] = []
            for pattern in pool {
                let sentence = speakable(pattern, slots: slots)
                guard !sentence.isEmpty else { continue }
                if ranks[sentence] == nil { rendered.append(sentence) }
                ranks[sentence] = (ranks[sentence] ?? true) && pattern.contains("{")
            }
            pool = rendered
        }
        guard limit > 0 else { return pool }
        let ranked = pool.enumerated().sorted { a, b in
            let aSlot = (ranks[a.element] ?? a.element.contains("{"))
            let bSlot = (ranks[b.element] ?? b.element.contains("{"))
            if aSlot != bSlot { return !aSlot }
            let aLength = a.element.unicodeScalars.count
            let bLength = b.element.unicodeScalars.count
            if aLength != bLength { return aLength < bLength }
            return a.offset < b.offset
        }
        return ranked.prefix(limit).map { $0.element }
    }

    public func asJSON() -> JSONObject {
        encodedJSONObject(self)
    }

    /// Parses an intent as `asJSON()` wrote it; `nil` when it has no `name`.
    public static func fromJSON(_ raw: JSONObject) -> HubIntent? {
        guard let name = raw["name"]?.stringValue, !name.isEmpty else { return nil }
        let phrases = (raw["phrases"]?.objectValue ?? [:]).compactMapValues { value -> [String]? in
            value.arrayValue?.compactMap { $0.stringValue }
        }
        let languages = raw["languages"]?.arrayValue?.compactMap { $0.stringValue }
        return HubIntent(
            skillId: raw["skill_id"]?.stringValue ?? "",
            name: name,
            engine: raw["engine"]?.stringValue ?? "unknown",
            phrases: phrases,
            languages: languages,
            enabled: raw["enabled"]?.boolValue != false
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let object = try container.decode(JSONObject.self)
        guard let parsed = HubIntent.fromJSON(object) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "A hub intent needs a name.")
        }
        self = parsed
    }
}

/// The intents one skill registered.
public struct HubSkillIntents: Codable, Equatable, Sendable {
    public let skillId: String
    public let intents: [HubIntent]
    /// Every language any of the skill's intents was listed in, first seen first.
    public let languages: [String]

    enum CodingKeys: String, CodingKey {
        case skillId = "skill_id"
        case intents
        case languages
    }

    public init(skillId: String, intents: [HubIntent]) {
        self.skillId = skillId
        self.intents = intents
        var seen: [String] = []
        for intent in intents {
            for lang in intent.languages where !seen.contains(lang) {
                seen.append(lang)
            }
        }
        self.languages = seen
    }

    public func asJSON() -> JSONObject {
        encodedJSONObject(self)
    }

    /// Parses a skill as `asJSON()` wrote it; `nil` when it has no `skill_id`.
    public static func fromJSON(_ raw: JSONObject) -> HubSkillIntents? {
        guard let skillId = raw["skill_id"]?.stringValue else { return nil }
        let intents = (raw["intents"]?.arrayValue ?? []).compactMap { $0.objectValue.flatMap(HubIntent.fromJSON) }
        return HubSkillIntents(skillId: skillId, intents: intents)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let object = try container.decode(JSONObject.self)
        guard let parsed = HubSkillIntents.fromJSON(object) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "A skill needs a skill_id.")
        }
        self = parsed
    }
}

/// One registered fallback handler, ordered by priority and then skill id.
public struct HubFallback: Codable, Equatable, Sendable {
    public let skillId: String
    public let priority: Int
    public init(skillId: String, priority: Int = 0) { self.skillId = skillId; self.priority = priority }
    enum CodingKeys: String, CodingKey { case skillId = "skill_id"; case priority }
    public func asJSON() -> JSONObject { encodedJSONObject(self) }
    static func fromJSON(_ raw: JSONObject) -> HubFallback? {
        guard let skill = raw["skill_id"]?.stringValue,
              !skill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let priority: Int
        switch raw["priority"] {
        case .integer(let value): priority = value
        case .bool(let value): priority = value ? 1 : 0
        case .number(let value):
            guard value.isFinite, value >= Double(Int.min), value < Double(Int.max) else { return nil }
            priority = Int(value)
        default: priority = 0
        }
        return HubFallback(skillId: skill, priority: priority)
    }
}

/// Everything a hub can be asked, grouped by skill.
///
/// `source` says how it was read: `.intentManifest` carries sentences per
/// language; `.engineManifests` is the names-only fallback, and `denied` then
/// names the query that triggered fallback. Silence uses the same marker and
/// is not proof of a policy denial.
public struct HubIntentInventory: Codable, Equatable, Sendable {
    /// The languages asked for, in the order asked: trimmed, one entry per
    /// language whatever its spellings (`en-us`, `en-US`, `en_us`), the first
    /// spelling kept.
    public let languages: [String]
    /// Skills sorted by id, each with its intents sorted by name.
    public let skills: [HubSkillIntents]
    public let source: HubIntentSource
    /// The queries the hub refused on the way to this result.
    public let denied: [String]
    public let fallbacks: [HubFallback]
    public let fallbacksKnown: Bool

    enum CodingKeys: String, CodingKey {
        case languages
        case skills
        case source
        case denied
        case fallbacks
        case fallbacksKnown = "fallbacks_known"
    }

    public init(
        languages: [String],
        skills: [HubSkillIntents],
        source: HubIntentSource = .intentManifest,
        denied: [String] = [],
        fallbacks: [HubFallback] = [],
        fallbacksKnown: Bool = false
    ) {
        self.languages = languages
        self.skills = skills
        self.source = source
        self.denied = denied
        self.fallbacks = fallbacks
        self.fallbacksKnown = fallbacksKnown
    }

    /// Every intent of every skill, in `skills` order.
    public var intents: [HubIntent] {
        skills.flatMap { $0.intents }
    }

    /// True when at least one intent carries at least one sentence. False for
    /// the names-only `.engineManifests` fallback, and for a manifest-path
    /// inventory whose describes all came back empty.
    public var hasPhrases: Bool {
        intents.contains { intent in intent.phrases.values.contains { !$0.isEmpty } }
    }

    /// Unknown fallback discovery cannot rule out a handler answering another language.
    public func mayAnswer(_ lang: String) -> Bool {
        intents.contains { $0.enabled && !$0.phrasesFor(lang).isEmpty } || !fallbacks.isEmpty || !fallbacksKnown
    }

    public func asJSON() -> JSONObject {
        encodedJSONObject(self)
    }

    /// Parses an inventory as `asJSON()` wrote it.
    public static func fromJSON(_ raw: JSONObject) -> HubIntentInventory {
        HubIntentInventory(
            languages: raw["languages"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            skills: (raw["skills"]?.arrayValue ?? []).compactMap { $0.objectValue.flatMap(HubSkillIntents.fromJSON) },
            source: raw["source"]?.stringValue.flatMap(HubIntentSource.init(rawValue:)) ?? .intentManifest,
            denied: raw["denied"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            fallbacks: (raw["fallbacks"]?.arrayValue ?? []).compactMap { $0.objectValue.flatMap(HubFallback.fromJSON) },
            fallbacksKnown: raw["fallbacks_known"]?.boolValue ?? false
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = HubIntentInventory.fromJSON(try container.decode(JSONObject.self))
    }
}

/// The `JSONObject` form of an encodable model, keyed as its `CodingKeys` name
/// the fields. These models encode a handful of strings and lists, so the
/// only way this comes back empty is an encoder failure that cannot happen.
func encodedJSONObject<T: Encodable>(_ value: T) -> JSONObject {
    guard let data = try? JSONEncoder().encode(value), let object = try? ThalovantJSON.decodeObject(data) else {
        return [:]
    }
    return object
}

// MARK: - The wire

/// One registration to describe: a row of the manifest, in one language.
struct IntentRequestKey: Hashable, Sendable {
    let skillId: String
    let intentName: String
    let lang: String
}

/// Keeps the first reply to a request; repeats are dropped.
final class FirstReply: @unchecked Sendable {
    private let lock = NSLock()
    private var event: ThalovantEvent?

    /// Stores `candidate` unless a reply is already held; true when it was stored.
    func keep(_ candidate: ThalovantEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard event == nil else { return false }
        event = candidate
        return true
    }

    var value: ThalovantEvent? {
        lock.lock()
        defer { lock.unlock() }
        return event
    }
}

/// Collects the replies of a describe batch, one per registration, and opens
/// its gate once every registration has been answered.
final class DescribeBatch: @unchecked Sendable {
    let gate = AsyncGate()
    private let lock = NSLock()
    private let expected: Int
    private var found: [IntentRequestKey: [IntentDefinition]] = [:]

    init(expected: Int) {
        self.expected = expected
    }

    /// Records the first answer for `key`; later ones for the same key are repeats.
    func record(_ key: IntentRequestKey, _ definitions: [IntentDefinition]) {
        lock.lock()
        guard found[key] == nil else {
            lock.unlock()
            return
        }
        found[key] = definitions
        let complete = found.count >= expected
        lock.unlock()
        if complete {
            gate.open()
        }
    }

    var hasDefinitions: Bool {
        lock.lock()
        defer { lock.unlock() }
        return found.values.contains { !$0.isEmpty }
    }

    func snapshot() -> [IntentRequestKey: [IntentDefinition]] {
        lock.lock()
        defer { lock.unlock() }
        return found
    }
}

/// The definitions a describe reply carries.
///
/// `{"ok": false}` yields none, which is a real answer: the hub does not know
/// that registration, so the intent simply has no sentences. A listing that
/// answers `ok: false` is the other case and throws, because a failed query
/// has told us nothing.
func intentDefinitions(from event: ThalovantEvent) -> [IntentDefinition] {
    if event.data["ok"]?.boolValue == false { return [] }
    return (event.data["definitions"]?.arrayValue ?? [])
        .compactMap { $0.objectValue.flatMap(IntentDefinition.fromDescribeItem) }
}

/// True when a `hive.policy.denied` event refuses `queryType`.
func isPolicyDenial(_ event: ThalovantEvent, of queryType: String) -> Bool {
    event.data["denied_type"]?.stringValue == queryType
}

/// `5` for five seconds, `0.2` for a fifth of one: the deadline as a person wrote it.
func secondsText(_ seconds: TimeInterval) -> String {
    seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
}

/// Deduplicates, keeping the first occurrence of each element in place.
func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    return values.filter { seen.insert($0).inserted }
}

/// `<skill_id>:<intent_name>` split at the first colon; a bare name has no skill.
func splitIntentName(_ raw: String) -> (skillId: String, intentName: String) {
    guard let colon = raw.firstIndex(of: ":") else { return ("", raw) }
    let intentName = String(raw[raw.index(after: colon)...])
    guard !intentName.isEmpty else { return ("", raw) }
    return (String(raw[..<colon]), intentName)
}

extension ThalovantClient {
    /// Sends one bus query and returns its reply, matched by request id.
    ///
    /// A reply may arrive more than once; the first one wins and repeats are
    /// dropped. A `hive.policy.denied` naming the query throws
    /// `ThalovantPolicyDeniedError` at once; no reply by `timeout` throws
    /// `ThalovantTimeoutError`.
    func requestReply(
        queryType: String,
        replyType: String,
        data: JSONObject,
        lang: String? = nil,
        timeout: TimeInterval
    ) async throws -> ThalovantEvent {
        let requestId = newRequestId()
        var context: JSONObject = ["request_id": .string(requestId)]
        if let lang, !lang.isEmpty {
            context["lang"] = .string(lang)
        }
        let gate = AsyncGate()
        let answer = FirstReply()

        try await connect()
        let denials = on(ThalovantEvents.policyDenied, requestId: requestId) { event in
            if isPolicyDenial(event, of: queryType) {
                gate.fail(ThalovantPolicyDeniedError.fromEvent(event))
            }
        }
        defer { denials.close() }
        let replies = on(replyType, requestId: requestId) { event in
            if answer.keep(event) {
                gate.open()
            }
        }
        defer { replies.close() }

        try await emit(queryType, data: data, context: context)
        let deadline = ThalovantTimeoutError("Hub did not answer \(queryType) within \(secondsText(timeout))s.")
        try await gate.wait(timeout: timeout, timeoutError: deadline)
        guard let event = answer.value else { throw deadline }
        return event
    }

    /// The hub's intent manifest for one language (`ovos.intent.list`).
    func listIntentRegistrations(lang: String, options: ListIntentsOptions) async throws -> [IntentRegistration] {
        var data: JSONObject = ["lang": .string(lang)]
        if options.includeDefinitions {
            data["include_definitions"] = .bool(true)
        }
        let event = try await requestReply(
            queryType: ThalovantEvents.intentList,
            replyType: ThalovantEvents.intentListResponse,
            data: data,
            lang: lang,
            timeout: options.timeout
        )
        if event.data["ok"]?.boolValue == false {
            // A refused listing is not an empty hub. Describe answers
            // `ok: false` for an intent it does not know, which is a real
            // answer; a listing that fails has told us nothing, and reporting
            // it as no intents would show a person an empty hub.
            let error = event.data["error"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = error.isEmpty ? "the hub refused the listing" : error
            throw ThalovantRuntimeError("\(ThalovantEvents.intentList) failed: \(detail)")
        }
        return (event.data["intents"]?.arrayValue ?? [])
            .compactMap { $0.objectValue.flatMap(IntentRegistration.fromJSON) }
    }

    /// Every registration behind one intent in one language
    /// (`ovos.intent.describe`), keyword ones first as the runtime lists them.
    func describeIntentDefinitions(
        skillId: String,
        intentName: String,
        lang: String,
        options: DescribeIntentOptions
    ) async throws -> [IntentDefinition] {
        let event = try await requestReply(
            queryType: ThalovantEvents.intentDescribe,
            replyType: ThalovantEvents.intentDescribeResponse,
            data: [
                "skill_id": .string(skillId),
                "intent_name": .string(intentName),
                "lang": .string(lang),
            ],
            lang: lang,
            timeout: options.timeout
        )
        return intentDefinitions(from: event)
    }

    /// Describes many registrations, at most `batchSize` of them in flight.
    ///
    /// One subscription window per batch, one request id per registration,
    /// replies matched by that id -- or, for a hub that does not echo it, by
    /// the definition's own `skill_id`/`intent_name`/`lang` -- and repeats
    /// dropped. The deadline covers each batch, so a hub that answers nothing
    /// fails after one batch rather than holding every request open. A window
    /// that answered nothing contributes nothing; the call fails only when no
    /// window produced anything. `batchSize: 0` sends them all at once.
    func describeIntentBatch(
        _ wanted: [IntentRequestKey],
        timeout: TimeInterval,
        batchSize: Int = defaultDescribeBatchSize
    ) async throws -> [IntentRequestKey: [IntentDefinition]] {
        let unique = orderedUnique(wanted)
        guard !unique.isEmpty else { return [:] }
        guard batchSize > 0, unique.count > batchSize else {
            return try await describeIntentWindow(unique, timeout: timeout)
        }
        var found: [IntentRequestKey: [IntentDefinition]] = [:]
        for start in stride(from: 0, to: unique.count, by: batchSize) {
            let batch = Array(unique[start..<min(start + batchSize, unique.count)])
            do {
                for (key, definitions) in try await describeIntentWindow(batch, timeout: timeout) {
                    found[key] = definitions
                }
            } catch let error as ThalovantTimeoutError {
                // A partial answer is an answer, across windows as within one:
                // windows are contiguous slices, so an unresponsive skill with
                // more than one window's worth of intents would otherwise turn
                // the whole inventory into a timeout while the same skill with
                // fewer intents only loses its sentences. A hub silent from the
                // start still fails at the first window, unless usable definitions were found.
                if !found.values.contains(where: { !$0.isEmpty }) { throw error }
            }
        }
        return found
    }

    /// One batch: subscribe, send every request, wait for the replies, drop the
    /// subscription. A registration the hub did not describe within `timeout`
    /// is simply absent from the result; no answer at all is a timeout.
    private func describeIntentWindow(
        _ unique: [IntentRequestKey],
        timeout: TimeInterval
    ) async throws -> [IntentRequestKey: [IntentDefinition]] {
        var requests: [(id: String, key: IntentRequestKey)] = []
        var keysByRequest: [String: IntentRequestKey] = [:]
        for key in unique {
            let id = newRequestId()
            requests.append((id, key))
            keysByRequest[id] = key
        }
        let byRequest = keysByRequest
        let batch = DescribeBatch(expected: unique.count)

        try await connect()
        let denials = on(ThalovantEvents.policyDenied) { event in
            if (event.requestId == nil || byRequest[event.requestId!] != nil), isPolicyDenial(event, of: ThalovantEvents.intentDescribe) {
                batch.gate.fail(ThalovantPolicyDeniedError.fromEvent(event))
            }
        }
        defer { denials.close() }
        let replies = on(ThalovantEvents.intentDescribeResponse) { event in
            let definitions = intentDefinitions(from: event)
            var key = event.requestId.flatMap { byRequest[$0] }
            if event.requestId == nil, let first = definitions.first {
                // No request id came back: the definition names what it describes.
                key = unique.first {
                    $0.skillId == first.skillId && $0.intentName == first.intentName
                        && sameLanguage($0.lang, first.lang)
                }
            }
            guard let key else { return }
            batch.record(key, definitions)
        }
        defer { replies.close() }

        for request in requests {
            try await emit(
                ThalovantEvents.intentDescribe,
                data: [
                    "skill_id": .string(request.key.skillId),
                    "intent_name": .string(request.key.intentName),
                    "lang": .string(request.key.lang),
                ],
                context: ["request_id": .string(request.id), "lang": .string(request.key.lang)]
            )
        }
        do {
            try await batch.gate.wait(
                timeout: timeout,
                timeoutError: ThalovantTimeoutError(
                    "Hub did not answer \(ThalovantEvents.intentDescribe) within \(secondsText(timeout))s."
                )
            )
        } catch let error as ThalovantTimeoutError {
            if !batch.hasDefinitions { throw error }
            // A partial answer is still an answer: the intents the hub did not
            // describe in time simply carry no sentences.
        }
        return batch.snapshot()
    }

    /// The engines' own manifests, adapt then padatious: names of the form
    /// `<skill_id>:<intent_name>`, the same whatever the language asked,
    /// because an intent's name is the same in every language. The fallback
    /// for a hub allowed for these queries but not the intent manifest.
    func intentEngineManifests(lang: String, timeout: TimeInterval) async throws -> [(engine: String, names: [String])] {
        let engines: [(engine: String, query: String, reply: String)] = [
            ("adapt", ThalovantEvents.adaptManifestGet, ThalovantEvents.adaptManifest),
            ("padatious", ThalovantEvents.padatiousManifestGet, ThalovantEvents.padatiousManifest),
        ]
        var manifests: [(engine: String, names: [String])] = []
        for engine in engines {
            let event = try await requestReply(
                queryType: engine.query,
                replyType: engine.reply,
                data: ["lang": .string(lang)],
                lang: lang,
                timeout: timeout
            )
            let names = (event.data["intents"]?.arrayValue ?? [])
                .compactMap { $0.stringValue }
                .filter { !$0.isEmpty }
            manifests.append((engine.engine, names))
        }
        return manifests
    }

    /// Everything the hub can be asked, in each language, grouped by skill.
    ///
    /// Asks the intent manifest per language and, unless the runtime attached
    /// definitions to the listing, describes every registration at once. When
    /// the hub refuses `ovos.intent.list` and `options.fallback` is on, the
    /// engines' manifests give the names and the result says so.
    func intentInventory(languages: [String], options: IntentInventoryOptions) async throws -> HubIntentInventory {
        // `en-us`, `en-US` and `en_us` are one language, asked once; the first
        // spelling given is the one the inventory reports.
        var asked: [String] = []
        for language in languages {
            let tag = language.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty, !asked.contains(where: { sameLanguage($0, tag) }) {
                asked.append(tag)
            }
        }
        guard !asked.isEmpty else {
            throw ThalovantRuntimeError("intents() requires at least one language.")
        }

        var listed: [(lang: String, rows: [IntentRegistration])] = []
        do {
            for lang in asked {
                let rows = try await listIntentRegistrations(
                    lang: lang,
                    options: ListIntentsOptions(timeout: options.timeout, includeDefinitions: options.describe)
                )
                listed.append((lang, rows))
            }
        } catch let denied as ThalovantPolicyDeniedError {
            guard options.fallback, denied.deniedType == ThalovantEvents.intentList else { throw denied }
            let manifests = try await intentEngineManifests(lang: asked[0], timeout: options.timeout)
            return try await withFallbacks(inventoryFromNames(manifests, languages: asked, denied: denied.deniedType), timeout: options.timeout)
        } catch let timeout as ThalovantTimeoutError {
            guard options.fallback else { throw timeout }
            let manifests = try await intentEngineManifests(lang: asked[0], timeout: options.timeout)
            return try await withFallbacks(inventoryFromNames(manifests, languages: asked, denied: ThalovantEvents.intentList), timeout: options.timeout)
        }

        var wanted: [IntentRequestKey] = []
        for entry in listed {
            for row in entry.rows where row.enabled && row.definition == nil && row.method == "template" {
                wanted.append(IntentRequestKey(skillId: row.skillId, intentName: row.intentName, lang: entry.lang))
            }
        }
        let described = options.describe && !wanted.isEmpty
            ? try await describeIntentBatch(wanted, timeout: options.timeout)
            : [:]

        struct IntentIdentity: Hashable {
            let skillId: String
            let intentName: String
        }
        var phrases: [IntentIdentity: [(lang: String, sentences: [String])]] = [:]
        var engines: [IntentIdentity: String] = [:]
        var enabled: [IntentIdentity: Bool] = [:]
        for entry in listed {
            for row in entry.rows {
                let key = IntentIdentity(skillId: row.skillId, intentName: row.intentName)
                if engines[key] == nil {
                    engines[key] = row.engine
                }
                enabled[key] = (enabled[key] ?? false) || row.enabled
                let sentences: [String]
                if let definition = row.definition {
                    sentences = intentSamples(from: definition)
                } else {
                    let request = IntentRequestKey(skillId: row.skillId, intentName: row.intentName, lang: entry.lang)
                    sentences = described[request]?.first { !$0.samples.isEmpty }?.samples ?? []
                }
                // An intent registered under both engines has two rows for the
                // language; the keyword row carries no sentences and must not
                // erase the template row's, whichever order they arrive in.
                var perLanguage = phrases[key] ?? []
                if let index = perLanguage.firstIndex(where: { $0.lang == entry.lang }) {
                    if !sentences.isEmpty {
                        perLanguage[index] = (entry.lang, sentences)
                    }
                } else {
                    perLanguage.append((entry.lang, sentences))
                }
                phrases[key] = perLanguage
            }
        }

        var bySkill: [String: [HubIntent]] = [:]
        for (key, perLanguage) in phrases {
            let intent = HubIntent(
                skillId: key.skillId,
                name: key.intentName,
                engine: engines[key] ?? "unknown",
                phrases: Dictionary(uniqueKeysWithValues: perLanguage.map { ($0.lang, $0.sentences) }),
                languages: perLanguage.map { $0.lang },
                enabled: enabled[key] ?? true
            )
            bySkill[key.skillId, default: []].append(intent)
        }
        let skills = bySkill.keys.sorted().map { skillId in
            HubSkillIntents(skillId: skillId, intents: (bySkill[skillId] ?? []).sorted { $0.name < $1.name })
        }
        return try await withFallbacks(HubIntentInventory(languages: asked, skills: skills, source: .intentManifest), timeout: options.timeout)
    }
}

/// The names-only inventory the engines' manifests give: one intent per name,
/// skills sorted by id, intents by name, no sentences.
func inventoryFromNames(
    _ manifests: [(engine: String, names: [String])],
    languages: [String],
    denied: String
) -> HubIntentInventory {
    var bySkill: [String: [String: HubIntent]] = [:]
    for manifest in manifests {
        for raw in manifest.names {
            let (skillId, intentName) = splitIntentName(raw)
            // First engine to name it wins, as on the manifest path.
            if bySkill[skillId]?[intentName] == nil {
                bySkill[skillId, default: [:]][intentName] = HubIntent(
                    skillId: skillId, name: intentName, engine: manifest.engine
                )
            }
        }
    }
    let skills = bySkill.keys.sorted().map { skillId in
        HubSkillIntents(skillId: skillId, intents: (bySkill[skillId] ?? [:]).values.sorted { $0.name < $1.name })
    }
    return HubIntentInventory(languages: languages, skills: skills, source: .engineManifests, denied: [denied])
}


extension ThalovantClient {
    /// Registered fallback handlers; nil means discovery unavailable, [] means none registered.
    public func listFallbacks(timeout: TimeInterval = 5) async throws -> [HubFallback]? {
        try validateRuntimeTimeout(timeout)
        let event: ThalovantEvent
        do {
            event = try await withThrowingTaskGroup(of: ThalovantEvent.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    try await self.requestReply(queryType: ThalovantEvents.fallbackList,
                        replyType: ThalovantEvents.fallbackListResponse, data: [:], timeout: timeout)
                }
                group.addTask {
                    try await AsyncGate().wait(timeout: timeout, timeoutError: ThalovantTimeoutError("Fallback discovery timed out."))
                    throw ThalovantTimeoutError("Fallback discovery timed out.")
                }
                return try await group.next()!
            }
        } catch is ThalovantPolicyDeniedError { return nil }
          catch is ThalovantTimeoutError { return nil }
        guard event.data["ok"]?.boolValue != false, let rows = event.data["fallbacks"]?.arrayValue else { return nil }
        return rows.compactMap { $0.objectValue.flatMap(HubFallback.fromJSON) }.sorted {
            $0.priority != $1.priority ? $0.priority < $1.priority : $0.skillId < $1.skillId
        }
    }

    private func withFallbacks(_ inventory: HubIntentInventory, timeout: TimeInterval) async throws -> HubIntentInventory {
        let handlers = try await listFallbacks(timeout: min(timeout, 1.5))
        return HubIntentInventory(languages: inventory.languages, skills: inventory.skills,
            source: inventory.source, denied: inventory.denied, fallbacks: handlers ?? [], fallbacksKnown: handlers != nil)
    }
}
