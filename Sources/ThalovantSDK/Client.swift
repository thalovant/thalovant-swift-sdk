import Foundation

/// Handle for a registered event handler; `close()` removes it.
public final class ThalovantSubscription: @unchecked Sendable {
    private let closeFn: () -> Void
    private let lock = NSLock()
    private var closed = false

    init(_ closeFn: @escaping () -> Void) {
        self.closeFn = closeFn
    }

    public func close() {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        if !alreadyClosed {
            closeFn()
        }
    }

    public func unsubscribe() {
        close()
    }
}

/// Data-plane client for a Thalovant hub. Speaks v3 Noise over WSS;
/// requesting the HTTPS or MQTT transport throws
/// `ThalovantUnsupportedProtocolError`.
public final class ThalovantClient: @unchecked Sendable {
    public let identity: ThalovantIdentity
    let transport: any HiveMindBusTransport
    private let replySettle: TimeInterval
    private let emptyReplyWait: TimeInterval
    private let correlationLock = NSLock()
    private var activeAskIDs = Set<String>()
    private var activeQueryIDs = Set<String>()

    /// The conversation each session id is in the middle of.
    ///
    /// A hub keeps nothing for a named session, so what the last turn activated
    /// comes back on `ovos.utterance.handled` and has to be sent again with the
    /// next utterance or it is gone. Bounded, because a long-lived client
    /// handed a fresh session id per turn must not accumulate one entry per
    /// turn for ever; a satellite runs one session for its whole life.
    private var conversations: [String: [String: JSONValue]] = [:]
    private static let maxRememberedConversations = 32

    /// Keep the session a hub returned, to send with the next utterance.
    func rememberConversation(_ sessionId: String, session: [String: JSONValue]?) {
        var kept: [String: JSONValue] = [:]
        for field in conversationSessionFields {
            guard let value = session?[field] else { continue }
            switch value {
            case .null: continue
            case .array(let items) where items.isEmpty: continue
            case .object(let fields) where fields.isEmpty: continue
            default: kept[field] = value
            }
        }
        correlationLock.lock()
        defer { correlationLock.unlock() }
        // Forgetting is the state, not the absence of one: a turn that ended
        // with nothing active must not leave the old entry to resurrect it.
        conversations.removeValue(forKey: sessionId)
        guard !kept.isEmpty else { return }
        if conversations.count >= Self.maxRememberedConversations, let oldest = conversations.keys.first {
            conversations.removeValue(forKey: oldest)
        }
        conversations[sessionId] = kept
    }

    /// Put the last turn's conversation state back into this turn.
    func continueConversation(_ context: [String: JSONValue], sessionId: String) -> [String: JSONValue] {
        correlationLock.lock()
        let previous = conversations[sessionId]
        correlationLock.unlock()
        guard let previous else { return context }
        var next = context
        var session: [String: JSONValue] = [:]
        if case .object(let existing)? = context["session"] { session = existing }
        next["session"] = .object(carryConversation(previous: previous, session: session))
        return next
    }

    func reserveRuntimeID(_ id: String, query: Bool) throws -> ThalovantSubscription {
        try correlationLock.locked {
            let inserted = query ? activeQueryIDs.insert(id).inserted : activeAskIDs.insert(id).inserted
            guard inserted else { throw ThalovantRuntimeError("The correlation ID is already active for this operation type on this client.") }
        }
        return ThalovantSubscription {
            self.correlationLock.locked {
                if query { self.activeQueryIDs.remove(id) } else { self.activeAskIDs.remove(id) }
            }
        }
    }

    public init(
        identity: ThalovantIdentity,
        hubProtocol: HubProtocol = .wss,
        userAgent: String = defaultThalovantUserAgent,
        replySettle: TimeInterval = 0.25,
        emptyReplyWait: TimeInterval = 5,
        noiseStore: (any ThalovantNoiseStore)? = nil
    ) throws {
        switch hubProtocol {
        case .wss:
            break
        case .https:
            throw ThalovantUnsupportedProtocolError(
                "The HTTPS data-plane transport is not supported by the Swift SDK yet; use wss."
            )
        case .mqtt:
            throw ThalovantUnsupportedProtocolError(
                "The MQTT data-plane transport is not supported by the Swift SDK yet; use wss."
            )
        }
        guard identity.endpointFor(.wss) != nil else {
            throw ThalovantUnsupportedProtocolError(
                "WSS is enabled, but the identity does not include a WSS endpoint."
            )
        }
        self.identity = identity
        self.transport = HiveMindWSSTransport(identity: identity, userAgent: userAgent, noiseStore: noiseStore)
        self.replySettle = replySettle
        self.emptyReplyWait = emptyReplyWait
    }

    /// A client over an already-built transport. The test suite uses it to
    /// drive the request/reply paths against an in-memory hub.
    init(
        identity: ThalovantIdentity,
        transport: any HiveMindBusTransport,
        replySettle: TimeInterval = 0.25,
        emptyReplyWait: TimeInterval = 5
    ) {
        self.identity = identity
        self.transport = transport
        self.replySettle = replySettle
        self.emptyReplyWait = emptyReplyWait
    }

    public static func fromIdentityFile(_ path: String, hubProtocol: HubProtocol = .wss) throws -> ThalovantClient {
        try ThalovantClient(identity: ThalovantIdentity.fromFile(path), hubProtocol: hubProtocol)
    }

    public func connect(timeout: TimeInterval = 6) async throws {
        try await transport.connect(timeout: timeout)
    }

    public func close() async {
        await transport.disconnect()
    }

    // MARK: Events

    /// Registers a handler for a named bus event, optionally filtered by
    /// correlation ids. Returns a subscription; call `close()` to remove it.
    @discardableResult
    public func on(
        _ eventName: String,
        sessionId: String? = nil,
        requestId: String? = nil,
        handler: @escaping (ThalovantEvent) -> Void
    ) -> ThalovantSubscription {
        let id = transport.addBusHandler { payload in
            guard let event = ThalovantEvent.fromBusPayload(payload), event.name == eventName else { return }
            // The request id decides when both sides carry one: a hub does not
            // echo a client-declared session id, it substitutes its own
            // (observed live on 2026-09-03), so comparing session ids rejected
            // replies the request id had already identified as ours.
            if let requestId, let eventRequest = event.requestId {
                if eventRequest != requestId { return }
            } else if let sessionId, let eventSession = event.sessionId,
                      eventSession != sessionId { return }
            handler(event)
        }
        return ThalovantSubscription { [transport] in
            transport.removeBusHandler(id)
        }
    }

    /// Listens to one of the hive's own frame kinds.
    ///
    /// A hub relays more than this client's conversation: `broadcast` is aimed
    /// down at every child, `propagate` walks the whole hive, `escalate` goes
    /// up to the parent, `intercom` is addressed node to node, and `rendezvous`
    /// is the mailbox peers use to find each other through NAT. See
    /// `hiveKinds`. Returns a subscription; call `close()` to remove it.
    @discardableResult
    public func onHive(
        _ kind: String,
        handler: @escaping (HiveMessage) -> Void
    ) throws -> ThalovantSubscription {
        guard hiveKinds.contains(kind) else {
            // Named rather than silently never firing: subscribing to "bus" or
            // to a typo is the kind of mistake that looks like a quiet hub.
            throw ThalovantRuntimeError(
                "\(kind) is not a hive frame kind; expected one of \(hiveKinds.joined(separator: ", "))."
            )
        }
        let id = transport.addMessageHandler { message in
            guard message.msgType == kind else { return }
            handler(message)
        }
        return ThalovantSubscription { [transport] in transport.removeMessageHandler(id) }
    }

    /// Listens for binary frames: rendered speech, and files.
    ///
    /// This is what a hub sends back for `speak:synth` -- the audio itself, so
    /// a client with no synthesiser can still speak -- and how it hands over a
    /// file. Delivered by subscription and not on a reply, because a binary
    /// frame carries no request id: it cannot be attributed to one `ask`. Its
    /// `utterance` is the only thread back to a turn.
    @discardableResult
    public func onBinary(handler: @escaping (ThalovantBinary) -> Void) -> ThalovantSubscription {
        let id = transport.addMessageHandler { message in
            guard let binary = message.binary else { return }
            handler(binary)
        }
        return ThalovantSubscription { [transport] in transport.removeMessageHandler(id) }
    }

    /// Sends an event across the hive; every node sees it once.
    public func propagate(_ eventType: String, data: JSONObject = [:], context: JSONObject = [:]) async throws {
        try await sendHive("propagate", eventType, data: data, context: context)
    }

    /// Sends an event up to the parent node.
    public func escalate(_ eventType: String, data: JSONObject = [:], context: JSONObject = [:]) async throws {
        try await sendHive("escalate", eventType, data: data, context: context)
    }

    /// Sends an event down to every child of this hub. **Admin only.**
    ///
    /// A hub requires admin standing and the `can_broadcast` grant, and a
    /// client that sends one without them is not answered with an error -- it
    /// is disconnected for misbehaviour. Nothing here can check first: a hub's
    /// HELLO carries its public key, peer name and node id, and nothing about
    /// what this client may do, so a refusal arrives as a closed socket on the
    /// next read.
    public func broadcast(_ eventType: String, data: JSONObject = [:], context: JSONObject = [:]) async throws {
        try await sendHive("broadcast", eventType, data: data, context: context)
    }

    private func sendHive(
        _ kind: String,
        _ eventType: String,
        data: JSONObject,
        context: JSONObject
    ) async throws {
        try await connect()
        // Nested on purpose: a hub reads message.payload as a HiveMessage of its
        // own and rewrites the route on it, so a flat frame loses the route.
        let inner: JSONObject = [
            "msg_type": .string("bus"),
            "payload": .object([
                "type": .string(eventType),
                "data": .object(data),
                "context": .object(contextWithIdentityMetadata(context)),
            ]),
        ]
        try await transport.sendHiveFrame(HiveMessage(msgType: kind, payload: inner))
    }

    /// Emits a bus event to the hub.
    public func emit(_ eventType: String, data: JSONObject = [:], context: JSONObject = [:]) async throws {
        try await connect()
        try await transport.emitBus(type: eventType, data: data, context: contextWithIdentityMetadata(context))
    }

    /// Sends an utterance without waiting for a reply.
    public func sendUtterance(
        _ text: String,
        lang: String = "en-us",
        context: JSONObject = [:],
        sessionId: String? = nil,
        requestId: String? = nil
    ) async throws {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw ThalovantRuntimeError("sendUtterance() requires a non-empty text prompt.")
        }
        let correlated = contextWithCorrelation(
            context,
            sessionId: sessionId ?? newSessionId(),
            siteId: identity.siteId,
            lang: lang,
            requestId: requestId ?? newRequestId()
        )
        try await emit(ThalovantEvents.recognizerLoopUtterance, data: utterancePayload(text: prompt, lang: lang), context: correlated)
    }

    // MARK: Ask

    /// Sends an utterance and aggregates the correlated `speak` replies into a
    /// single `ThalovantReply`, using the request id for correlation.
    public func ask(
        _ text: String,
        timeout: TimeInterval = 12,
        lang: String = "en-us",
        context: JSONObject = [:],
        sessionId: String? = nil,
        requestId: String? = nil,
        replySettle: TimeInterval? = nil,
        emptyReplyWait: TimeInterval? = nil
    ) async throws -> ThalovantReply {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw ThalovantRuntimeError("ask() requires a non-empty text prompt.")
        }
        try validateRuntimeTimeout(timeout)
        let emptyReplyWait = emptyReplyWait ?? self.emptyReplyWait
        let replySettle = replySettle ?? self.replySettle
        guard emptyReplyWait.isFinite, emptyReplyWait >= 0, replySettle.isFinite, replySettle >= 0 else {
            throw ThalovantRuntimeError("Reply waits must be finite and non-negative.")
        }
        try Task.checkCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        @Sendable func remaining() -> TimeInterval { max(0, timeout - (ProcessInfo.processInfo.systemUptime - started)) }
        let requestId = requestId ?? newRequestId()
        let correlation = try reserveRuntimeID(requestId, query: false)
        defer { correlation.close() }
        let sessionId = sessionId ?? newSessionId()
        let correlatedContext = contextWithCorrelation(
            continueConversation(contextWithIdentityMetadata(context), sessionId: sessionId),
            sessionId: sessionId,
            siteId: identity.siteId,
            lang: lang,
            requestId: requestId
        )
        let state = AskState()
        let handlerId = transport.addBusHandler { [weak self] payload in
            guard let event = ThalovantEvent.fromBusPayload(payload) else { return }
            state.process(event, requestId: requestId)
            // The end of the turn is the one place a hub states what the
            // conversation now is, and it keeps none of it for a named session.
            if event.name == ThalovantEvents.utteranceHandled, event.requestId == requestId {
                var session: [String: JSONValue]?
                if case .object(let existing)? = event.context["session"] { session = existing }
                self?.rememberConversation(sessionId, session: session)
            }
        }
        defer { transport.removeBusHandler(handlerId) }

        // Keep I/O ownership in its task while the caller waits on correlated progress.
        // Cancellation stops the caller wait; an admitted physical write keeps its own lifetime.
        let operation = Task {
            do {
                try Task.checkCancellation()
                let connectBudget = remaining()
                guard connectBudget > 0 else { throw ThalovantTimeoutError("Request budget expired before connecting.") }
                try await self.connect(timeout: connectBudget)
                try Task.checkCancellation()
                try await self.transport.emitBus(type: ThalovantEvents.recognizerLoopUtterance,
                    data: utterancePayload(text: prompt, lang: lang), context: correlatedContext)
            } catch { state.failOperation(error, deadline: started + timeout, replySettle: replySettle, emptyReplyWait: emptyReplyWait) }
        }
        defer { operation.cancel() }
        do {
            try await state.progressGate.wait(timeout: remaining(),
                timeoutError: ThalovantTimeoutError("Hub did not finish handling the utterance within the request budget."))
        } catch is ThalovantTimeoutError {
            let snapshot = state.snapshot()
            if snapshot.fragments.isEmpty && snapshot.failureEvent == nil && snapshot.softFailureEvent == nil && snapshot.operationFailure == nil {
                throw ThalovantTimeoutError("Hub did not finish handling the utterance within the request budget.")
            }
        }
        func bounded(_ window: TimeInterval, since: TimeInterval?) -> TimeInterval {
            min(remaining(), max(0, window - (since.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)))
        }
        let afterProgress = state.snapshot()
        if afterProgress.fragments.isEmpty && afterProgress.failureEvent == nil && afterProgress.operationFailure == nil {
            try await state.replyGate.wait(timeout: bounded(emptyReplyWait, since: afterProgress.emptyStartedAt), timeoutError: nil)
        }
        // Settling is optional and shares the original budget. Hard failure wakes it immediately.
        let afterEmpty = state.snapshot()
        if afterEmpty.failureEvent == nil && afterEmpty.operationFailure == nil && !afterEmpty.fragments.isEmpty {
            try await state.terminalGate.wait(timeout: bounded(replySettle, since: afterEmpty.firstSpeechAt), timeoutError: nil)
        }
        try Task.checkCancellation()

        let final = state.snapshot()
        if let error = final.operationFailure { throw error }
        // A soft intent-miss becomes the surfaced failure only if no reply (not
        // even a fallback) arrived; a reply means a fallback recovered the turn.
        let effectiveFailure = final.failureEvent ?? (final.fragments.isEmpty ? final.softFailureEvent : nil)
        if effectiveFailure == nil && final.fragments.isEmpty {
            throw ThalovantTimeoutError(
                "Hub handled the utterance but did not emit a speak reply within \(Int(emptyReplyWait * 1000))ms."
            )
        }
        if let failure = effectiveFailure, final.fragments.isEmpty {
            let message = failure.text.isEmpty ? "Hub reported \(failure.name)." : failure.text
            throw ThalovantRuntimeError(message)
        }
        let replyText = final.fragments.joined(separator: " ")
        return ThalovantReply(
            text: replyText,
            displayText: stripSsml(replyText),
            utterances: final.fragments,
            handled: effectiveFailure == nil,
            ok: effectiveFailure == nil,
            sessionId: final.responseSessionId ?? sessionId,
            requestId: requestId,
            events: final.events,
            failureEvent: effectiveFailure,
            droppedMedia: final.droppedMedia
        )
    }

    // MARK: Intents

    /// Everything the hub can be asked, per language, grouped by skill.
    ///
    /// Read from the runtime's intent manifest over this session, so no
    /// control-plane credential is involved. Each intent carries the sentences
    /// a person says to reach it, as the skill wrote them, `{slot}`
    /// placeholders included. `languages` defaults to `en-us`.
    ///
    /// Throws `ThalovantPolicyDeniedError` when the hub refuses the query and
    /// `options.fallback` is off; with it on (the default), a hub allowed for
    /// only the engines' manifests yields intent names with `source` set to
    /// `.engineManifests` and `denied` naming the refused query.
    public func intents(
        languages: [String]? = nil,
        options: IntentInventoryOptions = IntentInventoryOptions()
    ) async throws -> HubIntentInventory {
        let chosen = languages.flatMap { $0.isEmpty ? nil : $0 } ?? [defaultIntentLanguage]
        return try await intentInventory(languages: chosen, options: options)
    }

    /// The hub's intent manifest for one language, one row per registration
    /// (`ovos.intent.list`). `lang` defaults to `en-us`.
    public func listIntents(
        lang: String? = nil,
        options: ListIntentsOptions = ListIntentsOptions()
    ) async throws -> [IntentRegistration] {
        try await listIntentRegistrations(lang: lang ?? defaultIntentLanguage, options: options)
    }

    /// The registrations behind one intent in one language, sentences included
    /// (`ovos.intent.describe`). Empty for a registration the hub does not
    /// know. `lang` defaults to `en-us`.
    public func describeIntent(
        skillId: String,
        intentName: String,
        lang: String? = nil,
        options: DescribeIntentOptions = DescribeIntentOptions()
    ) async throws -> [IntentDefinition] {
        try await describeIntentDefinitions(
            skillId: skillId,
            intentName: intentName,
            lang: lang ?? defaultIntentLanguage,
            options: options
        )
    }

    private func contextWithIdentityMetadata(_ context: JSONObject) -> JSONObject {
        guard !identity.metadata.isEmpty else { return context }
        var merged = identity.metadata
        if let existing = context["metadata"]?.objectValue {
            for (key, value) in existing {
                merged[key] = value
            }
        }
        var next = context
        next["metadata"] = .object(merged)
        return next
    }
}

/// Accumulates correlated events for one `ask()` call.
final class AskState: @unchecked Sendable {
    struct Snapshot {
        let fragments: [String]
        let events: [ThalovantEvent]
        let failureEvent: ThalovantEvent?
        let softFailureEvent: ThalovantEvent?
        let handled: Bool
        let operationFailure: Error?
        let responseSessionId: String?
        let firstSpeechAt: TimeInterval?
        let emptyStartedAt: TimeInterval?
        let droppedMedia: Int
    }

    private let lock = NSLock()
    private var fragments: [String] = []
    private var events: [ThalovantEvent] = []
    private var mediaBudget = ReplyMediaBudget()
    private var failureEvent: ThalovantEvent?
    // An intent miss (ovos.intent.unmatched / complete_intent_failure) is a SOFT
    // failure: it ends phase 1 promptly but still allows the empty-reply grace
    // period for a fallback skill to answer. Only surfaced if no reply arrives.
    private var softFailureEvent: ThalovantEvent?
    private var handled = false
    private var firstSpeechAt: TimeInterval?, emptyStartedAt: TimeInterval?
    private var operationFailure: Error?
    private var responseSessionId: String?

    /// Opens when the utterance is handled or the first fragment arrives.
    let progressGate = AsyncGate()
    /// Opens when the first speak fragment arrives.
    let replyGate = AsyncGate()
    let terminalGate = AsyncGate()

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(fragments: fragments, events: events, failureEvent: failureEvent, softFailureEvent: softFailureEvent, handled: handled, operationFailure: operationFailure, responseSessionId: responseSessionId, firstSpeechAt: firstSpeechAt, emptyStartedAt: emptyStartedAt, droppedMedia: mediaBudget.dropped)
    }

    /// Correlation rule (mirrors the Node SDK): only events carrying the
    /// matching request id participate in the reply.
    func process(_ event: ThalovantEvent, requestId: String) {
        guard event.requestId == requestId else { return }
        lock.lock()
        defer { lock.unlock() }
        guard failureEvent == nil && operationFailure == nil else { return }
        guard mediaBudget.accept(event) else { return }
        switch event.name {
        case ThalovantEvents.audioQueue:
            events.append(event)
        case ThalovantEvents.speak, ThalovantEvents.ovosUtteranceSpeak:
            events.append(event)
            let normalized = normalizeFragment(event.text)
            if !normalized.isEmpty && fragments.last != normalized {
                if firstSpeechAt == nil { firstSpeechAt = ProcessInfo.processInfo.systemUptime }
                fragments.append(normalized); replyGate.open(); progressGate.open()
            }
        case ThalovantEvents.utteranceHandled:
            if emptyStartedAt == nil { emptyStartedAt = ProcessInfo.processInfo.systemUptime }
            events.append(event); handled = true; progressGate.open()
        case ThalovantEvents.intentFailure, ThalovantEvents.intentUnmatched:
            if emptyStartedAt == nil { emptyStartedAt = ProcessInfo.processInfo.systemUptime }
            events.append(event); softFailureEvent = event; handled = true; progressGate.open()
        case ThalovantEvents.policyDenied, ThalovantEvents.queryTimeout:
            events.append(event); failureEvent = event; handled = true
            progressGate.open(); replyGate.open(); terminalGate.open()
        default: return
        }
        if responseSessionId == nil, let id = event.sessionId, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { responseSessionId = id }
    }

    func failOperation(_ error: Error, deadline: TimeInterval, replySettle: TimeInterval, emptyReplyWait: TimeInterval) {
        guard !(error is CancellationError) else { return }
        lock.locked {
            let phaseEnd = firstSpeechAt.map { $0 + replySettle } ?? emptyStartedAt.map { $0 + emptyReplyWait } ?? deadline
            guard failureEvent == nil, operationFailure == nil,
                  ProcessInfo.processInfo.systemUptime < min(deadline, phaseEnd) else { return }
            operationFailure = error
            progressGate.open(); replyGate.open(); terminalGate.open()
        }
    }

    private func normalizeFragment(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
