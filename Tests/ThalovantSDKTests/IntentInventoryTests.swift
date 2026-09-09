import Foundation
import XCTest

@testable import ThalovantSDK

/// The intent inventory, against a hub that behaves like the one observed.
///
/// Shapes copied from a live runtime on 2026-09-05: `ovos.intent.list.response`
/// rows, `ovos.intent.describe.response` definitions carrying `samples` as the
/// skill's locale files wrote them, `hive.policy.denied` for a type the
/// connection may not publish, and every reply delivered twice.
private let weather = "thalovant-skill-weather.thalovant"
private let shadow = "thalovant-skill-custos-shadow.thalovant"
private let allowedTypes = ["recognizer_loop:utterance", "speak"]

/// What the hub registered: per language, per intent, the sentences. Weather
/// speaks both languages; the shadow skill only English.
private struct Registered {
    let skillId: String
    let intentName: String
    let samples: [String]
}

private let registrations: [String: [Registered]] = [
    "en-us": [
        Registered(skillId: weather, intentName: "current.weather", samples: [
            "what is the weather",
            "what is the weather in {location}",
            "how is it outside",
        ]),
        Registered(skillId: shadow, intentName: "custos.incidents", samples: [
            "are there incidents", "any incidents",
        ]),
    ],
    "fr-fr": [
        Registered(skillId: weather, intentName: "current.weather", samples: [
            "quel temps fait-il",
            "quelle est la météo à {location}",
            "quelle est la météo",
        ]),
    ],
]

/// A hub session: answers the manifest, or refuses it, twice over.
private final class FakeHubTransport: HiveMindBusTransport, @unchecked Sendable {
    struct Emitted {
        let type: String
        let data: JSONObject
        let context: JSONObject
    }

    let registered: [String: [Registered]]
    let refuse: Set<String>
    let silent: Set<String>
    let definitionsInList: Bool
    let echoRequestId: Bool
    let repeats: Int
    /// Skills whose describes are swallowed: the hub never answers them.
    let deafDescribeSkills: Set<String>
    /// Intent names whose describes are swallowed, for a hub that stops
    /// answering part way through.
    let deafDescribeIntent: (@Sendable (String) -> Bool)?
    /// When set, replies arrive that many seconds later on another thread,
    /// the way a real hub answers on the receive loop, instead of inside
    /// `emitBus`.
    let replyDelay: TimeInterval?
    /// When set, answers `ovos.intent.list` with these rows for the language
    /// instead of the registrations.
    let listRows: ((String) -> [JSONValue])?
    /// When set, answers `ovos.intent.list` with `{"ok": false, "error": ...}`
    /// -- the query failed, which is not the same as a hub with no intents.
    let listError: String?
    /// What `intent.service.adapt.manifest.get` answers (names only).
    let adaptNames: [String]
    let fallbackPayload: JSONObject
    let foreignFirst: Bool
    let fallbackDelay: TimeInterval
    let connectDelay: TimeInterval

    private let lock = NSLock()
    private var handlers: [UUID: (JSONObject) -> Void] = [:]
    private var connectedFlag = false
    private var emittedLog: [Emitted] = []
    private var describesInWindow = 0
    private var closedWindows: [Int] = []

    init(
        registered: [String: [Registered]] = registrations,
        refuse: Set<String> = [],
        silent: Set<String> = [],
        definitionsInList: Bool = false,
        echoRequestId: Bool = true,
        repeats: Int = 2,
        deafDescribeSkills: Set<String> = [],
        deafDescribeIntent: (@Sendable (String) -> Bool)? = nil,
        replyDelay: TimeInterval? = nil,
        listRows: ((String) -> [JSONValue])? = nil,
        listError: String? = nil,
        adaptNames: [String] = [],
        fallbackPayload: JSONObject = ["fallbacks": .array([])],
        foreignFirst: Bool = false, fallbackDelay: TimeInterval = 0, connectDelay: TimeInterval = 0
    ) {
        self.registered = registered
        self.refuse = refuse
        self.silent = silent
        self.definitionsInList = definitionsInList
        self.echoRequestId = echoRequestId
        self.repeats = repeats
        self.deafDescribeSkills = deafDescribeSkills
        self.deafDescribeIntent = deafDescribeIntent
        self.replyDelay = replyDelay
        self.listRows = listRows
        self.listError = listError
        self.adaptNames = adaptNames
        self.fallbackPayload = fallbackPayload
        self.foreignFirst = foreignFirst; self.fallbackDelay = fallbackDelay; self.connectDelay = connectDelay
    }

    var connected: Bool { lock.locked { connectedFlag } }
    var emitted: [Emitted] { lock.locked { emittedLog } }

    /// How many describes went out inside each subscription window, in order.
    /// A window closes when the client drops its handlers, so this is the
    /// number of requests that were in flight together.
    var describeWindows: [Int] {
        lock.locked { describesInWindow > 0 ? closedWindows + [describesInWindow] : closedWindows }
    }

    func clearEmitted() {
        lock.locked { emittedLog = [] }
    }

    // MARK: transport surface

    func connect(timeout: TimeInterval) async throws {
        if connectDelay > 0 { try await Task.sleep(nanoseconds: UInt64(connectDelay * 1_000_000_000)) }
        lock.locked { connectedFlag = true }
    }

    func disconnect() async {
        lock.locked { connectedFlag = false }
    }

    func addBusHandler(_ handler: @escaping (JSONObject) -> Void) -> UUID {
        let id = UUID()
        lock.locked { handlers[id] = handler }
        return id
    }

    func removeBusHandler(_ id: UUID) {
        lock.locked {
            handlers.removeValue(forKey: id)
            // The client drops both handlers at the end of a window; the last
            // one out closes it.
            if handlers.isEmpty, describesInWindow > 0 {
                closedWindows.append(describesInWindow)
                describesInWindow = 0
            }
        }
    }

    // MARK: the hub

    private func deliver(_ type: String, data: JSONObject, context: JSONObject) {
        var replyContext = context
        if !echoRequestId {
            replyContext["request_id"] = nil
        }
        if foreignFirst && type == ThalovantEvents.intentDescribeResponse {
            var bad = data
            if var definitions = bad["definitions"]?.arrayValue, var first = definitions.first?.objectValue,
               var definition = first["definition"]?.objectValue {
                definition["samples"] = .array([.string("foreign phrase")]); first["definition"] = .object(definition)
                definitions[0] = .object(first); bad["definitions"] = .array(definitions)
                fanOut(["type": .string(type), "data": .object(bad), "context": .object(["request_id": .string("foreign-request")])])
            }
        }
        let payload: JSONObject = ["type": .string(type), "data": .object(data), "context": .object(replyContext)]
        guard let replyDelay else {
            fanOut(payload)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + replyDelay) { [self] in
            fanOut(payload)
        }
    }

    private func fanOut(_ payload: JSONObject) {
        for _ in 0..<repeats {
            for handler in lock.locked({ Array(handlers.values) }) {
                handler(payload)
            }
        }
    }

    func emitBus(type: String, data: JSONObject, context: JSONObject) async throws {
        if type == ThalovantEvents.fallbackList && fallbackDelay > 0 { try await Task.sleep(nanoseconds: UInt64(fallbackDelay * 1_000_000_000)) }
        if foreignFirst { deliver(ThalovantEvents.policyDenied, data: ["denied_type": .string(type)], context: ["request_id": .string("foreign-request")]) }
        lock.locked {
            emittedLog.append(Emitted(type: type, data: data, context: context))
            if type == ThalovantEvents.intentDescribe {
                describesInWindow += 1
            }
        }
        if refuse.contains(type) {
            deliver(ThalovantEvents.policyDenied, data: [
                "denied_type": .string(type),
                "code": "acl_disallowed_type",
                "reason": .string("\(type) not in allowed_types"),
                "data": .object(["msg_type": .string(type), "allowed": .array(allowedTypes.map { .string($0) })]),
            ], context: context)
            return
        }
        if silent.contains(type) {
            return
        }
        // ovos-core's manifest folds the tag it receives (`standardize_lang`
        // on both store and query), so `fr_FR` finds what `fr-fr` registered.
        // The fake must not be stricter than the hub.
        let sent = data["lang"]?.stringValue ?? ""
        let lang = normalizedLanguageTag(sent)
        switch type {
        case ThalovantEvents.fallbackList:
            deliver(ThalovantEvents.fallbackListResponse, data: fallbackPayload, context: context)
        case ThalovantEvents.intentList:
            if let listError {
                deliver(
                    ThalovantEvents.intentListResponse,
                    data: ["ok": false, "error": .string(listError)],
                    context: context
                )
                return
            }
            if let listRows {
                deliver(ThalovantEvents.intentListResponse, data: ["ok": true, "intents": .array(listRows(lang))], context: context)
                return
            }
            var rows: [JSONValue] = []
            for entry in registered[lang] ?? [] {
                // The runtime standardises what it stores: fr-fr is answered in
                // another case, and the client must not mind.
                var row: JSONObject = [
                    "skill_id": .string(entry.skillId),
                    "intent_name": .string(entry.intentName),
                    "lang": .string(lang == "fr-fr" ? lang.uppercased() : lang),
                    "method": "template",
                    "enabled": true,
                    "session_id": "default",
                ]
                if definitionsInList, data["include_definitions"]?.boolValue == true {
                    row["definition"] = .object([
                        "skill_id": .string(entry.skillId),
                        "intent_name": .string(entry.intentName),
                        "lang": .string(lang),
                        "samples": .array(entry.samples.map { .string($0) }),
                    ])
                }
                rows.append(.object(row))
            }
            deliver(ThalovantEvents.intentListResponse, data: ["ok": true, "intents": .array(rows)], context: context)
        case ThalovantEvents.intentDescribe:
            let skillId = data["skill_id"]?.stringValue ?? ""
            let intentName = data["intent_name"]?.stringValue ?? ""
            if deafDescribeSkills.contains(skillId) || deafDescribeIntent?(intentName) == true {
                return
            }
            let known = (registered[lang] ?? []).first { $0.skillId == skillId && $0.intentName == intentName }
            let payload: JSONObject
            if let known {
                payload = ["ok": true, "definitions": .array([
                    .object([
                        "method": "template",
                        "definition": .object([
                            "skill_id": .string(known.skillId),
                            "intent_name": .string(known.intentName),
                            "lang": .string(lang),
                            "samples": .array(known.samples.map { .string($0) }),
                            "blacklist": .array([]),
                            "slot_blacklist": .object([:]),
                        ]),
                    ]),
                ])]
            } else {
                payload = ["ok": false, "error": "unknown intent"]
            }
            deliver(ThalovantEvents.intentDescribeResponse, data: payload, context: context)
        case ThalovantEvents.adaptManifestGet:
            deliver(ThalovantEvents.adaptManifest, data: ["intents": .array(adaptNames.map { .string($0) })], context: context)
        case ThalovantEvents.padatiousManifestGet:
            var names = Set<String>()
            for entries in registered.values {
                for entry in entries {
                    names.insert("\(entry.skillId):\(entry.intentName)")
                }
            }
            deliver(
                ThalovantEvents.padatiousManifest,
                data: ["intents": .array(names.sorted().map { .string($0) })],
                context: context
            )
        default:
            break
        }
    }
}

private func identity() throws -> ThalovantIdentity {
    try ThalovantIdentity(json: [
        "access_key": "key", "password": "password", "crypto_key": "crypto",
        "site_id": "site", "default_master": "http://hub.local", "default_port": 5679,
    ])
}

private func client(_ hub: FakeHubTransport) throws -> ThalovantClient {
    let identity = try identity()
    return ThalovantClient(identity: identity, transport: hub, replySettle: 0)
}

final class IntentInventoryTests: XCTestCase {
    func testInventoryCarriesTheSentencesPerLanguage() async throws {
        let hub = FakeHubTransport()
        let inventory = try await client(hub).intents(languages: ["en-us", "fr-fr"])

        XCTAssertEqual(inventory.source, .intentManifest)
        XCTAssertTrue(inventory.denied.isEmpty)
        XCTAssertEqual(inventory.languages, ["en-us", "fr-fr"])
        XCTAssertEqual(inventory.skills.map { $0.skillId }, [shadow, weather])
        let weatherIntent = try XCTUnwrap(inventory.skills[1].intents.first)
        XCTAssertEqual(weatherIntent.id, "\(weather):current.weather")
        XCTAssertEqual(weatherIntent.engine, "padatious")
        XCTAssertTrue(weatherIntent.enabled)
        XCTAssertEqual(weatherIntent.phrasesFor("fr-FR"), [
            "quel temps fait-il", "quelle est la météo à {location}", "quelle est la météo",
        ])
        XCTAssertEqual(inventory.skills[1].languages, ["en-us", "fr-fr"])
        let shadowSkill = inventory.skills[0]
        XCTAssertEqual(shadowSkill.languages, ["en-us"], "the hub said the skill has no French")
        XCTAssertEqual(shadowSkill.intents[0].phrasesFor("fr-fr"), [])
        XCTAssertTrue(inventory.hasPhrases)
        XCTAssertTrue(hub.connected, "the query connects the client first")
    }

    func testExamplesPreferWholeSentencesAndRespectTheLimit() async throws {
        let inventory = try await client(FakeHubTransport()).intents(languages: ["en-us"])
        let weatherIntent = try XCTUnwrap(inventory.skills[1].intents.first)
        XCTAssertEqual(weatherIntent.examples(lang: "en-us", limit: 2), ["how is it outside", "what is the weather"])
        XCTAssertEqual(weatherIntent.examples(lang: "en-us", limit: 0), weatherIntent.phrasesFor("en-us"))
        XCTAssertEqual(weatherIntent.examples(limit: 1), ["how is it outside"])
        XCTAssertEqual(weatherIntent.examples(lang: "de-de"), [], "no sentences for a language never listed")
    }

    func testEveryRegistrationIsDescribedAtOnceAndRepeatsAreDropped() async throws {
        let hub = FakeHubTransport(repeats: 3)
        let inventory = try await client(hub).intents(languages: ["en-us", "fr-fr"])

        let describes = hub.emitted
            .filter { $0.type == ThalovantEvents.intentDescribe }
            .map { "\($0.data["skill_id"]?.stringValue ?? "")|\($0.data["intent_name"]?.stringValue ?? "")|\($0.data["lang"]?.stringValue ?? "")" }
        XCTAssertEqual(describes.count, 3)
        XCTAssertEqual(Set(describes).count, 3, "each registration is described once, in one batch")
        XCTAssertEqual(inventory.intents.count, 2)
        XCTAssertEqual(inventory.intents.map { $0.id }, ["\(shadow):custos.incidents", "\(weather):current.weather"])
        for emitted in hub.emitted where [ThalovantEvents.intentList, ThalovantEvents.intentDescribe].contains(emitted.type) {
            XCTAssertNotNil(emitted.context["request_id"]?.stringValue, "every query is correlated by request id")
            XCTAssertNotNil(emitted.context["lang"]?.stringValue, "the language rides in the context too")
        }
    }

    func testDefinitionsAttachedToTheListingSkipTheDescribes() async throws {
        let hub = FakeHubTransport(definitionsInList: true)
        let inventory = try await client(hub).intents(languages: ["fr-fr"])
        XCTAssertFalse(hub.emitted.contains { $0.type == ThalovantEvents.intentDescribe })
        XCTAssertEqual(inventory.intents.first?.phrasesFor("fr-fr").first, "quel temps fait-il")
        XCTAssertEqual(hub.emitted.first?.data, ["lang": "fr-fr", "include_definitions": true])
    }

    func testDescribeOffListsNamesAndEnginesOnly() async throws {
        let hub = FakeHubTransport()
        let inventory = try await client(hub).intents(
            languages: ["en-us"], options: IntentInventoryOptions(describe: false)
        )
        XCTAssertFalse(hub.emitted.contains { $0.type == ThalovantEvents.intentDescribe })
        XCTAssertEqual(hub.emitted.first?.data, ["lang": "en-us"], "include_definitions is not asked for")
        XCTAssertEqual(inventory.source, .intentManifest)
        XCTAssertEqual(inventory.intents.count, 2)
        XCTAssertFalse(inventory.hasPhrases)
        XCTAssertEqual(inventory.intents[0].languages, ["en-us"], "listed for the language, without sentences")
    }

    func testARefusalIsAnErrorNamingTheTypeNotATimeout() async throws {
        let hub = FakeHubTransport(refuse: [ThalovantEvents.intentList])
        let started = Date()
        do {
            _ = try await client(hub).intents(
                languages: ["en-us"], options: IntentInventoryOptions(timeout: 5, fallback: false)
            )
            XCTFail("expected ThalovantPolicyDeniedError")
        } catch let error as ThalovantPolicyDeniedError {
            XCTAssertEqual(error.deniedType, "ovos.intent.list")
            XCTAssertEqual(error.code, "acl_disallowed_type")
            XCTAssertEqual(error.reason, "ovos.intent.list not in allowed_types")
            XCTAssertEqual(error.allowed, allowedTypes)
            XCTAssertTrue(error.message.contains("ovos.intent.list"))
            XCTAssertTrue(error.message.contains("connection"))
            XCTAssertEqual(error.errorDescription, error.message)
            XCTAssertEqual("\(error)", error.message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the refusal is surfaced at once, not after the deadline")
        XCTAssertFalse(hub.emitted.contains { $0.type == ThalovantEvents.adaptManifestGet }, "no fallback was asked for")
    }

    func testTheFallbackListsNamesAndSaysWhatWasRefused() async throws {
        let hub = FakeHubTransport(refuse: [ThalovantEvents.intentList])
        let inventory = try await client(hub).intents(languages: ["en-us", "fr-fr"])

        XCTAssertEqual(inventory.source, .engineManifests)
        XCTAssertEqual(inventory.denied, ["ovos.intent.list"])
        XCTAssertEqual(inventory.languages, ["en-us", "fr-fr"])
        XCTAssertFalse(inventory.hasPhrases)
        XCTAssertEqual(inventory.intents.map { $0.id }, ["\(shadow):custos.incidents", "\(weather):current.weather"])
        XCTAssertEqual(inventory.intents.map { $0.engine }, ["padatious", "padatious"])
        XCTAssertEqual(inventory.intents[0].languages, [])
        // Names carry no language, so the engines are asked once, not per language.
        XCTAssertEqual(hub.emitted.filter { $0.type == ThalovantEvents.padatiousManifestGet }.count, 1)
        XCTAssertEqual(hub.emitted.filter { $0.type == ThalovantEvents.adaptManifestGet }.count, 1)
    }

    func testAHubRefusingEverythingThrowsEvenWithTheFallback() async throws {
        let hub = FakeHubTransport(refuse: [ThalovantEvents.intentList, ThalovantEvents.adaptManifestGet])
        do {
            _ = try await client(hub).intents(languages: ["en-us"])
            XCTFail("expected ThalovantPolicyDeniedError")
        } catch let error as ThalovantPolicyDeniedError {
            XCTAssertEqual(error.deniedType, "intent.service.adapt.manifest.get")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testARefusedDescribeIsNotHiddenByTheListing() async throws {
        let hub = FakeHubTransport(refuse: [ThalovantEvents.intentDescribe])
        do {
            _ = try await client(hub).intents(languages: ["en-us"])
            XCTFail("expected ThalovantPolicyDeniedError")
        } catch let error as ThalovantPolicyDeniedError {
            XCTAssertEqual(error.deniedType, "ovos.intent.describe")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSilentListingFallsBackWithoutProvingPolicyDenial() async throws {
        let hub = FakeHubTransport(silent: [ThalovantEvents.intentList])
        let result = try await client(hub).intents(languages: ["en-us"], options: IntentInventoryOptions(timeout: 0.03))
        XCTAssertEqual(result.source, .engineManifests)
        XCTAssertEqual(result.denied, [ThalovantEvents.intentList])
        XCTAssertTrue(result.fallbacksKnown)
        XCTAssertFalse(result.mayAnswer("de-de"))
    }

    func testSilentListingStrictModeAndSilentEnginesStillTimeOut() async throws {
        for (silent, fallback, expected) in [
            ([ThalovantEvents.intentList], false, ThalovantEvents.intentList),
            ([ThalovantEvents.intentList, ThalovantEvents.adaptManifestGet], true, ThalovantEvents.adaptManifestGet),
        ] {
            do {
                _ = try await client(FakeHubTransport(silent: Set(silent))).intents(
                    languages: ["en-us"], options: IntentInventoryOptions(timeout: 0.03, fallback: fallback))
                XCTFail("Expected timeout")
            } catch let error as ThalovantTimeoutError { XCTAssertTrue(error.message.contains(expected)) }
        }
    }

    func testFallbackDiscoveryDistinguishesUnknownFromKnownEmpty() async throws {
        for hub in [FakeHubTransport(refuse: [ThalovantEvents.fallbackList]),
                    FakeHubTransport(silent: [ThalovantEvents.fallbackList]),
                    FakeHubTransport(fallbackPayload: ["fallbacks": .string("invalid")]),
                    FakeHubTransport(fallbackPayload: ["ok": .bool(false), "fallbacks": .array([])])] {
            let inventory = try await client(hub).intents(languages: ["fr-fr"], options: IntentInventoryOptions(timeout: 0.03))
            XCTAssertFalse(inventory.fallbacksKnown)
            XCTAssertTrue(inventory.mayAnswer("de-de"))
            XCTAssertEqual(inventory.asJSON()["fallbacks_known"], .bool(false))
        }
        let known = try await client(FakeHubTransport()).intents(languages: ["fr-fr"])
        XCTAssertTrue(known.fallbacksKnown)
        XCTAssertTrue(known.mayAnswer("fr-FR"))
        XCTAssertFalse(known.mayAnswer("de-de"))
        XCTAssertTrue(HubIntentInventory.fromJSON([:]).mayAnswer("de-de"))
        XCTAssertEqual(HubIntentInventory.fromJSON(known.asJSON()), known)
    }

    func testForeignCorrelatedDenialsAndDescriptionsCannotCompleteOurRequests() async throws {
        let inventory = try await client(FakeHubTransport(foreignFirst: true)).intents(languages: ["en-us", "fr-fr"])
        XCTAssertTrue(inventory.hasPhrases)
        XCTAssertFalse(inventory.intents.flatMap { $0.phrases.values.flatMap { $0 } }.contains("foreign phrase"))
        XCTAssertTrue(inventory.fallbacksKnown)
    }

    func testFallbackBudgetIncludesConnectAndSendAndPreservesCancellation() async throws {
        for hub in [FakeHubTransport(fallbackDelay: 5), FakeHubTransport(connectDelay: 5)] {
            let sdk = try client(hub), start = ProcessInfo.processInfo.systemUptime
            let handlers = try await sdk.listFallbacks(timeout: 0.03)
            XCTAssertNil(handlers); XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
            let pending = Task { try await sdk.listFallbacks(timeout: 5) }
            pending.cancel()
            do { _ = try await pending.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        }
        let start = ProcessInfo.processInfo.systemUptime
        let inventory = try await client(FakeHubTransport(fallbackDelay: 5)).intents(languages: ["en-us"])
        XCTAssertFalse(inventory.fallbacksKnown)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
    }

    func testFallbackDiscoveryParsesSortsAndRejectsUnsafePriority() async throws {
        let rows: [JSONValue] = [
            .object(["skill_id": .string("b"), "priority": .integer(20)]),
            .object(["skill_id": .string("a"), "priority": .number(20.5)]),
            .object(["skill_id": .string("default"), "priority": .string("10")]),
            .object(["skill_id": .string("huge"), "priority": .number(1e100)]),
            .object(["skill_id": .string("")]), .bool(false),
        ]
        let sdk = try client(FakeHubTransport(fallbackPayload: ["fallbacks": .array(rows)]))
        let handlers = try await sdk.listFallbacks()
        XCTAssertEqual(handlers, [HubFallback(skillId: "default"), HubFallback(skillId: "a", priority: 20), HubFallback(skillId: "b", priority: 20)])
        let inventory = try await sdk.intents(languages: ["fr-fr"])
        XCTAssertTrue(inventory.mayAnswer("de-de"))
        XCTAssertTrue(inventory.fallbacksKnown)
    }

    func testADescribeThatNeverComesLeavesThatIntentWithoutSentences() async throws {
        let hub = FakeHubTransport(deafDescribeSkills: [shadow])
        let inventory = try await client(hub).intents(languages: ["en-us"], options: IntentInventoryOptions(timeout: 0.3))
        var byId: [String: HubIntent] = [:]
        for intent in inventory.intents {
            byId[intent.id] = intent
        }
        XCTAssertFalse(try XCTUnwrap(byId["\(weather):current.weather"]).phrasesFor("en-us").isEmpty)
        XCTAssertEqual(try XCTUnwrap(byId["\(shadow):custos.incidents"]).phrasesFor("en-us"), [])
        XCTAssertEqual(byId["\(shadow):custos.incidents"]?.languages, ["en-us"], "still listed for the language")
    }

    func testNoDescribeAnsweredAtAllIsATimeout() async throws {
        let hub = FakeHubTransport(silent: [ThalovantEvents.intentDescribe])
        do {
            _ = try await client(hub).intents(languages: ["en-us"], options: IntentInventoryOptions(timeout: 0.2))
            XCTFail("expected ThalovantTimeoutError")
        } catch let error as ThalovantTimeoutError {
            XCTAssertTrue(error.message.contains("ovos.intent.describe"), error.message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAReplyWithoutARequestIdIsStillTaken() async throws {
        // A hub that does not echo the request id is not evidence of anything.
        let hub = FakeHubTransport(echoRequestId: false, repeats: 1)
        let inventory = try await client(hub).intents(languages: ["en-us", "fr-fr"])
        XCTAssertTrue(inventory.hasPhrases)
        XCTAssertEqual(inventory.intents.count, 2)
        // Describes are matched by the definition's own identity, language folded.
        let weatherIntent = try XCTUnwrap(inventory.intents.first { $0.skillId == weather })
        XCTAssertEqual(weatherIntent.phrasesFor("fr-fr").first, "quel temps fait-il")
        XCTAssertEqual(weatherIntent.phrasesFor("en-us").first, "what is the weather")
    }

    func testLowLevelCallsExposeTheManifestRowsAndDefinitions() async throws {
        let hub = FakeHubTransport()
        let rows = try await client(hub).listIntents(lang: "fr-fr")
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.skillId, weather)
        XCTAssertEqual(row.intentName, "current.weather")
        XCTAssertEqual(row.method, "template")
        XCTAssertEqual(row.engine, "padatious")
        XCTAssertTrue(row.enabled)
        XCTAssertEqual(row.sessionId, "default")
        XCTAssertNil(row.definition)
        XCTAssertEqual(row.lang, "FR-FR", "as the runtime standardised it")
        XCTAssertTrue(sameLanguage(row.lang, "fr-fr"))
        XCTAssertEqual(hub.emitted.first?.data, ["lang": "fr-fr"])

        let definitions = try await client(hub).describeIntent(skillId: weather, intentName: "current.weather", lang: "fr-fr")
        XCTAssertEqual(definitions.count, 1)
        let definition = try XCTUnwrap(definitions.first)
        XCTAssertEqual(definition.samples.first, "quel temps fait-il")
        XCTAssertEqual(definition.method, "template")
        XCTAssertEqual(definition.engine, "padatious")
        XCTAssertEqual(definition.skillId, weather)
        XCTAssertEqual(definition.intentName, "current.weather")
        XCTAssertEqual(definition.lang, "fr-fr")
        XCTAssertEqual(definition.raw["blacklist"], .array([]))
        XCTAssertEqual(definition.raw["slot_blacklist"], .object([:]))

        let unknown = try await client(hub).describeIntent(skillId: shadow, intentName: "custos.incidents", lang: "fr-fr")
        XCTAssertEqual(unknown, [])
    }

    func testListIntentsCanAskForDefinitions() async throws {
        let hub = FakeHubTransport(definitionsInList: true)
        let rows = try await client(hub).listIntents(lang: "en-us", options: ListIntentsOptions(includeDefinitions: true))
        XCTAssertEqual(hub.emitted.first?.data, ["lang": "en-us", "include_definitions": true])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].definition?["samples"]?.arrayValue?.first?.stringValue, "what is the weather")
    }

    func testLowLevelRefusalsThrowThePolicyError() async throws {
        let hub = FakeHubTransport(refuse: [ThalovantEvents.intentDescribe])
        do {
            _ = try await client(hub).describeIntent(skillId: weather, intentName: "current.weather", lang: "en-us")
            XCTFail("expected ThalovantPolicyDeniedError")
        } catch let error as ThalovantPolicyDeniedError {
            XCTAssertEqual(error.deniedType, "ovos.intent.describe")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAsJSONIsCompleteAndCodableRoundTrips() async throws {
        let inventory = try await client(FakeHubTransport()).intents(languages: ["en-us", "fr-fr"])
        let payload = inventory.asJSON()
        XCTAssertEqual(payload["source"]?.stringValue, "intent-manifest")
        XCTAssertEqual(payload["languages"], .array(["en-us", "fr-fr"]))
        XCTAssertEqual(payload["denied"], .array([]))
        let skills = try XCTUnwrap(payload["skills"]?.arrayValue)
        let weatherSkill = try XCTUnwrap(skills.first { $0["skill_id"]?.stringValue == weather })
        XCTAssertEqual(weatherSkill["languages"], .array(["en-us", "fr-fr"]))
        let intent = try XCTUnwrap(weatherSkill["intents"]?[0])
        XCTAssertEqual(intent["id"]?.stringValue, "\(weather):current.weather")
        XCTAssertEqual(intent["skill_id"]?.stringValue, weather)
        XCTAssertEqual(intent["name"]?.stringValue, "current.weather")
        XCTAssertEqual(intent["engine"]?.stringValue, "padatious")
        XCTAssertEqual(intent["enabled"]?.boolValue, true)
        XCTAssertEqual(intent["phrases"]?["fr-fr"]?[0]?.stringValue, "quel temps fait-il")

        let encoded = try JSONEncoder().encode(inventory)
        let decoded = try JSONDecoder().decode(HubIntentInventory.self, from: encoded)
        XCTAssertEqual(decoded, inventory)
        XCTAssertEqual(decoded.skills[1].intents[0].phrasesFor("fr-FR").count, 3)
    }

    func testLanguagesDefaultToEnglish() async throws {
        let hub = FakeHubTransport()
        _ = try await client(hub).intents()
        XCTAssertEqual(hub.emitted.first?.data["lang"]?.stringValue, "en-us")
        hub.clearEmitted()
        _ = try await client(hub).intents(languages: [])
        XCTAssertEqual(hub.emitted.first?.data["lang"]?.stringValue, "en-us")
        hub.clearEmitted()
        _ = try await client(hub).listIntents()
        XCTAssertEqual(hub.emitted.first?.data["lang"]?.stringValue, "en-us")
        hub.clearEmitted()
        _ = try await client(hub).describeIntent(skillId: weather, intentName: "current.weather")
        XCTAssertEqual(hub.emitted.first?.data["lang"]?.stringValue, "en-us")
    }

    func testBlankLanguagesAreRejected() async throws {
        let hub = FakeHubTransport()
        do {
            _ = try await client(hub).intents(languages: ["  "])
            XCTFail("expected ThalovantRuntimeError")
        } catch let error as ThalovantRuntimeError {
            XCTAssertTrue(error.message.contains("language"), error.message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(hub.emitted.isEmpty)
    }

    func testRepliesThatArriveLaterStillCompleteTheInventory() async throws {
        // A real hub answers on the receive loop, after emit returned: the
        // waits must suspend and be woken, and the batch must take replies
        // arriving from another thread while requests are still going out.
        let hub = FakeHubTransport(repeats: 2, replyDelay: 0.05)
        let inventory = try await client(hub).intents(languages: ["en-us", "fr-fr"], options: IntentInventoryOptions(timeout: 2))
        XCTAssertEqual(inventory.intents.count, 2)
        XCTAssertEqual(inventory.intents.first { $0.skillId == weather }?.phrasesFor("fr-fr").count, 3)
        XCTAssertEqual(inventory.intents.first { $0.skillId == shadow }?.phrasesFor("en-us").count, 2)

        let refused = FakeHubTransport(refuse: [ThalovantEvents.intentList], replyDelay: 0.05)
        do {
            _ = try await client(refused).intents(languages: ["en-us"], options: IntentInventoryOptions(timeout: 2, fallback: false))
            XCTFail("expected ThalovantPolicyDeniedError")
        } catch let error as ThalovantPolicyDeniedError {
            XCTAssertEqual(error.deniedType, "ovos.intent.list")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRepeatedLanguagesAreAskedOnce() async throws {
        let hub = FakeHubTransport()
        let inventory = try await client(hub).intents(languages: ["en-us", "en-us"])
        XCTAssertEqual(inventory.languages, ["en-us"])
        XCTAssertEqual(hub.emitted.filter { $0.type == ThalovantEvents.intentList }.count, 1)
    }

    // MARK: The four points the ports settled (reference 0.4.37)

    func testHasPhrasesMeansAtLeastOneSentence() async throws {
        let hub = FakeHubTransport(registered: ["en-us": [Registered(skillId: shadow, intentName: "custos.incidents", samples: [])]])
        let inventory = try await client(hub).intents(languages: ["en-us"])
        XCTAssertEqual(inventory.intents.count, 1, "the intent is listed")
        XCTAssertEqual(inventory.intents[0].languages, ["en-us"], "and listed for the language")
        XCTAssertFalse(inventory.hasPhrases, "but its describe came back with no sentences")
    }

    func testLanguagesAreFoldedAndDeduplicatedBeforeAsking() async throws {
        let hub = FakeHubTransport()
        let inventory = try await client(hub).intents(languages: [" en-us ", "en-US", "en_us", "fr-fr"])
        XCTAssertEqual(inventory.languages, ["en-us", "fr-fr"], "the first spelling, trimmed, in the order given")
        XCTAssertEqual(
            hub.emitted.filter { $0.type == ThalovantEvents.intentList }.map { $0.data["lang"]?.stringValue },
            ["en-us", "fr-fr"],
            "one language is asked once"
        )
        let weatherIntent = try XCTUnwrap(inventory.intents.first { $0.skillId == weather })
        XCTAssertEqual(weatherIntent.languages, ["en-us", "fr-fr"])
        XCTAssertEqual(weatherIntent.phrasesFor("en_US").count, 3)
    }

    func testAKeywordRowDoesNotEraseTheTemplateRowsSentences() async throws {
        // One intent, two registrations in one language: the keyword row has
        // no samples. Whichever order the rows arrive in, the sentences stay;
        // the first row names the engine.
        func row(_ method: String, lang: String) -> JSONValue {
            var definition: JSONObject = [
                "skill_id": .string(weather), "intent_name": "current.weather", "lang": .string(lang),
            ]
            if method == "template" {
                definition["samples"] = .array(["what is the weather"])
            } else {
                definition["required"] = .array([.array(["WeatherKeyword"])])
            }
            return .object([
                "skill_id": .string(weather), "intent_name": "current.weather", "lang": .string(lang),
                "method": .string(method), "enabled": true, "session_id": "default",
                "definition": .object(definition),
            ])
        }
        let templateFirst = FakeHubTransport(listRows: { lang in [row("template", lang: lang), row("keyword", lang: lang)] })
        let inventory = try await client(templateFirst).intents(languages: ["en-us"])
        XCTAssertEqual(inventory.intents.count, 1, "one intent, not two")
        XCTAssertEqual(inventory.intents[0].phrasesFor("en-us"), ["what is the weather"])
        XCTAssertEqual(inventory.intents[0].engine, "padatious", "the first row names the engine")
        XCTAssertTrue(inventory.hasPhrases)

        let keywordFirst = FakeHubTransport(listRows: { lang in [row("keyword", lang: lang), row("template", lang: lang)] })
        let reversed = try await client(keywordFirst).intents(languages: ["en-us"])
        XCTAssertEqual(reversed.intents.count, 1)
        XCTAssertEqual(reversed.intents[0].phrasesFor("en-us"), ["what is the weather"])
        XCTAssertEqual(reversed.intents[0].engine, "adapt", "the first row names the engine")
    }

    func testDescribesGoOutInBoundedBatches() async throws {
        // A hub with many intents must not put more requests in flight than a
        // bounded reply queue can hold: 69 intents is 69 describes, and every
        // reply arrives twice. They go out 32 at a time, each batch its own
        // subscription window.
        let many = (0..<69).map { n in
            Registered(skillId: weather, intentName: String(format: "intent.%03d", n), samples: ["sentence \(n)"])
        }
        let hub = FakeHubTransport(registered: ["en-us": many])
        let inventory = try await client(hub).intents(languages: ["en-us"])

        XCTAssertEqual(defaultDescribeBatchSize, 32)
        XCTAssertEqual(hub.describeWindows, [32, 32, 5], "69 describes go out in three batches of at most 32")
        XCTAssertEqual(inventory.intents.count, 69)
        XCTAssertTrue(inventory.hasPhrases)
        for intent in inventory.intents {
            XCTAssertEqual(intent.phrasesFor("en-us").count, 1, "\(intent.id) came back without its sentence")
        }
        XCTAssertEqual(hub.emitted.filter { $0.type == ThalovantEvents.intentDescribe }.count, 69, "each intent asked once")
    }

    func testABatchSizeOfZeroSendsThemAllAtOnce() async throws {
        let many = (0..<69).map { n in
            Registered(skillId: weather, intentName: String(format: "intent.%03d", n), samples: ["sentence \(n)"])
        }
        let hub = FakeHubTransport(registered: ["en-us": many])
        let sdk = try client(hub)
        let wanted = many.map { IntentRequestKey(skillId: $0.skillId, intentName: $0.intentName, lang: "en-us") }
        let described = try await sdk.describeIntentBatch(wanted, timeout: 5, batchSize: 0)
        XCTAssertEqual(described.count, 69)
        XCTAssertEqual(hub.describeWindows, [69], "batchSize 0 restores one window for everything")
    }

    func testASilentHubFailsAfterOneBatchNotAfterEveryRequest() async throws {
        // The deadline covers each batch, so nothing waits on 69 open requests.
        let many = (0..<69).map { n in
            Registered(skillId: weather, intentName: String(format: "intent.%03d", n), samples: ["sentence \(n)"])
        }
        let hub = FakeHubTransport(registered: ["en-us": many], silent: [ThalovantEvents.intentDescribe])
        do {
            _ = try await client(hub).intents(languages: ["en-us"], options: IntentInventoryOptions(timeout: 0.2))
            XCTFail("expected ThalovantTimeoutError")
        } catch is ThalovantTimeoutError {
            XCTAssertEqual(hub.describeWindows, [32], "it gave up after the first batch")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testASilentWindowKeepsWhatTheEarlierWindowsFound() async throws {
        // Windows are contiguous slices, so a skill that stops answering can
        // own a whole window. Losing its sentences is right; losing the
        // inventory is not.
        let quietFrom = 40
        let many = (0..<69).map { n in
            Registered(skillId: weather, intentName: String(format: "intent.%03d", n), samples: ["sentence \(n)"])
        }
        let hub = FakeHubTransport(
            registered: ["en-us": many],
            deafDescribeIntent: { name in (Int(name.split(separator: ".").last ?? "") ?? 0) >= quietFrom }
        )
        let inventory = try await client(hub).intents(languages: ["en-us"], options: IntentInventoryOptions(timeout: 0.3))

        XCTAssertEqual(inventory.intents.count, 69, "every intent is still listed")
        // Windows are 0-31, 32-63, 64-68. The first answers in full, the second
        // in part, the third not at all — and the third does not discard the rest.
        XCTAssertEqual(inventory.intents.filter { !$0.phrasesFor("en-us").isEmpty }.count, quietFrom)
        XCTAssertTrue(inventory.hasPhrases)
        XCTAssertEqual(hub.describeWindows, [32, 32, 5], "all three windows were attempted")
        XCTAssertEqual(inventory.intents.first?.phrasesFor("en-us"), ["sentence 0"], "the first window kept its sentences")
        XCTAssertEqual(inventory.intents.last?.phrasesFor("en-us"), [], "the silent window's intents carry none")
    }

    func testTheCallersLanguageSpellingIsSentAsGiven() async throws {
        // The runtime folds the tag it receives, so the SDK sends what the
        // caller wrote rather than a normalised spelling — as the reference
        // does. The fake folds like ovos-core's manifest.
        let hub = FakeHubTransport()
        let inventory = try await client(hub).intents(languages: ["fr_FR"])
        XCTAssertEqual(inventory.languages, ["fr_FR"], "the caller's spelling is what the inventory reports")
        XCTAssertEqual(
            hub.emitted.filter { $0.type == ThalovantEvents.intentList }.map { $0.data["lang"]?.stringValue },
            ["fr_FR"],
            "sent verbatim, not normalised"
        )
        XCTAssertEqual(
            hub.emitted.first { $0.type == ThalovantEvents.intentDescribe }?.data["lang"]?.stringValue,
            "fr_FR"
        )
        let weatherIntent = try XCTUnwrap(inventory.intents.first { $0.skillId == weather })
        XCTAssertEqual(weatherIntent.phrasesFor("fr-fr").first, "quel temps fait-il", "and the hub answered it")
        XCTAssertEqual(weatherIntent.phrasesFor("fr_FR").first, "quel temps fait-il")

        let rows = try await client(hub).listIntents(lang: "FR-fr")
        XCTAssertEqual(rows.count, 1)
        let definitions = try await client(hub).describeIntent(
            skillId: weather, intentName: "current.weather", lang: "FR-fr"
        )
        XCTAssertEqual(definitions.first?.samples.first, "quel temps fait-il")
    }

    func testTheFallbackKeepsTheFirstEngineThatNamesAnIntent() async throws {
        // adapt is asked before padatious, so a name both list is adapt.
        let hub = FakeHubTransport(refuse: [ThalovantEvents.intentList], adaptNames: ["\(weather):current.weather"])
        let inventory = try await client(hub).intents(languages: ["en-us"])
        XCTAssertEqual(inventory.source, .engineManifests)
        let weatherIntent = try XCTUnwrap(inventory.intents.first { $0.name == "current.weather" })
        XCTAssertEqual(weatherIntent.engine, "adapt")
        XCTAssertEqual(inventory.intents.first { $0.skillId == shadow }?.engine, "padatious", "named by padatious alone")
        XCTAssertEqual(inventory.intents.count, 2, "a name both engines list is one intent")
    }

    func testARefusedListingIsAnErrorNotAnEmptyHub() async throws {
        // `ok: false` on a listing means the query failed. Reporting it as no
        // intents would show a person a device that can do nothing.
        let hub = FakeHubTransport(listError: "manifest unavailable")
        do {
            _ = try await client(hub).intents(languages: ["en-us"])
            XCTFail("expected ThalovantRuntimeError")
        } catch let error as ThalovantRuntimeError {
            XCTAssertTrue(error.message.contains("manifest unavailable"), error.message)
            XCTAssertTrue(error.message.contains(ThalovantEvents.intentList), error.message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(
            hub.emitted.allSatisfy { $0.type == ThalovantEvents.intentList },
            "a failed listing is not a refusal, so the engine-manifest fallback stays out of it"
        )
    }

    func testARefusedListingWithoutAReasonStillReadsAsAFailure() async throws {
        let hub = FakeHubTransport(listError: "   ")
        do {
            _ = try await client(hub).listIntents(lang: "en-us")
            XCTFail("expected ThalovantRuntimeError")
        } catch let error as ThalovantRuntimeError {
            XCTAssertTrue(error.message.contains("the hub refused the listing"), error.message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testADescribeThatDoesNotKnowTheIntentIsNotAnError() async throws {
        // The other half of the rule: describe answering `ok: false` is a real
        // answer -- the hub does not know that registration -- so the intent
        // is listed with no sentences rather than failing the inventory.
        let unknown: JSONValue = .object([
            "skill_id": .string(weather),
            "intent_name": "gone.away",
            "lang": "en-us",
            "method": "template",
            "enabled": true,
            "session_id": "default",
        ])
        let hub = FakeHubTransport(listRows: { _ in [unknown] })
        let inventory = try await client(hub).intents(languages: ["en-us"])
        XCTAssertEqual(inventory.intents.map { $0.id }, ["\(weather):gone.away"])
        XCTAssertEqual(inventory.intents[0].phrasesFor("en-us"), [])
        XCTAssertFalse(inventory.hasPhrases)
    }
}

/// The models on their own: parsing the observed shapes, language folding,
/// and the policy error built from a `hive.policy.denied` event.
final class IntentModelTests: XCTestCase {
    func testSameLanguageFoldsCaseAndSeparators() {
        XCTAssertTrue(sameLanguage("fr-fr", "fr_FR"))
        XCTAssertTrue(sameLanguage(" en-US ", "en-us"))
        XCTAssertFalse(sameLanguage("en-us", "en-gb"))
        XCTAssertFalse(sameLanguage("fr", "fr-fr"))
    }

    func testEventNamesMatchTheContract() {
        XCTAssertEqual(ThalovantEvents.intentList, "ovos.intent.list")
        XCTAssertEqual(ThalovantEvents.intentListResponse, "ovos.intent.list.response")
        XCTAssertEqual(ThalovantEvents.intentDescribe, "ovos.intent.describe")
        XCTAssertEqual(ThalovantEvents.intentDescribeResponse, "ovos.intent.describe.response")
        XCTAssertEqual(ThalovantEvents.adaptManifestGet, "intent.service.adapt.manifest.get")
        XCTAssertEqual(ThalovantEvents.adaptManifest, "intent.service.adapt.manifest")
        XCTAssertEqual(ThalovantEvents.padatiousManifestGet, "intent.service.padatious.manifest.get")
        XCTAssertEqual(ThalovantEvents.padatiousManifest, "intent.service.padatious.manifest")
        XCTAssertEqual(HubIntentSource.intentManifest.rawValue, "intent-manifest")
        XCTAssertEqual(HubIntentSource.engineManifests.rawValue, "engine-manifests")
    }

    func testPolicyDeniedErrorFromTheObservedEvent() {
        let event = ThalovantEvent(name: ThalovantEvents.policyDenied, data: [
            "denied_type": "ovos.intent.list",
            "code": "acl_disallowed_type",
            "reason": "ovos.intent.list not in allowed_types",
            "data": .object(["msg_type": "ovos.intent.list", "allowed": .array(["speak", "recognizer_loop:utterance"])]),
        ])
        let error = ThalovantPolicyDeniedError.fromEvent(event)
        XCTAssertEqual(error.deniedType, "ovos.intent.list")
        XCTAssertEqual(error.code, "acl_disallowed_type")
        XCTAssertEqual(error.reason, "ovos.intent.list not in allowed_types")
        XCTAssertEqual(error.allowed, ["speak", "recognizer_loop:utterance"])
        XCTAssertEqual(
            error.message,
            "The hub refused 'ovos.intent.list': ovos.intent.list not in allowed_types. "
                + "Allow this connection to publish 'ovos.intent.list' in the dashboard's connection settings."
        )
        XCTAssertEqual(error.description, error.message)
        XCTAssertEqual(error.localizedDescription, error.message)
    }

    func testOnlyStringEntriesSurviveInTheAllowedList() {
        // A number or a null in `allowed` is not a message type; carrying one
        // through would put "3" in front of an operator reading which types to
        // allow.
        let error = ThalovantPolicyDeniedError.fromEvent(ThalovantEvent(name: ThalovantEvents.policyDenied, data: [
            "denied_type": "ovos.intent.list",
            "code": "acl_disallowed_type",
            "data": .object(["allowed": .array(["speak", 3, .null, "recognizer_loop:utterance"])]),
        ]))
        XCTAssertEqual(error.allowed, ["speak", "recognizer_loop:utterance"])
    }

    func testPolicyDeniedErrorFallsBackToCodeThenToAGenericDetail() {
        let bare = ThalovantPolicyDeniedError.fromEvent(ThalovantEvent(name: ThalovantEvents.policyDenied, data: [:]))
        XCTAssertEqual(bare.deniedType, "")
        XCTAssertEqual(bare.allowed, [])
        XCTAssertTrue(bare.message.contains("refused by the hub's policy"), bare.message)
        let coded = ThalovantPolicyDeniedError(deniedType: "ovos.intent.describe", code: "acl_disallowed_type")
        XCTAssertTrue(coded.message.contains("acl_disallowed_type"), coded.message)
    }

    func testRegistrationParsesTheObservedRowLeniently() throws {
        XCTAssertNil(IntentRegistration.fromJSON(["intent_name": "x"]), "no skill")
        XCTAssertNil(IntentRegistration.fromJSON(["skill_id": "s", "intent_name": "  "]), "no intent")
        let row = try XCTUnwrap(IntentRegistration.fromJSON([
            "skill_id": " skill ", "intent_name": "name", "lang": "en-US", "method": "keyword",
        ]))
        XCTAssertEqual(row.skillId, "skill")
        XCTAssertEqual(row.intentName, "name")
        XCTAssertEqual(row.engine, "adapt")
        XCTAssertTrue(row.enabled, "a missing enabled is true")
        XCTAssertEqual(row.sessionId, "default")
        XCTAssertNil(row.definition)
        let disabled = try XCTUnwrap(IntentRegistration.fromJSON([
            "skill_id": "s", "intent_name": "n", "method": "other", "enabled": false, "session_id": "abc",
            "definition": .object(["samples": .array(["hi"])]),
        ]))
        XCTAssertFalse(disabled.enabled)
        XCTAssertEqual(disabled.engine, "other")
        XCTAssertEqual(disabled.sessionId, "abc")
        XCTAssertEqual(disabled.definition?["samples"], .array(["hi"]))
        XCTAssertEqual(IntentRegistration(skillId: "s", intentName: "n").engine, "unknown")
    }

    func testRegistrationCodableUsesTheWireKeys() throws {
        let json = """
        {"skill_id": "\(weather)", "intent_name": "current.weather", "lang": "en-us",
         "method": "template", "enabled": true, "session_id": "default"}
        """
        let row = try JSONDecoder().decode(IntentRegistration.self, from: Data(json.utf8))
        XCTAssertEqual(row.skillId, weather)
        XCTAssertEqual(row.engine, "padatious")
        let encoded = try ThalovantJSON.decodeObject(try JSONEncoder().encode(row))
        XCTAssertEqual(encoded["skill_id"]?.stringValue, weather)
        XCTAssertEqual(encoded["intent_name"]?.stringValue, "current.weather")
        XCTAssertEqual(encoded["session_id"]?.stringValue, "default")
        XCTAssertNil(encoded["definition"], "an absent definition is not encoded as null")
        XCTAssertEqual(try JSONDecoder().decode(IntentRegistration.self, from: try JSONEncoder().encode(row)), row)
        XCTAssertThrowsError(try JSONDecoder().decode(IntentRegistration.self, from: Data(#"{"lang": "en-us"}"#.utf8)))
    }

    func testDefinitionParsesTheDescribeItem() throws {
        XCTAssertNil(IntentDefinition.fromDescribeItem(["method": "template"]), "no definition")
        XCTAssertNil(IntentDefinition.fromDescribeItem(["definition": .object(["skill_id": "s"])]), "no intent")
        let definition = try XCTUnwrap(IntentDefinition.fromDescribeItem([
            "method": "template",
            "definition": .object([
                "skill_id": "s", "intent_name": "n", "lang": "fr-fr",
                "samples": .array(["  bonjour ", "", 3, "salut {name}"]),
                "blacklist": .array([]),
            ]),
        ]))
        XCTAssertEqual(definition.samples, ["bonjour", "salut {name}"])
        XCTAssertEqual(definition.engine, "padatious")
        XCTAssertEqual(definition.raw["blacklist"], .array([]))
        // The method may also live on the definition itself.
        let keyword = try XCTUnwrap(IntentDefinition.fromDescribeItem([
            "definition": .object(["skill_id": "s", "intent_name": "n", "method": "keyword"]),
        ]))
        XCTAssertEqual(keyword.engine, "adapt")
        XCTAssertEqual(keyword.samples, [])
    }

    func testDefinitionCodableRoundTrip() throws {
        let definition = IntentDefinition(
            skillId: "s", intentName: "n", lang: "en-us", method: "template",
            samples: ["hello"], raw: ["samples": .array(["hello"]), "skill_id": "s"]
        )
        let encoded = try ThalovantJSON.decodeObject(try JSONEncoder().encode(definition))
        XCTAssertEqual(encoded["skill_id"]?.stringValue, "s")
        XCTAssertEqual(encoded["intent_name"]?.stringValue, "n")
        XCTAssertEqual(encoded["samples"], .array(["hello"]))
        XCTAssertEqual(try JSONDecoder().decode(IntentDefinition.self, from: try JSONEncoder().encode(definition)), definition)
        let minimal = try JSONDecoder().decode(IntentDefinition.self, from: Data(#"{"skill_id": "s", "intent_name": "n"}"#.utf8))
        XCTAssertEqual(minimal, IntentDefinition(skillId: "s", intentName: "n"))
    }

    func testHubIntentPhrasesAndExamples() {
        let intent = HubIntent(
            skillId: "s", name: "n", engine: "padatious",
            phrases: ["en-us": ["tell me a long joke", "joke", "a joke about {topic}"], "fr-fr": []],
            languages: ["fr-fr", "en-us"]
        )
        XCTAssertEqual(intent.id, "s:n")
        XCTAssertEqual(intent.languages, ["fr-fr", "en-us"])
        XCTAssertEqual(intent.phrasesFor("EN_US"), ["tell me a long joke", "joke", "a joke about {topic}"])
        XCTAssertEqual(intent.phrasesFor("fr-fr"), [])
        XCTAssertEqual(intent.phrasesFor("de-de"), [])
        XCTAssertEqual(intent.examples(lang: "en-us"), ["joke", "tell me a long joke"])
        XCTAssertEqual(intent.examples(lang: "en-us", limit: 3), ["joke", "tell me a long joke", "a joke about {topic}"])
        XCTAssertEqual(intent.examples(), [], "defaults to the first language listed, which has no sentences")
        XCTAssertEqual(HubIntent(skillId: "s", name: "n", engine: "adapt", phrases: ["b": ["x"], "a": ["y"]]).languages, ["a", "b"])
    }

    func testExamplesKeepTheOriginalOrderAmongEqualSentences() {
        let intent = HubIntent(skillId: "s", name: "n", engine: "padatious", phrases: ["en-us": ["bbb", "aaa", "cc {x}", "dd"]])
        XCTAssertEqual(intent.examples(lang: "en-us", limit: 4), ["dd", "bbb", "aaa", "cc {x}"])
    }

    func testInventoryCodableAndJSONShape() throws {
        let inventory = HubIntentInventory(
            languages: ["en-us"],
            skills: [HubSkillIntents(skillId: "s", intents: [
                HubIntent(skillId: "s", name: "b", engine: "adapt"),
                HubIntent(skillId: "s", name: "a", engine: "padatious", phrases: ["en-us": ["hi"]]),
            ])],
            source: .engineManifests,
            denied: ["ovos.intent.list"]
        )
        XCTAssertEqual(inventory.intents.map { $0.id }, ["s:b", "s:a"])
        XCTAssertTrue(inventory.hasPhrases)
        XCTAssertEqual(inventory.skills[0].languages, ["en-us"])
        let payload = inventory.asJSON()
        XCTAssertEqual(payload["source"]?.stringValue, "engine-manifests")
        XCTAssertEqual(payload["denied"], .array(["ovos.intent.list"]))
        XCTAssertEqual(payload["skills"]?[0]?["skill_id"]?.stringValue, "s")
        XCTAssertEqual(payload["skills"]?[0]?["intents"]?[1]?["phrases"]?["en-us"], .array(["hi"]))
        let decoded = try JSONDecoder().decode(HubIntentInventory.self, from: try JSONEncoder().encode(inventory))
        XCTAssertEqual(decoded, inventory)
        // The Python SDK's as_dict() shape, without the languages an intent carries, still decodes.
        let foreign = try JSONDecoder().decode(HubIntentInventory.self, from: Data("""
        {"languages": ["en-us"], "source": "intent-manifest", "denied": [],
         "skills": [{"skill_id": "s", "languages": ["en-us"], "intents": [
           {"id": "s:a", "skill_id": "s", "name": "a", "engine": "padatious", "enabled": true,
            "phrases": {"en-us": ["hi"]}}]}]}
        """.utf8))
        XCTAssertEqual(foreign.source, .intentManifest)
        XCTAssertEqual(foreign.intents[0].languages, ["en-us"])
        XCTAssertEqual(foreign.intents[0].phrasesFor("en-US"), ["hi"])
        XCTAssertFalse(HubIntentInventory(languages: [], skills: []).hasPhrases)
    }

    func testEngineManifestNamesSplitAtTheFirstColon() {
        let inventory = inventoryFromNames(
            [("adapt", ["skill-a:one", "bare"]), ("padatious", ["skill-a:two:extra", "skill-b:one"])],
            languages: ["en-us"],
            denied: "ovos.intent.list"
        )
        XCTAssertEqual(inventory.skills.map { $0.skillId }, ["", "skill-a", "skill-b"])
        XCTAssertEqual(inventory.skills[0].intents.map { $0.name }, ["bare"])
        XCTAssertEqual(inventory.skills[1].intents.map { $0.name }, ["one", "two:extra"])
        XCTAssertEqual(inventory.skills[1].intents.map { $0.engine }, ["adapt", "padatious"])
        XCTAssertEqual(inventory.source, .engineManifests)
        XCTAssertEqual(inventory.denied, ["ovos.intent.list"])
        XCTAssertFalse(inventory.hasPhrases)
    }
}
