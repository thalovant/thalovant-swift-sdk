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

/// Data-plane client for a Thalovant hub. Version 0.1 speaks WSS only;
/// requesting the HTTPS or MQTT transport throws
/// `ThalovantUnsupportedProtocolError`.
public final class ThalovantClient: @unchecked Sendable {
    public let identity: ThalovantIdentity
    let transport: HiveMindWSSTransport
    private let replySettle: TimeInterval
    private let emptyReplyWait: TimeInterval
    private let lock = NSLock()
    private var connected = false

    public init(
        identity: ThalovantIdentity,
        hubProtocol: HubProtocol = .wss,
        userAgent: String = defaultThalovantUserAgent,
        replySettle: TimeInterval = 0.25,
        emptyReplyWait: TimeInterval = 5
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
        self.transport = HiveMindWSSTransport(identity: identity, userAgent: userAgent)
        self.replySettle = replySettle
        self.emptyReplyWait = emptyReplyWait
    }

    public static func fromIdentityFile(_ path: String, hubProtocol: HubProtocol = .wss) throws -> ThalovantClient {
        try ThalovantClient(identity: ThalovantIdentity.fromFile(path), hubProtocol: hubProtocol)
    }

    public func connect(timeout: TimeInterval = 6) async throws {
        let alreadyConnected = lock.locked { connected }
        if alreadyConnected { return }
        try await transport.connect(timeout: timeout)
        lock.locked { connected = true }
    }

    public func close() async {
        await transport.disconnect()
        lock.locked { connected = false }
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
            if let sessionId, let eventSession = event.sessionId, eventSession != sessionId { return }
            if let requestId, let eventRequest = event.requestId, eventRequest != requestId { return }
            handler(event)
        }
        return ThalovantSubscription { [transport] in
            transport.removeBusHandler(id)
        }
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
        let requestId = requestId ?? newRequestId()
        let sessionId = sessionId ?? newSessionId()
        let correlatedContext = contextWithCorrelation(
            contextWithIdentityMetadata(context),
            sessionId: sessionId,
            siteId: identity.siteId,
            lang: lang,
            requestId: requestId
        )
        try await connect()

        let state = AskState()
        let handlerId = transport.addBusHandler { payload in
            guard let event = ThalovantEvent.fromBusPayload(payload) else { return }
            state.process(event, requestId: requestId)
        }
        defer { transport.removeBusHandler(handlerId) }

        try await transport.emitBus(
            type: ThalovantEvents.recognizerLoopUtterance,
            data: utterancePayload(text: prompt, lang: lang),
            context: correlatedContext
        )

        // Phase 1: wait until the hub reports the utterance handled or the
        // first speak fragment arrives.
        try await state.progressGate.wait(
            timeout: timeout,
            timeoutError: ThalovantTimeoutError(
                "Hub did not finish handling the utterance within \(Int(timeout * 1000))ms."
            )
        )

        // Phase 2: the hub finished handling but has not spoken yet; give the
        // reply a grace period.
        let emptyReplyWait = emptyReplyWait ?? self.emptyReplyWait
        if state.snapshot().fragments.isEmpty && state.snapshot().failureEvent == nil && emptyReplyWait > 0 {
            try await state.replyGate.wait(timeout: emptyReplyWait, timeoutError: nil)
        }

        // Phase 3: let trailing fragments settle briefly.
        let replySettle = replySettle ?? self.replySettle
        if replySettle > 0 {
            try await Task.sleep(nanoseconds: UInt64(replySettle * 1_000_000_000))
        }

        let final = state.snapshot()
        if final.failureEvent == nil && final.fragments.isEmpty {
            throw ThalovantTimeoutError(
                "Hub handled the utterance but did not emit a speak reply within \(Int(emptyReplyWait * 1000))ms."
            )
        }
        if let failure = final.failureEvent, final.fragments.isEmpty {
            let message = failure.text.isEmpty ? "Hub reported \(failure.name)." : failure.text
            throw ThalovantRuntimeError(message)
        }
        let replyText = final.fragments.joined(separator: " ")
        return ThalovantReply(
            text: replyText,
            displayText: stripSsml(replyText),
            utterances: final.fragments,
            handled: final.failureEvent == nil,
            ok: final.failureEvent == nil,
            sessionId: sessionId,
            requestId: requestId,
            events: final.events,
            failureEvent: final.failureEvent
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
        let handled: Bool
    }

    private let lock = NSLock()
    private var fragments: [String] = []
    private var events: [ThalovantEvent] = []
    private var failureEvent: ThalovantEvent?
    private var handled = false

    /// Opens when the utterance is handled or the first fragment arrives.
    let progressGate = AsyncGate()
    /// Opens when the first speak fragment arrives.
    let replyGate = AsyncGate()

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(fragments: fragments, events: events, failureEvent: failureEvent, handled: handled)
    }

    /// Correlation rule (mirrors the Node SDK): only events carrying the
    /// matching request id participate in the reply.
    func process(_ event: ThalovantEvent, requestId: String) {
        guard event.requestId == requestId else { return }
        switch event.name {
        case ThalovantEvents.speak, ThalovantEvents.ovosUtteranceSpeak:
            let normalized = normalizeFragment(event.text)
            lock.lock()
            events.append(event)
            if !normalized.isEmpty && fragments.last != normalized {
                fragments.append(normalized)
                lock.unlock()
                replyGate.open()
                progressGate.open()
                return
            }
            lock.unlock()
        case ThalovantEvents.utteranceHandled:
            lock.lock()
            events.append(event)
            handled = true
            lock.unlock()
            progressGate.open()
        case ThalovantEvents.intentFailure:
            lock.lock()
            events.append(event)
            lock.unlock()
        case ThalovantEvents.policyDenied, ThalovantEvents.queryTimeout:
            lock.lock()
            events.append(event)
            failureEvent = event
            handled = true
            lock.unlock()
            progressGate.open()
        default:
            break
        }
    }

    private func normalizeFragment(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
