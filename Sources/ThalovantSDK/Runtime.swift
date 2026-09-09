import Foundation

/// Local connection status. Endpoints and credentials are deliberately absent.
public struct ThalovantConnectionInfo: Equatable, Sendable {
    public let phase: String
    public let lastError: String?
    public init(phase: String = "idle", lastError: String? = nil) { self.phase = phase; self.lastError = lastError }
}

public struct ThalovantHealth: Equatable, Sendable {
    public let connected: Bool
    public let handshakeComplete: Bool
    public let transportAlive: Bool
    public let connection: ThalovantConnectionInfo
    public var ok: Bool { connected && handshakeComplete && transportAlive && connection.lastError == nil }
}

public struct ThalovantDoctorCheck: Equatable, Sendable {
    public let name: String
    public let ok: Bool
    public let detail: String
}
public struct ThalovantDoctorReport: Equatable, Sendable {
    public let checks: [ThalovantDoctorCheck]
    public var ok: Bool { checks.allSatisfy { $0.ok } }
}

extension ThalovantClient {
    public func connectionInfo() -> ThalovantConnectionInfo { transport.connectionInfo }
    public func connectWithInfo(timeout: TimeInterval = 6) async throws -> ThalovantConnectionInfo {
        try await connect(timeout: timeout)
        return connectionInfo()
    }
    /// Snapshot of the authenticated transport; it does not assert health of every hub skill.
    public func healthcheck(timeout: TimeInterval = 6) async throws -> ThalovantHealth {
        try await connect(timeout: timeout)
        return ThalovantHealth(connected: transport.connected, handshakeComplete: transport.handshakeComplete,
            transportAlive: transport.connected, connection: connectionInfo())
    }
    public func doctor(timeout: TimeInterval = 6) async throws -> ThalovantDoctorReport {
        var checks = [ThalovantDoctorCheck(name: "identity", ok: true, detail: "Client identity loaded."),
            ThalovantDoctorCheck(name: "endpoint", ok: identity.endpointFor(.wss) != nil, detail: "WSS endpoint availability.")]
        do {
            let health = try await healthcheck(timeout: timeout)
            checks.append(ThalovantDoctorCheck(name: "connect", ok: health.ok, detail: "Authenticated WSS transport state."))
        } catch is CancellationError { throw CancellationError() }
          catch { checks.append(ThalovantDoctorCheck(name: "connect", ok: false, detail: "Authenticated WSS connection failed.")) }
        return ThalovantDoctorReport(checks: checks)
    }

    /// Wait for one event; cancellation, timeout and transport loss remove the subscription.
    public func waitForEvent(_ eventName: String, timeout: TimeInterval = 12,
        sessionId: String? = nil, requestId: String? = nil,
        predicate: @escaping @Sendable (ThalovantEvent) -> Bool = { _ in true }
    ) async throws -> ThalovantEvent {
        try validateRuntimeTimeout(timeout)
        let started = ProcessInfo.processInfo.systemUptime
        let state = RuntimeEventState()
        let subscription = on(eventName, sessionId: sessionId, requestId: requestId) { event in
            if predicate(event) { state.keep(event) }
        }
        defer { subscription.close() }
        try await connect(timeout: timeout)
        try await waitRuntime(state.gate, timeout: max(0, timeout - (ProcessInfo.processInfo.systemUptime - started)))
        guard let event = state.value else { throw ThalovantTimeoutError("Hub did not emit the requested event.") }
        return event
    }

    /// A bounded asynchronous event stream. Overflow fails explicitly instead of dropping events silently.
    public func listen(_ eventName: String, timeout: TimeInterval? = nil, maxEvents: Int? = nil,
        sessionId: String? = nil, requestId: String? = nil,
        predicate: @escaping @Sendable (ThalovantEvent) -> Bool = { _ in true }
    ) -> AsyncThrowingStream<ThalovantEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            if let timeout, !timeout.isFinite || timeout <= 0 {
                continuation.finish(throwing: ThalovantRuntimeError("timeout must be finite and positive.")); return
            }
            if let maxEvents, maxEvents < 0 {
                continuation.finish(throwing: ThalovantRuntimeError("maxEvents must be non-negative.")); return
            }
            if maxEvents == 0 { continuation.finish(); return }
            let counter = RuntimeStreamCounter()
            let subscription = on(eventName, sessionId: sessionId, requestId: requestId) { event in
                guard predicate(event) else { return }
                switch continuation.yield(event) {
                case .dropped: continuation.finish(throwing: ThalovantRuntimeError("Event stream buffer overflow."))
                case .enqueued:
                    if let maxEvents, counter.increment() >= maxEvents { continuation.finish() }
                case .terminated: break
                @unknown default: break
                }
            }
            let monitor = Task {
                let deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 }
                do {
                    try await connect(timeout: min(timeout ?? 6, 6))
                    while !Task.isCancelled {
                        if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { continuation.finish(); return }
                        try requireRuntimeConnected()
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                } catch is CancellationError { continuation.finish() }
                  catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in subscription.close(); monitor.cancel() }
        }
    }

    public func sendAction(_ payload: String, title: String? = nil, lang: String = "en-us",
        context: JSONObject = [:], sessionId: String? = nil, requestId: String? = nil
    ) async throws {
        let prompt = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ThalovantRuntimeError("sendAction() requires a non-empty payload.") }
        let input: JSONObject = ["kind": .string("action"), "title": title.map(JSONValue.string) ?? .null, "payload": .string(prompt)]
        try await sendUtterance(prompt, lang: lang, context: mergeRuntimeContext(context, ["input": .object(input)]),
            sessionId: sessionId, requestId: requestId)
    }

    /// Exact text and structured metadata are carried in both event data and context.
    public func sendCode(_ value: String, kind: String = "code", label: String? = nil, lang: String = "en-us",
        context: JSONObject = [:], sessionId: String? = nil, requestId: String? = nil
    ) async throws {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw ThalovantRuntimeError("sendCode() requires a non-empty value.") }
        let input: JSONObject = ["kind": .string(kind), "label": label.map(JSONValue.string) ?? .null,
            "value": .string(code), "exact": .bool(true)]
        var data = utterancePayload(text: code, lang: lang); data["input"] = .object(input)
        let correlated = contextWithCorrelation(mergeRuntimeContext(context, ["input": .object(input)]),
            sessionId: sessionId ?? newSessionId(), siteId: identity.siteId, lang: lang, requestId: requestId ?? newRequestId())
        try await emit(ThalovantEvents.recognizerLoopUtterance, data: data, context: correlated)
    }

    /// Direct query/cascade exchange, strictly scoped by query id. Never automatically replayed.
    public func query(_ text: String, timeout: TimeInterval = 12, lang: String = "en-us", context: JSONObject = [:],
        sessionId: String? = nil, requestId: String? = nil, queryId: String? = nil
    ) async throws -> ThalovantReply {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ThalovantRuntimeError("query() requires a non-empty prompt.") }
        try validateRuntimeTimeout(timeout)
        guard transport.supportsHiveMessages else { throw ThalovantRuntimeError("This transport does not support HiveMind query frames.") }
        let request = requestId ?? newRequestId(), session = sessionId ?? newSessionId(), query = queryId ?? request
        let state = RuntimeQueryState()
        let token = transport.addMessageHandler { message in
            guard ["query", "cascade"].contains(message.msgType),
                  (message.metadata["query_id"]?.stringValue ?? message.metadata["queryId"]?.stringValue) == query,
                  let event = runtimeQueryEvent(message.payload) else { return }
            state.accept(event)
        }
        defer { transport.removeMessageHandler(token) }
        return try await withThrowingTaskGroup(of: ThalovantReply.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await self.connect(timeout: timeout)
                let correlated = contextWithCorrelation(context, sessionId: session, siteId: self.identity.siteId, lang: lang, requestId: request)
                let bus = HiveMessage(msgType: "bus", payload: ["type": .string(ThalovantEvents.recognizerLoopUtterance),
                    "data": .object(utterancePayload(text: prompt, lang: lang)), "context": .object(correlated)])
                try await self.transport.sendHiveFrame(HiveMessage(msgType: "query", payload: encodedJSONObject(bus), metadata: ["query_id": .string(query)]))
                try await self.waitRuntime(state.gate, timeout: timeout)
                return try state.reply(sessionId: session, requestId: request)
            }
            group.addTask {
                try await AsyncGate().wait(timeout: timeout, timeoutError: ThalovantTimeoutError("Hub did not complete the query in time."))
                throw ThalovantTimeoutError("Hub did not complete the query in time.")
            }
            return try await group.next()!
        }
    }

    public func conversation(sessionId: String = newSessionId(), lang: String = "en-us", context: JSONObject = [:]) -> ThalovantConversation {
        ThalovantConversation(client: self, sessionId: sessionId, lang: lang, context: context)
    }

    private func requireRuntimeConnected() throws {
        guard transport.connected && transport.handshakeComplete else {
            throw ThalovantConnectionError("HiveMind transport disconnected while waiting.")
        }
    }
    private func waitRuntime(_ gate: AsyncGate, timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await gate.wait(timeout: timeout, timeoutError: ThalovantTimeoutError("Hub did not complete the request in time.")) }
            group.addTask {
                while true { try await Task.sleep(nanoseconds: 100_000_000); try self.requireRuntimeConnected() }
            }
            _ = try await group.next()
        }
    }
}

func validateRuntimeTimeout(_ timeout: TimeInterval) throws {
    guard timeout.isFinite, timeout > 0, timeout <= Double(Int32.max) / 1000 else { throw ThalovantRuntimeError("timeout must be finite and positive.") }
}
private func runtimeQueryEvent(_ raw: JSONObject) -> ThalovantEvent? {
    var payload = raw
    for _ in 0..<16 {
        if let event = ThalovantEvent.fromBusPayload(payload) { return event }
        guard let inner = payload["payload"]?.objectValue else { return nil }
        payload = inner
    }
    return nil
}
private final class RuntimeEventState: @unchecked Sendable {
    let gate = AsyncGate(); private let lock = NSLock(); private var stored: ThalovantEvent?
    var value: ThalovantEvent? { lock.locked { stored } }
    func keep(_ event: ThalovantEvent) { lock.locked { if stored == nil { stored = event; gate.open() } } }
}
private final class RuntimeStreamCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func increment() -> Int { lock.locked { value += 1; return value } }
}
private final class RuntimeQueryState: @unchecked Sendable {
    let gate = AsyncGate(); private let lock = NSLock()
    private var events: [ThalovantEvent] = [], fragments: [String] = []
    private var failure: ThalovantEvent?, complete = false
    private var responseSessionId: String?
    func accept(_ event: ThalovantEvent) {
        lock.locked {
            guard !complete else { return }; events.append(event)
            if responseSessionId == nil, let session = event.sessionId, !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { responseSessionId = session }
            if event.name == "hive.query.complete" { complete = true; gate.open() }
            else if [ThalovantEvents.speak, ThalovantEvents.ovosUtteranceSpeak].contains(event.name) {
                let fragment = event.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if !fragment.isEmpty && fragments.last != fragment { fragments.append(fragment) }
            } else if [ThalovantEvents.policyDenied, ThalovantEvents.queryTimeout].contains(event.name) {
                failure = event; complete = true; gate.open()
            } else if event.isFailure { failure = event }
        }
    }
    func reply(sessionId: String, requestId: String) throws -> ThalovantReply {
        try lock.locked {
            if fragments.isEmpty {
                if let failure { throw ThalovantRuntimeError("Hub reported \(failure.name).") }
                throw ThalovantTimeoutError("Hub completed the query without a speak reply.")
            }
            let terminalFailure = failure.flatMap { [ThalovantEvents.policyDenied, ThalovantEvents.queryTimeout].contains($0.name) ? $0 : nil }
            return ThalovantReply(text: fragments.joined(separator: " "), displayText: stripSsml(fragments.joined(separator: " ")), utterances: fragments, handled: terminalFailure == nil, ok: terminalFailure == nil,
                sessionId: responseSessionId ?? sessionId, requestId: requestId, events: events, failureEvent: terminalFailure)
        }
    }
}

func mergeRuntimeContext(_ base: JSONObject, _ extra: JSONObject) -> JSONObject {
    var result = base
    for (key, value) in extra {
        if let left = result[key]?.objectValue, let right = value.objectValue { result[key] = .object(mergeRuntimeContext(left, right)) }
        else { result[key] = value }
    }
    return result
}

/// Stable session wrapper sharing the client's connection.
public final class ThalovantConversation: Sendable {
    public let client: ThalovantClient, sessionId: String, lang: String, context: JSONObject
    init(client: ThalovantClient, sessionId: String, lang: String, context: JSONObject) {
        self.client = client; self.sessionId = sessionId; self.lang = lang; self.context = context
    }
    public func ask(_ text: String, timeout: TimeInterval = 12, context: JSONObject = [:]) async throws -> ThalovantReply {
        try await client.ask(text, timeout: timeout, lang: lang, context: mergeRuntimeContext(self.context, context), sessionId: sessionId)
    }
    public func query(_ text: String, timeout: TimeInterval = 12, context: JSONObject = [:]) async throws -> ThalovantReply {
        try await client.query(text, timeout: timeout, lang: lang, context: mergeRuntimeContext(self.context, context), sessionId: sessionId)
    }
    public func sendUtterance(_ text: String, context: JSONObject = [:]) async throws {
        try await client.sendUtterance(text, lang: lang, context: mergeRuntimeContext(self.context, context), sessionId: sessionId)
    }
    public func sendAction(_ payload: String, title: String? = nil, context: JSONObject = [:]) async throws {
        try await client.sendAction(payload, title: title, lang: lang, context: mergeRuntimeContext(self.context, context), sessionId: sessionId)
    }
    public func sendCode(_ value: String, kind: String = "code", label: String? = nil, context: JSONObject = [:]) async throws {
        try await client.sendCode(value, kind: kind, label: label, lang: lang, context: mergeRuntimeContext(self.context, context), sessionId: sessionId)
    }
    public func on(_ eventName: String, handler: @escaping (ThalovantEvent) -> Void) -> ThalovantSubscription {
        client.on(eventName, sessionId: sessionId, handler: handler)
    }
    public func waitForEvent(_ eventName: String, timeout: TimeInterval = 12,
        predicate: @escaping @Sendable (ThalovantEvent) -> Bool = { _ in true }) async throws -> ThalovantEvent {
        try await client.waitForEvent(eventName, timeout: timeout, sessionId: sessionId, predicate: predicate)
    }
    public func listen(_ eventName: String, timeout: TimeInterval? = nil, maxEvents: Int? = nil) -> AsyncThrowingStream<ThalovantEvent, Error> {
        client.listen(eventName, timeout: timeout, maxEvents: maxEvents, sessionId: sessionId)
    }
    public func emit(_ eventType: String, data: JSONObject = [:], context: JSONObject = [:]) async throws {
        try await client.emit(eventType, data: data, context: contextWithCorrelation(mergeRuntimeContext(self.context, context),
            sessionId: sessionId, siteId: client.identity.siteId, lang: lang))
    }
}
