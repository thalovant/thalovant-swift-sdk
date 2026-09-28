import Foundation
import XCTest

@testable import ThalovantSDK

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Serves one vector case's exchanges in order through URLSession, and checks
/// every request against the one the case names: method, path, body or body
/// subset, `If-Match` and `Authorization`. The same job as the reference's
/// `ScriptedApi` in `tests/test_home_link_vectors.py`, over the SDK's real
/// HTTP path rather than beside it.
final class ScriptedApi: URLProtocol {
    private static let lock = NSLock()
    private static var exchanges: [JSONObject] = []
    private static var index = 0
    private static var sentLines: [String] = []
    private static var mismatchLines: [String] = []

    static let apiURL = "https://api.example.com"

    /// Starts a case: these exchanges, nothing sent yet.
    static func serve(_ next: [JSONObject]) {
        lock.locked {
            exchanges = next
            index = 0
            sentLines = []
            mismatchLines = []
        }
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
            answer(status: 599, contentType: "application/json", body: "{}")
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
            body: response["body"]?.stringValue ?? ""
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

    private func answer(status: Int, contentType: String, body: String) {
        let bytes = Data(body.utf8)
        var headers = ["Content-Length": String(bytes.count)]
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
            current = life
            return (life, closeAfterHandshake, closeCodeArrivesLate)
        }
        if let life, let code {
            // The hub's verdict arrives a moment after the handshake.
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000)
                self.end(life, closeCode: late ? nil : code)
                if late {
                    try? await Task.sleep(nanoseconds: 40_000_000)
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
