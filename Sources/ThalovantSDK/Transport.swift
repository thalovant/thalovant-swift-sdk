import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension NSLock {
    /// Runs `body` while holding the lock. Safe to call from async contexts
    /// because the lock is only held inside this synchronous helper.
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// Precompiled matcher for an `authorization=<value>` query parameter — the
/// value is the base64 access-key credential the WSS transport puts on the
/// connection URL. `nil` only if the literal pattern fails to compile.
private let authorizationQueryRegex = try? NSRegularExpression(
    pattern: "(authorization=)[^&\\s\"']*",
    options: [.caseInsensitive]
)

/// Redacts the value of any `authorization=` query parameter in `text`,
/// preserving the surrounding message (scheme, host, path, other parameters).
/// A pure string transform, so it behaves identically on every platform.
func redactingAuthorizationQuery(_ text: String) -> String {
    guard let regex = authorizationQueryRegex else { return text }
    return regex.stringByReplacingMatches(
        in: text,
        options: [],
        range: NSRange(text.startIndex..., in: text),
        withTemplate: "$1<redacted>"
    )
}

/// Human-facing description of a transport error that never leaks the
/// connection URL. `URLSession` surfaces failures as `NSError`s that embed the
/// failing request URL under `NSErrorFailingURLKey`, and that URL carries
/// `?authorization=base64("<user agent>:<access key>")` in its query — so
/// `String(describing:)` / `\(error)` would expose the access key. Take only
/// the localized failure reason (which omits the URL) and scrub any
/// authorization query that still slips through, as a final guard.
func safeTransportErrorMessage(_ error: Error) -> String {
    redactingAuthorizationQuery(error.localizedDescription)
}

/// One-shot async gate shared by connection waiters. Opening or failing the
/// gate settles every waiter. Cancellation and deadlines affect only that
/// waiter's registration; they never overwrite another task's continuation.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]

    func open() { settle(.success(())) }
    func fail(_ error: Error) { settle(.failure(error)) }

    var isOpen: Bool {
        lock.locked {
            if case .success = result { return true }
            return false
        }
    }

    var waiterCount: Int { lock.locked { continuations.count } }

    private func settle(_ outcome: Result<Void, Error>) {
        let waiters = lock.locked { () -> [CheckedContinuation<Void, Error>] in
            guard result == nil else { return [] }
            result = outcome
            let waiters = Array(continuations.values)
            continuations.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(with: outcome) }
    }

    private func finishWaiter(_ id: UUID, with outcome: Result<Void, Error>) {
        let waiter = lock.locked { continuations.removeValue(forKey: id) }
        waiter?.resume(with: outcome)
    }

    func wait(timeout: TimeInterval?, timeoutError: Error?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                let immediate = lock.locked { () -> Result<Void, Error>? in
                    // Covers cancellation before registration, including a
                    // cancellation handler that ran before taking this lock.
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if let result { return result }
                    continuations[id] = waiter
                    return nil
                }
                if let immediate {
                    waiter.resume(with: immediate)
                    return
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finishWaiter(id, with: timeoutError.map { .failure($0) } ?? .success(()))
                    }
                }
            }
        } onCancel: {
            self.finishWaiter(id, with: .failure(CancellationError()))
        }
    }
}

/// The life of one established connection: it ends once, and says how.
///
/// A hub that does not know a client's static key says so only by closing
/// right after the handshake, so a session that just connected waits a moment
/// on `ended` and asks `refused` to tell a verdict on the credentials from a
/// dropped network.
final class LinkLifetime: @unchecked Sendable {
    /// The close codes a hub turns credentials away with: 1005 -- a close with
    /// no status, which is what a hub sends for an access key it does not
    /// know and after a Noise abort -- 1000, and 1008 for a malformed
    /// authorization. Anything else (1001, 1011, 1013, a socket that dropped
    /// without a close) is the hub's trouble or the network's.
    static let refusalCloseCodes: Set<Int> = [1000, 1005, 1008]

    /// Opens when the connection ends.
    let ended = AsyncGate()
    private let lock = NSLock()
    private var finished = false
    private var code: Int?

    /// The WebSocket close code, when the hub sent one.
    var closeCode: Int? { lock.locked { code } }
    /// Whether the hub closed the connection the way it refuses credentials.
    var refused: Bool { lock.locked { code.map(Self.refusalCloseCodes.contains) ?? false } }

    /// Ends the connection. The first call decides; a close code learnt later
    /// -- the delegate can report it after the read already failed -- fills in
    /// one that was not known.
    func end(closeCode: Int?) {
        let first = lock.locked { () -> Bool in
            let known = closeCode.flatMap { $0 == 0 ? nil : $0 }
            if finished {
                if code == nil { code = known }
                return false
            }
            finished = true
            code = known
            return true
        }
        if first { ended.open() }
    }
}

/// The slice of a data-plane transport that `ThalovantClient` drives: connect,
/// emit a bus event, observe bus events. `HiveMindWSSTransport` is the
/// production implementation; the test suite substitutes an in-memory hub so
/// the client's request/reply paths run without a network.
protocol HiveMindBusTransport: AnyObject, Sendable {
    var connected: Bool { get }
    var handshakeComplete: Bool { get }
    var connectionInfo: ThalovantConnectionInfo { get }
    var supportsHiveMessages: Bool { get }
    func addMessageHandler(_ handler: @escaping (HiveMessage) -> Void) -> UUID
    func removeMessageHandler(_ id: UUID)
    func sendHiveFrame(_ message: HiveMessage) async throws
    func connect(timeout: TimeInterval) async throws
    func disconnect() async
    func addBusHandler(_ handler: @escaping (JSONObject) -> Void) -> UUID
    func removeBusHandler(_ id: UUID)
    func emitBus(type: String, data: JSONObject, context: JSONObject) async throws
    /// The most recent established connection, ended or not; nil before the
    /// first handshake, and for a transport that cannot tell.
    var lifetime: LinkLifetime? { get }
}

extension HiveMindBusTransport {
    var lifetime: LinkLifetime? { nil }
    var connected: Bool { false }
    var handshakeComplete: Bool { connected }
    var connectionInfo: ThalovantConnectionInfo { ThalovantConnectionInfo(phase: connected && handshakeComplete ? "ready" : "idle") }
    var supportsHiveMessages: Bool { false }
    func addMessageHandler(_ handler: @escaping (HiveMessage) -> Void) -> UUID { UUID() }
    func removeMessageHandler(_ id: UUID) {}
    func sendHiveFrame(_ message: HiveMessage) async throws { throw ThalovantRuntimeError("This transport does not support HiveMind query frames.") }
}

/// WSS data-plane transport for the HiveMind runtime, backed by
/// `URLSessionWebSocketTask`.
///
/// HiveMind v3 WSS transport: authenticated Noise XXpsk2 / KKpsk0 with
/// X25519, AES256-GCM and the exact Argon2id password derivation. Runtime
/// messages use ordered encrypted binary frames; legacy downgrade is rejected.
public final class HiveMindWSSTransport: NSObject, HiveMindBusTransport, @unchecked Sendable {
    var supportsHiveMessages: Bool { true }
    var connectionInfo: ThalovantConnectionInfo {
        lock.locked { ThalovantConnectionInfo(phase: lastErrorMessage != nil ? "error" : handshakeCompleteFlag && connectedFlag ? "ready" : connectedFlag ? "handshake" : "idle",
            lastError: lastErrorMessage == nil ? nil : "HiveMind WSS connection failed.") }
    }
    func sendHiveFrame(_ message: HiveMessage) async throws { try await send(message) }

    public let identity: ThalovantIdentity
    public let userAgent: String

    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private let noiseStore: any ThalovantNoiseStore
    private var negotiator: NoiseNegotiator?
    private var writer = NoiseSocketWriter()
    private var connectedFlag = false
    private var handshakeCompleteFlag = false
    private var lastErrorMessage: String?
    private var openGate = AsyncGate()
    private var handshakeGate = AsyncGate()
    private var busHandlers: [UUID: (JSONObject) -> Void] = [:]
    private var messageHandlers: [UUID: (HiveMessage) -> Void] = [:]
    private var currentLifetime: LinkLifetime?
    private var refusedUpgrade: Int?
    /// The HTTP status of the last connect's WebSocket upgrade, when the hub
    /// answered it 401 or 403; nil otherwise.
    var refusedUpgradeStatus: Int? { lock.locked { refusedUpgrade } }
    /// The socket that carried the last connection to end, and its lifetime:
    /// the delegate can report a close code after the read already failed.
    private weak var retiredSocket: URLSessionWebSocketTask?
    private var retiredLifetime: LinkLifetime?

    var lifetime: LinkLifetime? { lock.locked { currentLifetime } }

    public init(identity: ThalovantIdentity, userAgent: String = defaultThalovantUserAgent,
                noiseStore: (any ThalovantNoiseStore)? = nil) {
        self.identity = identity
        self.userAgent = userAgent
        self.noiseStore = noiseStore ?? ThalovantFileNoiseStore(identityScope: identity.accessKey)
    }

    public var connected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connectedFlag
    }

    public var handshakeComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handshakeCompleteFlag
    }

    #if DEBUG
    private var applicationWriteBarrier: (@Sendable () async throws -> Void)?
    /// Pause one application write after admission for the independent loopback peer fixture.
    @_spi(Testing) public func _setNextApplicationWriteBarrier(_ barrier: @escaping @Sendable () async throws -> Void) {
        lock.locked { applicationWriteBarrier = barrier }
    }
    /// Loopback-test barrier: callers admitted to this socket's pending handshake.
    /// This test SPI is absent from release builds.
    @_spi(Testing) public var _pendingConnectHandshakeWaiters: Int {
        lock.locked { handshakeGate.waiterCount }
    }
    #endif

    public var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastErrorMessage
    }

    var authorization: String {
        HiveWire.authorization(userAgent: userAgent, accessKey: identity.accessKey)
    }

    /// The fully authorized WSS URL for this identity.
    public func endpointURL() throws -> URL {
        guard let endpoint = identity.endpointFor(.wss) else {
            throw ThalovantConnectionError("The identity does not include a WSS endpoint.")
        }
        return try HiveWire.authorizedEndpoint(endpoint, authorization: authorization)
    }

    // MARK: Event registration

    @discardableResult
    public func addBusHandler(_ handler: @escaping (JSONObject) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        busHandlers[id] = handler
        lock.unlock()
        return id
    }

    public func removeBusHandler(_ id: UUID) {
        lock.lock()
        busHandlers.removeValue(forKey: id)
        lock.unlock()
    }

    @discardableResult
    func addMessageHandler(_ handler: @escaping (HiveMessage) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        messageHandlers[id] = handler
        lock.unlock()
        return id
    }

    func removeMessageHandler(_ id: UUID) {
        lock.lock()
        messageHandlers.removeValue(forKey: id)
        lock.unlock()
    }

    // MARK: Lifecycle

    public func connect(timeout: TimeInterval = 6) async throws {
        try validateRuntimeTimeout(timeout)
        try Task.checkCancellation()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let url = try endpointURL()
        let setup = lock.locked { () -> (URLSessionWebSocketTask, AsyncGate, AsyncGate, Bool)? in
            if connectedFlag && handshakeCompleteFlag { return nil }
            if let socket { return (socket, openGate, handshakeGate, false) }
            negotiator = NoiseNegotiator(identity: identity, store: noiseStore)
            writer = NoiseSocketWriter()
            refusedUpgrade = nil
            openGate = AsyncGate(); handshakeGate = AsyncGate()
            handshakeCompleteFlag = false; lastErrorMessage = nil
            let delegate = WebSocketOpenDelegate(transport: self)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            let socket = session.webSocketTask(with: url)
            self.session = session; self.socket = socket
            return (socket, openGate, handshakeGate, true)
        }
        guard let (socket, open, handshake, startsAttempt) = setup else { return }
        if startsAttempt {
            socket.resume()
            startReceiveLoop(on: socket)
        }
        do {
            try await open.wait(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime), timeoutError: noiseError("HiveMind WSS connect timed out."))
            try Task.checkCancellation()
            try lock.locked {
                guard self.socket === socket else { throw noiseError("Connection attempt was interrupted.") }
                connectedFlag = true
            }
            try await handshake.wait(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime), timeoutError: ThalovantTimeoutError("HiveMind WSS handshake timed out."))
            try Task.checkCancellation()
            try lock.locked {
                guard self.socket === socket, handshakeCompleteFlag else { throw noiseError("Connection closed during Noise negotiation.") }
            }
        } catch {
            // Only the task that created the attempt owns its teardown. A
            // joining caller's timeout/cancellation must not abort other users.
            if startsAttempt { handleSocketFailure(error, on: socket) }
            // An upgrade answered 401 or 403 is a verdict on the credentials,
            // not a network that may come back. Kept beside the error, whose
            // type callers already match, for a session to read.
            if let status = (socket.response as? HTTPURLResponse)?.statusCode, status == 401 || status == 403 {
                lock.locked { refusedUpgrade = status }
            }
            throw error
        }
    }

    public func disconnect() async {
        let (socket, session, open, handshake, ending) = lock.locked { () -> (URLSessionWebSocketTask?, URLSession?, AsyncGate, AsyncGate, LinkLifetime?) in
            let pair = (self.socket, self.session, openGate, handshakeGate, currentLifetime)
            self.socket = nil; self.session = nil
            connectedFlag = false; handshakeCompleteFlag = false
            negotiator?.connection?.close(); negotiator = nil
            return pair
        }
        let error = noiseError("HiveMind WSS disconnected.")
        open.fail(error); handshake.fail(error)
        // Closed from this side: an end, never a refusal.
        ending?.end(closeCode: nil)
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: Sending

    public func send(_ message: HiveMessage, encrypt: Bool = true) async throws {
        let (socket, connection, writer) = try lock.locked { () throws -> (URLSessionWebSocketTask, NoiseConnection, NoiseSocketWriter) in
            guard encrypt, let socket = self.socket, handshakeCompleteFlag, let connection = negotiator?.connection, connection.ready else {
                throw noiseError("HiveMind v3 messages require a completed Noise handshake and encryption.")
            }
            return (socket, connection, self.writer)
        }
        #if DEBUG
        let barrier = lock.locked { () -> (@Sendable () async throws -> Void)? in
            let saved = applicationWriteBarrier; applicationWriteBarrier = nil; return saved
        }
        #endif
        do {
            try await writer.send(frames: {
                let bytes = try JSONEncoder().encode(message)
                return try connection.encrypt(bytes).map { .data($0) }
            }, write: { frame in
                #if DEBUG
                try await barrier?()
                #endif
                try await socket.send(frame)
            }, onPhysicalFailure: { [weak self] error in
                // The callback remains owned by the physical task after its caller leaves.
                self?.handleSocketFailure(error, on: socket)
            })
        } catch is NoiseQueuedSendCancelled {
            throw CancellationError()
        } catch is CancellationError {
            // Caller cancellation does not cancel an already admitted physical write.
            throw CancellationError()
        } catch {
            throw noiseError("HiveMind WSS send failed: \(safeTransportErrorMessage(error))")
        }
    }

    public func emitBus(type: String, data: JSONObject, context: JSONObject) async throws {
        try await send(HiveWire.busMessage(type: type, data: data, context: context))
    }

    // MARK: Receiving

    private func startReceiveLoop(on socket: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                guard let self else { return }
                do {
                    let frame = try await socket.receive()
                    guard self.lock.locked({ self.socket === socket }) else { return }
                    switch frame {
                    case .string(let text):
                        let (replies, connection, writer) = try self.lock.locked { () throws -> ([HiveMessage], NoiseConnection?, NoiseSocketWriter) in
                            guard self.socket === socket, !self.handshakeCompleteFlag, let negotiator = self.negotiator else {
                                throw noiseError("Unexpected cleartext frame after Noise negotiation.")
                            }
                            let replies = try negotiator.receive(HiveWire.decode(text: text, cryptoKey: nil))
                            return (replies, negotiator.connection, self.writer)
                        }
                        for reply in replies {
                            try await writer.send(on: socket) { [.string(try HiveWire.encode(reply, cryptoKey: nil, encrypt: false))] }
                        }
                        if let connection, connection.ready {
                            let hello = HiveWire.helloMessage(siteId: self.identity.siteId, publicKey: self.identity.publicKey,
                                                            sessionId: "thalovant-swift-" + UUID().uuidString.lowercased())
                            try await writer.send(on: socket) { try connection.encrypt(JSONEncoder().encode(hello)).map { .data($0) } }
                            self.lock.locked {
                                guard self.socket === socket else { return }
                                self.handshakeCompleteFlag = true
                                self.currentLifetime = LinkLifetime()
                                self.handshakeGate.open()
                            }
                        }
                    case .data(let data):
                        let decoded = try self.lock.locked { () throws -> (Data, Bool)? in
                            guard self.socket === socket, self.handshakeCompleteFlag, let connection = self.negotiator?.connection else {
                                throw noiseError("Binary frame arrived before Noise negotiation completed.")
                            }
                            return try connection.decrypt(data)
                        }
                        if let (payload, isJSON) = decoded {
                            // The Noise framing marks each frame JSON or not.
                            // A frame marked binary is a WIRE-1 one -- how a hub
                            // answers speak:synth with the rendered audio, and
                            // how a file arrives. Refusing it here is what made
                            // every such frame unreachable.
                            let message = isJSON
                                ? try JSONDecoder().decode(HiveMessage.self, from: payload)
                                : try HiveWire.decodeBinaryFrame(payload)
                            try self.handleFrame(message, on: socket)
                        }
                    @unknown default:
                        throw noiseError("Unknown WebSocket frame type.")
                    }
                } catch {
                    // The close code is there when the hub closed the socket;
                    // a local failure leaves it invalid (0), which is no code.
                    self.handleSocketFailure(error, on: socket, closeCode: socket.closeCode.rawValue)
                    return
                }
            }
        }
    }

    func handleSocketOpen(on socket: URLSessionWebSocketTask) {
        lock.locked { if self.socket === socket { openGate.open() } }
    }

    func handleSocketClosed(_ error: ThalovantConnectionError, closeCode: Int? = nil, on socket: URLSessionWebSocketTask) {
        let late = lock.locked { () -> LinkLifetime? in
            guard self.socket !== socket, retiredSocket === socket else { return nil }
            return retiredLifetime
        }
        if let late {
            late.end(closeCode: closeCode)
            return
        }
        handleSocketFailure(error, on: socket, closeCode: closeCode)
    }

    private func handleSocketFailure(_ error: Error, on socket: URLSessionWebSocketTask, closeCode: Int? = nil) {
        let detail = safeTransportErrorMessage(error)
        let explanation = detail.contains("WebSockets not supported by libcurl")
            ? "This Linux FoundationNetworking/libcurl build has no WebSocket support. Use a Swift distribution compiled with WebSocket support; Noise negotiation has not started."
            : "HiveMind WSS connection failed: \(detail)"
        let failure = noiseError(explanation)
        let detached = lock.locked { () -> (URLSession?, AsyncGate, AsyncGate, LinkLifetime?)? in
            guard self.socket === socket else { return nil }
            // Only an established connection has a life to end; a failure
            // during the handshake leaves the previous one as it was.
            let ending = handshakeCompleteFlag ? currentLifetime : nil
            let old = (session, openGate, handshakeGate, ending)
            self.socket = nil; session = nil; connectedFlag = false; handshakeCompleteFlag = false
            lastErrorMessage = failure.message
            negotiator?.connection?.close(); negotiator = nil
            retiredSocket = socket; retiredLifetime = ending
            return old
        }
        guard let (session, open, handshake, ending) = detached else { return }
        ending?.end(closeCode: closeCode)
        open.fail(failure); handshake.fail(failure)
        socket.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel()
    }

    func handleFrame(_ message: HiveMessage, on socket: URLSessionWebSocketTask) throws {
        // Admit callbacks for the same socket that supplied the decrypted frame.
        // There is no async hop between admission and delivery. Handlers run
        // outside the lock so application callbacks can register/remove handlers.
        let snapshot = try lock.locked { () throws -> ([(JSONObject) -> Void], [(HiveMessage) -> Void])? in
            guard self.socket === socket, handshakeCompleteFlag else { return nil }
            guard message.msgType != "handshake", message.msgType != "shake" else {
                throw noiseError("Unexpected handshake inside an established Noise session.")
            }
            let bus = message.msgType == "bus" ? Array(busHandlers.values) : []
            return (bus, Array(messageHandlers.values))
        }
        guard let (bus, messages) = snapshot else { return }
        for handler in bus { handler(message.payload) }
        for handler in messages { handler(message) }
    }

}

/// Serialize encryption and socket sends together. Actor reentrancy does not
/// reorder nonce assignment: each task waits for its predecessor before sealing.
// A queued cancellation has not consumed a nonce or touched the socket.
struct NoiseQueuedSendCancelled: Error {}

private final class NoiseWriteState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false, started = false, finished = false
    private var storedFailure: Error?
    func begin() -> Bool {
        lock.locked { if cancelled { return false }; started = true; return true }
    }
    func cancel() { lock.locked { cancelled = true } }
    var hasStarted: Bool { lock.locked { started } }
    func finish(_ error: Error? = nil) -> Bool {
        lock.locked {
            guard !finished else { return false }
            finished = true; storedFailure = error; return true
        }
    }
    var failure: Error? { lock.locked { storedFailure } }
}

actor NoiseSocketWriter {
    private var tail: Task<Void, Error>?
    private let physicalWriteTimeout: TimeInterval
    init(physicalWriteTimeout: TimeInterval = 20) {
        precondition(physicalWriteTimeout.isFinite && physicalWriteTimeout > 0 && physicalWriteTimeout <= Double(Int32.max) / 1000)
        self.physicalWriteTimeout = physicalWriteTimeout
    }
    #if DEBUG
    private(set) var queuedEntryCount = 0
    #endif
    func send(on socket: URLSessionWebSocketTask,
              frames: @escaping @Sendable () throws -> [URLSessionWebSocketTask.Message]) async throws {
        try await send(frames: frames, write: { try await socket.send($0) })
    }
    func send(frames: @escaping @Sendable () throws -> [URLSessionWebSocketTask.Message],
              write: @escaping @Sendable (URLSessionWebSocketTask.Message) async throws -> Void,
              onPhysicalFailure: @escaping @Sendable (Error) -> Void = { _ in }) async throws {
        let previous = tail
        let completion = AsyncGate(), state = NoiseWriteState()
        #if DEBUG
        queuedEntryCount += 1
        #endif
        let next = Task {
            defer {
                #if DEBUG
                queuedEntryCount -= 1
                #endif
            }
            do {
                if let previous { try await previous.value }
                // A skipped queued entry succeeds for its successor without consuming a nonce.
                guard state.begin() else { completion.fail(NoiseQueuedSendCancelled()); return }
                // Admission transfers ownership to this task; caller cancellation cannot cancel it.
                let physical = Task {
                    for message in try frames() {
                        try Task.checkCancellation()
                        try await write(message)
                    }
                }
                let expiry = Task {
                    do { try await Task.sleep(nanoseconds: UInt64(physicalWriteTimeout * 1_000_000_000)) }
                    catch { return }
                    let error = ThalovantTimeoutError("HiveMind physical write timed out.")
                    if state.finish(error) {
                        onPhysicalFailure(error); completion.fail(error); physical.cancel()
                    }
                }
                defer { expiry.cancel() }
                do {
                    try await physical.value
                    if state.finish() { completion.open() }
                    if let failure = state.failure { throw failure }
                } catch {
                    if state.finish(error) { onPhysicalFailure(error); completion.fail(error) }
                    throw state.failure ?? error
                }
            } catch {
                completion.fail(error)
                throw error
            }
        }
        // The tail remains pending through actual physical cleanup, even after timeout/cancellation.
        tail = next
        do {
            try await withTaskCancellationHandler(operation: {
                try await completion.wait(timeout: nil, timeoutError: nil)
            }, onCancel: { state.cancel() })
        } catch is CancellationError where Task.isCancelled && !state.hasStarted {
            throw NoiseQueuedSendCancelled()
        }
    }
}

/// URLSession delegate translating socket open/close callbacks into transport state.
private final class WebSocketOpenDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private weak var transport: HiveMindWSSTransport?

    init(transport: HiveMindWSSTransport) {
        self.transport = transport
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        transport?.handleSocketOpen(on: webSocketTask)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let suffix = reason.flatMap { String(data: $0, encoding: .utf8) }.map { ": \($0)" } ?? ""
        transport?.handleSocketClosed(
            ThalovantConnectionError("HiveMind WSS closed (\(closeCode.rawValue))\(suffix)."),
            closeCode: closeCode.rawValue, on: webSocketTask
        )
    }
}
