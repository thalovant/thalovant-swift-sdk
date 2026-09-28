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

/// The life of one connection attempt: its handshake, and how it ended.
///
/// A hub refuses credentials in ways that look like a drop -- it closes the
/// socket during the handshake, or right after it -- so a close is read by its
/// code and by when it happened (`closeRefuses`). A transport may learn the
/// code after it learns of the close (URLSession does), so a late code still
/// fills in one that was not known, and the close's own time is kept.
final class LinkLifetime: @unchecked Sendable {
    /// The close codes a hub turns credentials away with: 1005 -- a close with
    /// no status at all, which is what a hub sends for an access key it does
    /// not know and after a Noise abort -- 1000, and 1008 for a malformed
    /// authorization. Anything else (1001, 1006, 1011, 1013, a socket that
    /// ended without a close frame) is the hub's trouble or the network's.
    static let refusalCloseCodes: Set<Int> = [1000, 1005, 1008]
    /// How long after the handshake a close is still the hub's answer to it.
    static let refusalSettleMs = 750
    /// How late a transport may learn a close's code and still have it count.
    static let closeCodeGraceMs = 250

    /// Whether a close is the hub refusing the credentials rather than a drop.
    ///
    /// `code` is the RFC 6455 close code, nil when the socket ended without
    /// one. `closedAfterHandshakeMs` is when the close happened, counted from
    /// the end of the handshake, or nil for a close during it: its own time
    /// decides, not when the code was learnt. `codeLateMs` is how long after
    /// the close the code became known.
    static func closeRefuses(code: Int?, closedAfterHandshakeMs: Int?, codeLateMs: Int = 0) -> Bool {
        guard let code, refusalCloseCodes.contains(code), codeLateMs <= closeCodeGraceMs else { return false }
        return closedAfterHandshakeMs.map { $0 <= refusalSettleMs } ?? true
    }

    /// Opens when the connection ends.
    let ended = AsyncGate()
    /// Opens once a close code is known, which can be a moment after `ended`.
    let coded = AsyncGate()
    private let lock = NSLock()
    private var handshakeAt: TimeInterval?
    private var endedAt: TimeInterval?
    private var code: Int?
    private var codeAt: TimeInterval?
    private var chosen: String?

    /// When the handshake completed, on the monotonic clock; nil until then.
    var handshakeTime: TimeInterval? { lock.locked { handshakeAt } }
    /// The Noise pattern this attempt chose, once it chose one.
    var pattern: String? {
        get { lock.locked { chosen } }
        set { lock.locked { chosen = newValue } }
    }
    /// The WebSocket close code, when the hub sent one.
    var closeCode: Int? { lock.locked { code } }
    /// Whether the connection ended the way a hub refuses credentials: a
    /// refusal code, during the handshake or within the settle window after
    /// it, and learnt within the grace.
    var refused: Bool {
        lock.locked {
            guard let endedAt else { return false }
            let after = handshakeAt.map { Int(((endedAt - $0) * 1000).rounded(.down)) }
            let late = codeAt.map { Int((($0 - endedAt) * 1000).rounded(.down)) } ?? 0
            return Self.closeRefuses(code: code, closedAfterHandshakeMs: after, codeLateMs: late)
        }
    }

    func completeHandshake(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.locked { if handshakeAt == nil { handshakeAt = now } }
    }

    /// Ends the connection. The first call decides when; a close code learnt
    /// later -- the delegate can report it after the read already failed --
    /// fills in one that was not known.
    func end(closeCode: Int?, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let (first, learnt) = lock.locked { () -> (Bool, Bool) in
            let known = closeCode.flatMap { $0 == 0 ? nil : $0 }
            if endedAt != nil {
                guard code == nil, let known else { return (false, false) }
                code = known
                codeAt = now
                return (false, true)
            }
            endedAt = now
            code = known
            codeAt = known == nil ? nil : now
            return (true, known != nil)
        }
        if first { ended.open() }
        if learnt { coded.open() }
    }

    /// When the connection ended without a code, waits for one until the
    /// grace after the close is up.
    func awaitLateCode() async {
        let deadline = lock.locked { () -> TimeInterval? in
            guard code == nil, let endedAt else { return nil }
            return endedAt + TimeInterval(Self.closeCodeGraceMs) / 1000
        }
        guard let deadline else { return }
        try? await coded.wait(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime), timeoutError: nil)
    }
}

/// The socket a WSS transport speaks through: URLSession's WebSocket in
/// production, and an in-memory hub in the test suite, so the handshake, its
/// retry and its failures run through the real transport either way.
protocol HiveSocket: AnyObject {
    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    /// The close code the peer sent, when it is known yet.
    var peerCloseCode: Int? { get }
    /// The HTTP status the server answered the WebSocket upgrade with, when it
    /// refused it; nil for a socket that opened, or when nothing answered.
    var upgradeStatus: Int? { get }
}

/// Builds a socket for a URL, and the session to invalidate with it.
typealias HiveSocketFactory = (URL, HiveMindWSSTransport) -> (any HiveSocket, URLSession?)

/// URLSession's WebSocket, as a `HiveSocket`.
final class URLSessionHiveSocket: HiveSocket, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask) { self.task = task }
    func resume() { task.resume() }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }
    var peerCloseCode: Int? {
        let raw = task.closeCode.rawValue
        return raw == 0 ? nil : raw
    }
    var upgradeStatus: Int? {
        guard let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 else { return nil }
        return status
    }

    /// The production factory: a session of its own per socket, whose
    /// delegate reports the socket opening and closing to the transport.
    static let factory: HiveSocketFactory = { url, transport in
        let delegate = WebSocketOpenDelegate(transport: transport)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let socket = URLSessionHiveSocket(task: session.webSocketTask(with: url))
        delegate.socket = socket
        return (socket, session)
    }
}

/// A failed KK attempt: the next one uses XX.
private struct KKAttemptRefused: Error {
    let refusal: ThalovantConnectionError
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
    private var socket: (any HiveSocket)?
    private var session: URLSession?
    private let noiseStore: any ThalovantNoiseStore
    private let makeSocket: HiveSocketFactory
    private let derivePSK: (String, String) throws -> Data
    private var negotiator: NoiseNegotiator?
    private var writer = NoiseSocketWriter()
    private var connectedFlag = false
    private var handshakeCompleteFlag = false
    private var lastErrorMessage: String?
    private var openGate = AsyncGate()
    private var handshakeGate = AsyncGate()
    private var busHandlers: [UUID: (JSONObject) -> Void] = [:]
    private var messageHandlers: [UUID: (HiveMessage) -> Void] = [:]
    /// The current (or last) connection attempt.
    private var currentLifetime: LinkLifetime?
    /// The socket that carried the last connection to end, and its lifetime:
    /// the delegate can report a close code after the read already failed.
    private weak var retiredSocket: (any HiveSocket)?
    private var retiredLifetime: LinkLifetime?

    var lifetime: LinkLifetime? { lock.locked { currentLifetime } }

    public convenience init(identity: ThalovantIdentity, userAgent: String = defaultThalovantUserAgent,
                            noiseStore: (any ThalovantNoiseStore)? = nil) {
        self.init(identity: identity, userAgent: userAgent, noiseStore: noiseStore,
                  socketFactory: URLSessionHiveSocket.factory, derivePSK: noisePSK)
    }

    /// A transport over sockets `socketFactory` builds; the test suite's
    /// in-memory hub is one.
    init(identity: ThalovantIdentity, userAgent: String = defaultThalovantUserAgent,
         noiseStore: (any ThalovantNoiseStore)?, socketFactory: @escaping HiveSocketFactory,
         derivePSK: @escaping (String, String) throws -> Data) {
        self.identity = identity
        self.userAgent = userAgent
        self.noiseStore = noiseStore ?? ThalovantFileNoiseStore(identityScope: identity.accessKey)
        self.makeSocket = socketFactory
        self.derivePSK = derivePSK
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

    /// Connects and authenticates.
    ///
    /// A KK attempt that fails -- its answer does not authenticate, or the hub
    /// closes during it with a refusal code, which is what a hub does when it
    /// cannot read a KK first message -- is followed at once, inside this call,
    /// by one XX attempt, whose outcome is the connect's: a KK failure means
    /// the password or the hub's key is not what was pinned, and only XX says
    /// which. The XX attempt is not a downgrade: the pinned key is still
    /// checked when it completes. A refusal throws `ThalovantConnectionError`
    /// of kind `.refused`, a hub whose key is not the pinned one of kind
    /// `.keyChanged`.
    public func connect(timeout: TimeInterval = 6) async throws {
        try validateRuntimeTimeout(timeout)
        try Task.checkCancellation()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            try await connectAttempt(deadline: deadline, preferXX: false)
        } catch is KKAttemptRefused {
            do {
                try await connectAttempt(deadline: deadline, preferXX: true)
            } catch let failed as KKAttemptRefused {
                throw failed.refusal
            }
        }
    }

    private func connectAttempt(deadline: TimeInterval, preferXX: Bool) async throws {
        let url = try endpointURL()
        let setup = lock.locked { () -> (any HiveSocket, AsyncGate, AsyncGate, LinkLifetime, Bool)? in
            if connectedFlag && handshakeCompleteFlag { return nil }
            if let socket, let attempt = currentLifetime { return (socket, openGate, handshakeGate, attempt, false) }
            negotiator = NoiseNegotiator(identity: identity, store: noiseStore, derive: derivePSK, preferXX: preferXX)
            writer = NoiseSocketWriter()
            openGate = AsyncGate(); handshakeGate = AsyncGate()
            handshakeCompleteFlag = false; lastErrorMessage = nil
            let attempt = LinkLifetime()
            let (socket, session) = makeSocket(url, self)
            self.session = session; self.socket = socket; currentLifetime = attempt
            return (socket, openGate, handshakeGate, attempt, true)
        }
        guard let (socket, open, handshake, attempt, startsAttempt) = setup else { return }
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
            let verdict = await classify(error, socket: socket, attempt: attempt)
            if let refusal = verdict as? ThalovantConnectionError, refusal.kind == .refused, attempt.pattern == "KKpsk0" {
                throw KKAttemptRefused(refusal: refusal)
            }
            throw verdict
        }
    }

    /// What a failed attempt means: a refusal and a changed hub key keep their
    /// kind; an upgrade answered 401 or 403 is a refusal; a close during the
    /// handshake is one when its code is (waiting a moment for a code learnt
    /// late); anything else is what it was.
    private func classify(_ error: Error, socket: any HiveSocket, attempt: LinkLifetime) async -> Error {
        if error is CancellationError { return error }
        if let verdict = error as? ThalovantConnectionError, verdict.kind != .other { return verdict }
        if let status = socket.upgradeStatus {
            if status == 401 || status == 403 {
                return ThalovantConnectionError("The hub refused this connection's credentials (HTTP \(status)).", kind: .refused)
            }
            return ThalovantConnectionError("The hub could not accept the WebSocket upgrade (HTTP \(status)).")
        }
        guard attempt.ended.isOpen, attempt.handshakeTime == nil else { return error }
        await attempt.awaitLateCode()
        if attempt.refused {
            let code = attempt.closeCode.map(String.init) ?? "no status"
            return ThalovantConnectionError(
                "The hub refused this connection's credentials: it closed the link during the handshake (\(code)).",
                kind: .refused)
        }
        return error
    }

    public func disconnect() async {
        let (socket, session, open, handshake, ending) = lock.locked { () -> ((any HiveSocket)?, URLSession?, AsyncGate, AsyncGate, LinkLifetime?) in
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
        let (socket, connection, writer) = try lock.locked { () throws -> (any HiveSocket, NoiseConnection, NoiseSocketWriter) in
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

    private func startReceiveLoop(on socket: any HiveSocket) {
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
                            // Noted as soon as it is chosen: a failed KK attempt
                            // is followed by an XX one.
                            if let pattern = negotiator.connection?.pattern { self.currentLifetime?.pattern = pattern }
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
                                self.currentLifetime?.completeHandshake()
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
                    self.handleSocketFailure(error, on: socket, closeCode: socket.peerCloseCode)
                    return
                }
            }
        }
    }

    func handleSocketOpen(on socket: any HiveSocket) {
        lock.locked { if self.socket === socket { openGate.open() } }
    }

    func handleSocketClosed(_ error: ThalovantConnectionError, closeCode: Int? = nil, on socket: any HiveSocket) {
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

    private func handleSocketFailure(_ error: Error, on socket: any HiveSocket, closeCode: Int? = nil) {
        let detail = safeTransportErrorMessage(error)
        let explanation = detail.contains("WebSockets not supported by libcurl")
            ? "This Linux FoundationNetworking/libcurl build has no WebSocket support. Use a Swift distribution compiled with WebSocket support; Noise negotiation has not started."
            : "HiveMind WSS connection failed: \(detail)"
        // A refusal or a changed hub key keeps its kind through the gates.
        let failure = ThalovantConnectionError(explanation, kind: (error as? ThalovantConnectionError)?.kind ?? .other)
        let detached = lock.locked { () -> (URLSession?, AsyncGate, AsyncGate, LinkLifetime?)? in
            guard self.socket === socket else { return nil }
            let ending = currentLifetime
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

    func handleFrame(_ message: HiveMessage, on socket: any HiveSocket) throws {
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
    func send(on socket: any HiveSocket,
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
final class WebSocketOpenDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private weak var transport: HiveMindWSSTransport?
    /// The socket this session carries; set once it exists.
    weak var socket: URLSessionHiveSocket?

    init(transport: HiveMindWSSTransport) {
        self.transport = transport
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard let socket, socket.task === webSocketTask else { return }
        transport?.handleSocketOpen(on: socket)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard let socket, socket.task === webSocketTask else { return }
        let suffix = reason.flatMap { String(data: $0, encoding: .utf8) }.map { ": \($0)" } ?? ""
        transport?.handleSocketClosed(
            ThalovantConnectionError("HiveMind WSS closed (\(closeCode.rawValue))\(suffix)."),
            closeCode: closeCode.rawValue, on: socket
        )
    }
}
