import Foundation
import XCTest

@testable import ThalovantSDK

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Serves one vector case's exchanges in order through URLSession, and checks
/// every request against the one the case names: method, path, body or body
/// subset, `If-Match` and `Authorization`; it answers with the case's status,
/// content type, body and headers. The same job as the reference's
/// `ScriptedApi` in `tests/test_home_link_vectors.py`, over the SDK's real
/// HTTP path rather than beside it. It answers for a loopback address, so an
/// operation link can name the API's own origin (`{api_host}:{api_port}`).
final class ScriptedApi: URLProtocol {
    private static let lock = NSLock()
    private static var exchanges: [JSONObject] = []
    private static var index = 0
    private static var sentLines: [String] = []
    private static var mismatchLines: [String] = []
    private static var generation = 0

    static let apiHost = "127.0.0.1"
    static let apiPort = 8765
    static let apiURL = "http://\(apiHost):\(apiPort)"

    /// Starts a case: these exchanges, nothing sent yet.
    static func serve(_ next: [JSONObject]) {
        lock.locked {
            exchanges = next
            index = 0
            sentLines = []
            mismatchLines = []
            generation += 1
        }
    }

    /// A control plane for the case being served. Its requests say which case
    /// sent them, so one a finished case left in flight -- a read abandoned
    /// when its wait ran out -- is turned away instead of taking the next
    /// case's exchange.
    static func controlPlane(accessToken: String? = nil) -> ThalovantControlPlane {
        let tag = lock.locked { generation }
        return ThalovantControlPlane(
            apiURL: apiURL, accessToken: accessToken,
            userAgent: "\(defaultThalovantUserAgent) \(casePrefix)\(tag)", session: session())
    }

    private static let casePrefix = "scripted-case/"

    /// Whether a request came from a case other than the one being served.
    private static func isStraggler(_ userAgent: String?) -> Bool {
        guard let userAgent, let range = userAgent.range(of: casePrefix),
              let tag = Int(userAgent[range.upperBound...]) else { return false }
        return lock.locked { tag != generation }
    }

    /// What the SDK sent, in order: `METHOD path`, with ` If-Match=<etag>` when set.
    static var sent: [String] { lock.locked { sentLines } }
    /// Every way a request differed from the one its exchange names.
    static var mismatches: [String] { lock.locked { mismatchLines } }
    /// How many exchanges were used up; a repeating one never is.
    static var used: Int { lock.locked { index } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedApi.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.isStraggler(request.value(forHTTPHeaderField: "User-Agent")) {
            answer(status: 599, contentType: "application/json", body: "{}", headers: [:])
            return
        }
        let method = request.httpMethod ?? ""
        let path = request.url?.path ?? ""
        let ifMatch = request.value(forHTTPHeaderField: "If-Match")
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let raw = request.httpBody ?? Self.drain(request.httpBodyStream) ?? Data()
        let body = raw.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: raw)

        let exchange = Self.next("\(method) \(path)" + (ifMatch.map { " If-Match=\($0)" } ?? ""))
        guard let exchange,
              let expected = exchange["request"]?.objectValue,
              let response = exchange["response"]?.objectValue
        else {
            answer(status: 599, contentType: "application/json", body: "{}", headers: [:])
            return
        }
        var differences: [String] = []
        if method != expected["method"]?.stringValue || path != expected["path"]?.stringValue {
            differences.append("\(method) \(path) != \(expected["method"]?.stringValue ?? "") \(expected["path"]?.stringValue ?? "")")
        }
        if let json = expected["json"], body != json {
            differences.append("body \(String(describing: body)) != \(json)")
        }
        if let subset = expected["json_subset"], !Self.contains(body, subset) {
            differences.append("body \(String(describing: body)) lacks \(subset)")
        }
        if let wanted = expected["if_match"], ifMatch != wanted.stringValue {
            differences.append("If-Match \(ifMatch ?? "nil") != \(wanted)")
        }
        if let wanted = expected["authorization"], authorization != wanted.stringValue {
            differences.append("wrong Authorization header")
        }
        if !differences.isEmpty {
            Self.lock.locked { Self.mismatchLines.append(contentsOf: differences) }
        }
        answer(
            status: response["status"]?.intValue ?? 599,
            contentType: response["content_type"]?.stringValue ?? "application/json",
            body: response["body"]?.stringValue ?? "",
            headers: (response["headers"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        )
    }

    override func stopLoading() {}

    /// Notes a request and hands out the exchange that answers it: the next
    /// one, or the same one again when it repeats.
    private static func next(_ line: String) -> JSONObject? {
        lock.locked { () -> JSONObject? in
            sentLines.append(line)
            guard index < exchanges.count else {
                mismatchLines.append("unexpected \(line)")
                return nil
            }
            let exchange = exchanges[index]
            if exchange["repeat"]?.boolValue != true { index += 1 }
            return exchange
        }
    }

    private func answer(status: Int, contentType: String, body: String, headers extra: [String: String]) {
        let bytes = Data(body.utf8)
        var headers = extra
        headers["Content-Length"] = String(bytes.count)
        if !bytes.isEmpty { headers["Content-Type"] = contentType }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: Self.apiURL)!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !bytes.isEmpty { client?.urlProtocol(self, didLoad: bytes) }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// The reference's `_contains`: every key of a subset object present and
    /// itself contained; anything else equal.
    static func contains(_ value: JSONValue?, _ subset: JSONValue) -> Bool {
        if case .object(let wanted) = subset {
            guard case .object(let actual)? = value else { return false }
            return wanted.allSatisfy { key, item in actual[key] != nil && contains(actual[key], item) }
        }
        return value == subset
    }

    /// Apple platforms hand the body to URLProtocol as a stream.
    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// A loopback port that accepts every connection and resets it at once
/// (`SO_LINGER` 0, then close): what the vectors' "unreachable" means, reached
/// the same way everywhere. A closed port would do on Linux and macOS, but
/// Windows retries a SYN to one for about two seconds first.
final class ResettingListener: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    private let done = DispatchSemaphore(value: 0)

    init() throws {
        #if canImport(Glibc)
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard descriptor >= 0 else { throw ThalovantConnectionError("socket() failed") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard bound == 0, named == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw ThalovantConnectionError("Could not listen on loopback.")
        }
        fd = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
        let listening = descriptor
        Thread.detachNewThread { [self] in
            while !lock.locked({ stopped }) {
                var ready = pollfd(fd: listening, events: Int16(POLLIN), revents: 0)
                guard poll(&ready, 1, 50) > 0 else { continue }
                let connection = accept(listening, nil, nil)
                guard connection >= 0 else { continue }
                var reset = linger(l_onoff: 1, l_linger: 0)
                _ = setsockopt(connection, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
                close(connection)
            }
            done.signal()
        }
    }

    func stop() {
        lock.locked { stopped = true }
        _ = done.wait(timeout: .now() + 2)
        close(fd)
    }
}

/// Reads a vendored vector file by its stem.
func loadVectors(_ stem: String) throws -> JSONObject {
    let url = try XCTUnwrap(Bundle.module.url(forResource: stem, withExtension: "json"))
    return try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: url))
}

/// A number as the reference records it: a whole one as an integer.
func recordedNumber(_ value: Double) -> JSONValue {
    value.isFinite && value == value.rounded() && abs(value) < 9_007_199_254_740_992
        ? .integer(Int(value)) : .number(value)
}

/// `status`, `code` and `detail`, as every refusal kind keeps them.
func apiFields(_ error: ThalovantApiError) -> JSONObject {
    [
        "status": error.statusCode.map { .integer($0) } ?? .null,
        "code": error.errorCode.map { .string($0) } ?? .null,
        "detail": error.detail.map { .string($0) } ?? .null,
    ]
}

/// Every form an error takes when it is shown or logged.
func printedForms(_ error: any Error) -> [String] {
    var forms = [String(describing: error), String(reflecting: error), "\(error)", error.localizedDescription]
    if let api = error as? ThalovantApiError { forms += [api.message, api.description, api.errorDescription ?? ""] }
    return forms
}

/// An in-memory hub link whose connection can end the way a hub ends one:
/// dropped, closed with a code, or closed right after the handshake.
final class LinkFake: HiveMindBusTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var online = false
    private var errored = false
    private var current: LinkLifetime?
    private var buses: [UUID: (JSONObject) -> Void] = [:]
    private var emissions: [ThalovantEvent] = []
    /// A close code the hub sends right after every handshake; nil admits.
    var closeAfterHandshake: Int?
    /// Reports that close code only after the connection has already ended,
    /// as a WebSocket delegate can.
    var closeCodeArrivesLate = false
    /// Holds every `recognizer_loop:utterance` until the ask is abandoned: a
    /// turn the hub is still working on.
    var holdUtterances = false
    /// How long putting a frame on the wire takes; a cancelled send is never
    /// put on it.
    var sendMilliseconds = 0

    var connected: Bool { lock.locked { online } }
    var handshakeComplete: Bool { connected }
    var connectionInfo: ThalovantConnectionInfo {
        lock.locked { ThalovantConnectionInfo(phase: online ? "ready" : errored ? "error" : "idle") }
    }
    var lifetime: LinkLifetime? { lock.locked { current } }
    var emitted: [ThalovantEvent] { lock.locked { emissions } }
    var busCount: Int { lock.locked { buses.count } }

    func connect(timeout: TimeInterval) async throws {
        let (life, code, late) = lock.locked { () -> (LinkLifetime?, Int?, Bool) in
            if online { return (nil, nil, false) }
            online = true
            errored = false
            let life = LinkLifetime()
            life.completeHandshake()
            current = life
            return (life, closeAfterHandshake, closeCodeArrivesLate)
        }
        if let life, let code {
            // The hub's verdict follows the handshake at once. Ended here,
            // before the session starts its settle wait, so the outcome never
            // depends on how fast a busy runner schedules a task.
            end(life, closeCode: late ? nil : code)
            if late {
                // The delegate reports the code a moment after the read failed.
                Task {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    life.end(closeCode: code)
                }
            }
        }
    }

    func disconnect() async {
        let life = lock.locked { () -> LinkLifetime? in
            online = false
            return current
        }
        life?.end(closeCode: nil)
    }

    /// The network drops the connection, or the hub closes it with `closeCode`.
    func drop(closeCode: Int? = nil) {
        guard let life = lock.locked({ current }) else { return }
        end(life, closeCode: closeCode)
    }

    private func end(_ life: LinkLifetime, closeCode: Int?) {
        lock.locked {
            guard current === life, online else { return }
            online = false
            errored = true
        }
        life.end(closeCode: closeCode)
    }

    func addBusHandler(_ handler: @escaping (JSONObject) -> Void) -> UUID {
        let id = UUID()
        lock.locked { buses[id] = handler }
        return id
    }

    func removeBusHandler(_ id: UUID) { _ = lock.locked { buses.removeValue(forKey: id) } }

    func emitBus(type: String, data: JSONObject, context: JSONObject) async throws {
        guard connected else { throw ThalovantConnectionError("The fake link is down.") }
        if sendMilliseconds > 0 { try await Task.sleep(nanoseconds: UInt64(sendMilliseconds) * 1_000_000) }
        lock.locked { emissions.append(ThalovantEvent(name: type, data: data, context: context)) }
        if type == ThalovantEvents.recognizerLoopUtterance && holdUtterances {
            try await AsyncGate().wait(timeout: nil, timeoutError: nil)
        }
    }

    /// The hub sends a bus message.
    func deliver(_ type: String, data: JSONObject = [:], context: JSONObject = [:]) {
        let payload: JSONObject = ["type": .string(type), "data": .object(data), "context": .object(context)]
        for handler in lock.locked({ Array(buses.values) }) { handler(payload) }
    }
}

/// A client over `transport`, with a fixture identity.
func fakeClient(_ transport: any HiveMindBusTransport) throws -> ThalovantClient {
    var identity = try ThalovantJSON.decodeObject(Fixtures.clientIdentify)
    identity["default_master"] = .string("wss://hub.example")
    return ThalovantClient(
        identity: try ThalovantIdentity(json: identity), transport: transport, replySettle: 0,
        emptyReplyWait: 0)
}

/// Waits until `predicate` holds, failing after `seconds`.
func eventually(
    _ seconds: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
    _ predicate: () -> Bool
) async throws {
    let end = ProcessInfo.processInfo.systemUptime + seconds
    while !predicate() {
        guard ProcessInfo.processInfo.systemUptime < end else {
            XCTFail("condition never became true", file: file, line: line)
            throw ThalovantTimeoutError("condition never became true")
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

// MARK: - An in-memory hub

/// A cheap stand-in for the Argon2id PSK: a different password still derives a
/// different key, which is all a handshake case needs, and a suite that runs
/// dozens of them does not spend 64 MiB and a tenth of a second on each.
func cheapPSK(_ password: String, _ nodeID: String) throws -> Data {
    noiseHash(Data((password + "\u{0}" + nodeID).utf8))
}

/// A client key store that lives in memory.
final class MemoryNoiseStore: ThalovantNoiseStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key = noiseRandomKey()
    private var pins: [String: Data] = [:]
    func privateKey() throws -> Data { lock.locked { key } }
    /// A new client key; the hub pins stay.
    func replaceClientKey() { lock.locked { key = noiseRandomKey() } }
    func pinnedKey(nodeID: String) throws -> Data? { lock.locked { pins[nodeID] } }
    func pin(_ key: Data, nodeID: String) throws {
        try lock.locked {
            guard pins[nodeID] == nil || pins[nodeID] == key else { throw noiseError("pin conflict") }
            pins[nodeID] = key
        }
    }
}

/// Messages one end of a socket has not read yet.
actor Mailbox {
    private var items: [URLSessionWebSocketTask.Message] = []
    private var waiters: [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = []
    private var failure: Error?

    func put(_ message: URLSessionWebSocketTask.Message) {
        guard failure == nil else { return }
        if waiters.isEmpty { items.append(message) } else { waiters.removeFirst().resume(returning: message) }
    }

    func take() async throws -> URLSessionWebSocketTask.Message {
        if !items.isEmpty { return items.removeFirst() }
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func close(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        for waiter in waiters { waiter.resume(throwing: error) }
        waiters = []
    }
}

/// A HiveMind v3 hub in memory, speaking the hub's side of the Noise
/// negotiation with the SDK's own Noise code, so `HiveMindWSSTransport` runs
/// its real connect -- the negotiation, the KK-then-XX retry, the reading of a
/// failure -- against it. It records the pattern each attempt chose, as the
/// reference's `FakeHub.patterns_chosen` does.
final class MemoryHub: @unchecked Sendable {
    let nodeID = "fake-hub-node"
    private let lock = NSLock()
    private var state = State()
    private struct State {
        var staticKey = noiseRandomKey()
        var offerKK = true
        var upgradeStatus: Int?
        var password = "the-right-password"
        var pinnedClient: Data?
        var patterns: [String] = []
        var attempts = 0
        var closeAfterHandshake: Int?
        var closeAfterHandshakeSpeaks = false
        var spoken = SpokenFrame.json
        var closeCodeLateMs = 0
        var received: [String] = []
        var receivedData: [(String, JSONObject)] = []
        var lastSocket: MemorySocket?
    }

    var staticKey: Data { get { lock.locked { state.staticKey } } set { lock.locked { state.staticKey = newValue } } }
    var offerKK: Bool { get { lock.locked { state.offerKK } } set { lock.locked { state.offerKK = newValue } } }
    /// Answer the WebSocket upgrade with this HTTP status instead.
    var upgradeStatus: Int? { get { lock.locked { state.upgradeStatus } } set { lock.locked { state.upgradeStatus = newValue } } }
    var password: String { get { lock.locked { state.password } } set { lock.locked { state.password = newValue } } }
    /// Close right after the handshake with this code; 0 ends the socket with
    /// no close frame.
    var closeAfterHandshake: Int? {
        get { lock.locked { state.closeAfterHandshake } }
        set { lock.locked { state.closeAfterHandshake = newValue } }
    }
    /// Send one encrypted frame before that close: a hub that has spoken has
    /// accepted the client's key, so the close is a drop.
    var closeAfterHandshakeSpeaks: Bool {
        get { lock.locked { state.closeAfterHandshakeSpeaks } }
        set { lock.locked { state.closeAfterHandshakeSpeaks = newValue } }
    }
    /// What the hub says before that close: a JSON bus message by default.
    var spoken: SpokenFrame { get { lock.locked { state.spoken } } set { lock.locked { state.spoken = newValue } } }
    /// Report a close's code this long after the close, as URLSession can.
    var closeCodeLateMs: Int { get { lock.locked { state.closeCodeLateMs } } set { lock.locked { state.closeCodeLateMs = newValue } } }
    var patterns: [String] { lock.locked { state.patterns } }
    var attempts: Int { lock.locked { state.attempts } }
    /// Whether the hub has pinned a client's key: the client's connect can
    /// return before the hub has read its last handshake message.
    var clientPinned: Bool { lock.locked { state.pinnedClient != nil } }
    /// The bus messages clients sent once connected, by type, in order.
    var received: [String] { lock.locked { state.received } }
    /// The same messages with their data.
    var receivedMessages: [(type: String, data: JSONObject)] {
        lock.locked { state.receivedData.map { (type: $0.0, data: $0.1) } }
    }
    /// The socket the last attempt dialled.
    var lastSocket: MemorySocket? { lock.locked { state.lastSocket } }

    var factory: HiveSocketFactory {
        { [self] _, transport in (MemorySocket(hub: self, transport: transport), nil) }
    }

    /// A transport that dials this hub.
    func transport(password: String? = nil, store: MemoryNoiseStore) throws -> HiveMindWSSTransport {
        let identity = try ThalovantIdentity(json: [
            "access_key": "hub-access", "password": .string(password ?? self.password),
            "default_master": "wss://hub.example", "site_id": "site",
        ])
        return HiveMindWSSTransport(identity: identity, noiseStore: store, socketFactory: factory, derivePSK: cheapPSK)
    }

    /// The hub's side of one socket.
    fileprivate func serve(_ socket: MemorySocket) async {
        let (upgrade, key, offerKK, pinned) = lock.locked { () -> (Int?, Data, Bool, Data?) in
            state.attempts += 1
            state.lastSocket = socket
            return (state.upgradeStatus, state.staticKey, state.offerKK, state.pinnedClient)
        }
        if let upgrade {
            socket.refuseUpgrade(upgrade)
            return
        }
        socket.open()
        let hello: JSONObject = ["pubkey": "hub-public-key", "peer": "site::hub-ac", "node_id": .string(nodeID)]
        let offer: JSONObject = [
            "handshake": true, "min_protocol_version": 2, "max_protocol_version": 3, "binarize": false,
            "preshared_key": false, "password": true, "crypto_required": true,
            "encodings": ["JSON-B64", "JSON-HEX"], "ciphers": ["AES-GCM"],
            "noise": .object([
                "patterns": .array((pinned != nil && offerKK ? ["KKpsk0", "XXpsk2"] : ["XXpsk2"]).map { .string($0) }),
                "suites": .array([.string(NoiseConnection.suite)]),
            ]),
        ]
        do {
            await socket.toClient(HiveMessage(msgType: "hello", payload: hello))
            await socket.toClient(HiveMessage(msgType: "shake", payload: offer))
            guard let first = try await socket.fromClient()?["noise"]?.objectValue,
                  let pattern = first["pattern"]?.stringValue, let suite = first["suite"]?.stringValue,
                  let msg = first["msg"]?.stringValue else { return await socket.closeFromHub(1005, lateMs: 0) }
            lock.locked { state.patterns.append(pattern) }
            let prologue = Data((try noiseCanonical(.object(hello)) + noiseCanonical(.object(offer))
                + "Noise_\(pattern)_\(suite)").utf8)
            let responder = try NoiseConnection(
                pattern: pattern, psk: cheapPSK(password, nodeID), prologue: prologue, privateKey: key,
                pin: pattern == "KKpsk0" ? pinned : nil, initiator: false)
            let answer: Data
            do {
                _ = try responder.read(noiseUnhex(msg))
                answer = try responder.write(Data(#"{"encoding":"JSON-HEX"}"#.utf8))
            } catch {
                // What a hub does when it cannot read a first message: close
                // without a status.
                return await socket.closeFromHub(1005, lateMs: 0)
            }
            await socket.toClient(HiveMessage(msgType: "shake", payload: ["noise": .object(["msg": .string(noiseHex(answer))])]))
            if !responder.ready {
                guard let final = try await socket.fromClient()?["noise"]?["msg"]?.stringValue else {
                    return await socket.closeFromHub(1005, lateMs: 0)
                }
                do { _ = try responder.read(noiseUnhex(final)) } catch { return await socket.closeFromHub(1005, lateMs: 0) }
            }
            let client = responder.remoteKey
            let known = lock.locked { () -> Bool in
                if let pinnedClient = state.pinnedClient, pinnedClient != client { return false }
                state.pinnedClient = client
                return true
            }
            guard known else { return await socket.closeFromHub(1005, lateMs: 0) }
            // The client's encrypted HELLO.
            guard case .data(let frame) = try await socket.takeFromClient(), try responder.decrypt(frame) != nil else {
                return await socket.closeFromHub(1005, lateMs: 0)
            }
            let (closeCode, late, speaks, spoken) = lock.locked {
                (state.closeAfterHandshake, state.closeCodeLateMs, state.closeAfterHandshakeSpeaks, state.spoken)
            }
            if let closeCode {
                if speaks {
                    let frames: [Data]
                    switch spoken {
                    case .json:
                        let ready = try JSONEncoder().encode(HiveWire.busMessage(type: "hub.ready", data: [:], context: [:]))
                        frames = try responder.encrypt(ready)
                    case .binary(let wire):
                        frames = try responder.encrypt(wire, isJSON: false)
                    case .firstChunk:
                        // The first chunk of a larger message (marker 2): it
                        // decrypts, though the message is never whole. Sealed
                        // small, as sealing 65 kB in a debug build would
                        // outlast the settle window.
                        frames = [try responder.sealFrame(Data([2]) + Data(#"{"msg_type": "bus", "#.utf8))]
                    }
                    for frame in frames { await socket.toClientRaw(.data(frame)) }
                }
                return await socket.closeFromHub(closeCode, lateMs: late)
            }
            while true {
                guard case .data(let frame) = try await socket.takeFromClient(),
                      let (payload, isJSON) = try responder.decrypt(frame), isJSON else { continue }
                let message = try JSONDecoder().decode(HiveMessage.self, from: payload)
                if let type = message.payload["type"]?.stringValue {
                    let data = message.payload["data"]?.objectValue ?? [:]
                    lock.locked {
                        state.received.append(type)
                        state.receivedData.append((type, data))
                    }
                }
            }
        } catch {
            return
        }
    }
}

/// What a `MemoryHub` sends before it closes right after the handshake.
enum SpokenFrame {
    case json
    /// A WIRE-1 binary frame, sent as such.
    case binary(Data)
    /// Only the first chunk of a message too big for one frame.
    case firstChunk
}

/// The client's end of a socket to a `MemoryHub`.
final class MemorySocket: HiveSocket, @unchecked Sendable {
    private let hub: MemoryHub
    private weak var transport: HiveMindWSSTransport?
    private let clientBox = Mailbox()
    private let hubBox = Mailbox()
    private let lock = NSLock()
    private var code: Int?
    private var refusedStatus: Int?
    private var hold: AsyncGate?
    private var holding = false

    init(hub: MemoryHub, transport: HiveMindWSSTransport) {
        self.hub = hub
        self.transport = transport
    }

    var peerCloseCode: Int? { lock.locked { code } }
    var upgradeStatus: Int? { lock.locked { refusedStatus } }

    func resume() { Task { await hub.serve(self) } }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await clientBox.take() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let gate = lock.locked { () -> AsyncGate? in
            let gate = hold
            hold = nil
            holding = gate != nil
            return gate
        }
        if let gate {
            // A frame being written: it is finished however long that takes.
            try await gate.wait(timeout: nil, timeoutError: nil)
            lock.locked { holding = false }
        }
        await hubBox.put(message)
    }

    /// Holds the next frame written until `gate` opens.
    func holdNextSend(_ gate: AsyncGate) { lock.locked { hold = gate } }
    /// Whether a frame is being held mid-write.
    var sendHeld: Bool { lock.locked { holding } }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task {
            await hubBox.close(ThalovantConnectionError("The client closed the socket."))
            await clientBox.close(ThalovantConnectionError("The socket is closed."))
        }
    }

    fileprivate func open() {
        transport?.handleSocketOpen(on: self)
    }

    fileprivate func refuseUpgrade(_ status: Int) {
        lock.locked { refusedStatus = status }
        Task { await clientBox.close(ThalovantConnectionError("The server refused the WebSocket upgrade.")) }
    }

    fileprivate func toClient(_ message: HiveMessage) async {
        guard let text = try? HiveWire.encode(message, cryptoKey: nil, encrypt: false) else { return }
        await clientBox.put(.string(text))
    }

    fileprivate func toClientRaw(_ message: URLSessionWebSocketTask.Message) async {
        await clientBox.put(message)
    }

    fileprivate func takeFromClient() async throws -> URLSessionWebSocketTask.Message { try await hubBox.take() }

    /// The next handshake message the client sent, as its payload.
    fileprivate func fromClient() async throws -> JSONObject? {
        guard case .string(let text) = try await hubBox.take() else { return nil }
        return try HiveWire.decode(text: text, cryptoKey: nil).payload
    }

    /// The hub closes the socket with `code` (0: no close frame at all),
    /// reporting the code `lateMs` after the close when that is not zero.
    fileprivate func closeFromHub(_ closeCode: Int, lateMs: Int) async {
        if lateMs == 0 { lock.locked { code = closeCode == 0 ? nil : closeCode } }
        await hubBox.close(ThalovantConnectionError("The hub closed the socket."))
        await clientBox.close(ThalovantConnectionError("The hub closed the socket."))
        guard lateMs > 0, closeCode != 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(lateMs) * 1_000_000)
        lock.locked { code = closeCode }
        transport?.handleSocketClosed(ThalovantConnectionError("The hub closed the socket."), closeCode: closeCode, on: self)
    }
}
