import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension NSLock {
    /// Runs `body` while holding the lock. Safe to call from async contexts
    /// because the lock is only held inside this synchronous helper.
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// One-shot async gate: `wait` suspends until `open`/`fail`, or until the
/// timeout elapses. On timeout it either throws `timeoutError` or, when no
/// error is configured, returns normally.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func open() {
        settle(.success(()))
    }

    func fail(_ error: Error) {
        settle(.failure(error))
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .success = result { return true }
        return false
    }

    private func settle(_ outcome: Result<Void, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume(with: outcome)
    }

    func wait(timeout: TimeInterval, timeoutError: Error?) async throws {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                waiter.resume(with: result)
                return
            }
            continuation = waiter
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard let pending = self.continuation else {
                    self.lock.unlock()
                    return
                }
                self.continuation = nil
                if let timeoutError {
                    self.result = .failure(timeoutError)
                    self.lock.unlock()
                    pending.resume(throwing: timeoutError)
                } else {
                    self.lock.unlock()
                    pending.resume()
                }
            }
        }
    }
}

/// WSS data-plane transport for the HiveMind runtime, backed by
/// `URLSessionWebSocketTask`.
///
/// Wire protocol (mirrors the Node SDK's WSS transport):
/// 1. Connect to the identity's WSS endpoint with
///    `?authorization=base64("<user agent>:<access key>")`.
/// 2. The hub sends a `handshake`/`shake` frame with `payload.preshared_key`.
/// 3. The client answers with a plaintext `hello` frame carrying `pubkey`,
///    `session.session_id`, and `site_id`; the handshake is then complete.
/// 4. Subsequent frames are JSON `HiveMessage`s, AES-128-GCM encrypted with the
///    identity `crypto_key` when one is present.
public final class HiveMindWSSTransport: NSObject, @unchecked Sendable {
    public let identity: ThalovantIdentity
    public let userAgent: String

    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var connectedFlag = false
    private var handshakeCompleteFlag = false
    private var lastErrorMessage: String?
    private var openGate = AsyncGate()
    private var handshakeGate = AsyncGate()
    private var busHandlers: [UUID: (JSONObject) -> Void] = [:]
    private var messageHandlers: [UUID: (HiveMessage) -> Void] = [:]

    public init(identity: ThalovantIdentity, userAgent: String = defaultThalovantUserAgent) {
        self.identity = identity
        self.userAgent = userAgent
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
        let alreadyReady = lock.locked {
            if connectedFlag && handshakeCompleteFlag {
                return true
            }
            openGate = AsyncGate()
            handshakeGate = AsyncGate()
            handshakeCompleteFlag = false
            lastErrorMessage = nil
            return false
        }
        if alreadyReady { return }

        let url = try endpointURL()
        let delegate = WebSocketOpenDelegate(transport: self)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: url)
        lock.locked {
            self.session = session
            self.socket = socket
        }
        socket.resume()
        receiveNext(on: socket)

        do {
            try await openGate.wait(
                timeout: timeout,
                timeoutError: ThalovantConnectionError("HiveMind WSS connect timed out.")
            )
            lock.locked { connectedFlag = true }
            try await handshakeGate.wait(
                timeout: timeout,
                timeoutError: ThalovantTimeoutError("HiveMind WSS handshake timed out.")
            )
        } catch {
            await disconnect()
            throw error
        }
    }

    public func disconnect() async {
        let (socket, session) = lock.locked { () -> (URLSessionWebSocketTask?, URLSession?) in
            let pair = (self.socket, self.session)
            self.socket = nil
            self.session = nil
            connectedFlag = false
            handshakeCompleteFlag = false
            return pair
        }
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: Sending

    public func send(_ message: HiveMessage, encrypt: Bool = true) async throws {
        let (socket, ready) = lock.locked { (self.socket, handshakeCompleteFlag) }
        guard let socket else {
            throw ThalovantConnectionError("HiveMind WSS transport is not connected.")
        }
        let payload = try HiveWire.encode(
            message,
            cryptoKey: identity.cryptoKey,
            encrypt: encrypt && ready
        )
        try await sendText(payload, on: socket)
    }

    public func emitBus(type: String, data: JSONObject, context: JSONObject) async throws {
        try await send(HiveWire.busMessage(type: type, data: data, context: context))
    }

    private func sendText(_ text: String, on socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.send(.string(text)) { error in
                if let error {
                    continuation.resume(throwing: ThalovantConnectionError("HiveMind WSS send failed: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: Receiving

    private func receiveNext(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleSocketFailure(error)
            case .success(let message):
                do {
                    switch message {
                    case .string(let text):
                        try self.handleFrame(HiveWire.decode(text: text, cryptoKey: self.identity.cryptoKey))
                    case .data(let data):
                        try self.handleFrame(HiveWire.decode(data: data, cryptoKey: self.identity.cryptoKey))
                    @unknown default:
                        break
                    }
                } catch {
                    self.handleSocketFailure(error)
                    return
                }
                self.receiveNext(on: socket)
            }
        }
    }

    func handleSocketOpen() {
        openGate.open()
    }

    /// Called when the socket closes; fails pending waiters when the
    /// handshake never completed.
    func handleSocketClosed(_ error: ThalovantConnectionError) {
        let handshakeWasComplete = lock.locked { () -> Bool in
            connectedFlag = false
            return handshakeCompleteFlag
        }
        if !handshakeWasComplete {
            lock.locked { lastErrorMessage = error.message }
            openGate.fail(error)
            handshakeGate.fail(error)
        }
    }

    private func handleSocketFailure(_ error: Error) {
        lock.lock()
        connectedFlag = false
        lastErrorMessage = String(describing: error)
        lock.unlock()
        let failure = (error as? ThalovantConnectionError)
            ?? ThalovantConnectionError("HiveMind WSS connection failed: \(error)")
        openGate.fail(failure)
        handshakeGate.fail(failure)
    }

    private func handleFrame(_ message: HiveMessage) throws {
        switch message.msgType {
        case "handshake", "shake":
            try handleHandshake(message.payload)
        case "bus":
            lock.lock()
            let handlers = Array(busHandlers.values)
            lock.unlock()
            for handler in handlers {
                handler(message.payload)
            }
        default:
            break
        }
        lock.lock()
        let handlers = Array(messageHandlers.values)
        lock.unlock()
        for handler in handlers {
            handler(message)
        }
    }

    private func handleHandshake(_ payload: JSONObject) throws {
        guard HiveWire.isPresharedKeyHandshake(payload) else {
            throw ThalovantConnectionError("Only HiveMind preshared-key handshakes are supported by this SDK.")
        }
        guard ThalovantCrypto.runtimeKey(identity.cryptoKey) != nil else {
            throw ThalovantConnectionError("HiveMind requested a preshared key, but identity.crypto_key is missing.")
        }
        let hello = HiveWire.helloMessage(
            siteId: identity.siteId,
            publicKey: identity.publicKey,
            sessionId: "thalovant-swift-" + UUID().uuidString.lowercased()
        )
        lock.lock()
        let socket = self.socket
        lock.unlock()
        guard let socket else {
            throw ThalovantConnectionError("HiveMind WSS transport is not connected.")
        }
        // The hello reply is always sent unencrypted.
        let payloadText = try HiveWire.encode(hello, cryptoKey: nil, encrypt: false)
        socket.send(.string(payloadText)) { [weak self] error in
            guard let self else { return }
            if let error {
                self.handleSocketFailure(
                    ThalovantConnectionError("HiveMind WSS hello failed: \(error.localizedDescription)")
                )
                return
            }
            self.lock.lock()
            self.handshakeCompleteFlag = true
            self.lock.unlock()
            self.handshakeGate.open()
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
        transport?.handleSocketOpen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let suffix = reason.flatMap { String(data: $0, encoding: .utf8) }.map { ": \($0)" } ?? ""
        transport?.handleSocketClosed(
            ThalovantConnectionError("HiveMind WSS closed (\(closeCode.rawValue))\(suffix).")
        )
    }
}
