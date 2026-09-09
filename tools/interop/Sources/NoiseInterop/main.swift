import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@_spi(Testing) import ThalovantSDK

enum FixtureFailure: Error { case barrierTimedOut, invalidBarrierAcknowledgement }

actor Replies {
    var count = 0
    func accept(_ event: JSONObject) { if event["type"]?.stringValue == "fixture.pong" { count += 1 } }
    func received() -> Int { count }
}
actor PhysicalWriteBarrier {
    private var started = false, released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func pause() async {
        started = true
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func hasStarted() -> Bool { started }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@main struct Interop {
    // Callback bridge also supports FoundationNetworking in Swift 5.10.
    static func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, let response { continuation.resume(returning: (data, response)) }
                else { continuation.resume(throwing: FixtureFailure.invalidBarrierAcknowledgement) }
            }.resume()
        }
    }

    static func waitForFirstSocketClose(endpoint: String) async throws {
        var url = URLComponents(string: endpoint)!
        url.scheme = "http"
        url.path = "/fixture/status"
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let request = URLRequest(url: url.url!, timeoutInterval: 5)
            let (data, response) = try await Self.request(request)
            let status = try JSONDecoder().decode([String: Int].self, from: data)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw FixtureFailure.invalidBarrierAcknowledgement
            }
            if status["closedBatches"] == 1 { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw FixtureFailure.barrierTimedOut
    }

    static func releaseHandshake(on transport: HiveMindWSSTransport, endpoint: String, batch: Int) async throws {
        #if DEBUG
        let deadline = Date().addingTimeInterval(10)
        while transport._pendingConnectHandshakeWaiters != 3 {
            guard Date() < deadline else { throw FixtureFailure.barrierTimedOut }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        var url = URLComponents(string: endpoint)!
        url.scheme = "http"
        url.path = "/fixture/release/\(batch)"
        var request = URLRequest(url: url.url!, timeoutInterval: 10)
        request.httpMethod = "POST"
        let (data, response) = try await Self.request(request)
        let acknowledgement = try JSONDecoder().decode([String: Int].self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              acknowledgement["connections"] == batch, acknowledgement["barriers"] == batch else {
            throw FixtureFailure.invalidBarrierAcknowledgement
        }
        #else
        fatalError("The concurrency fixture requires a debug build with test SPI.")
        #endif
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Supply loopback ws:// endpoint") }
        let endpoint = CommandLine.arguments[1]
        guard endpoint.hasPrefix("ws://127.0.0.1:") else { fatalError("Only loopback test endpoints are accepted") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try ThalovantIdentity(json: ["access_key":"fixture", "password":"fixture-password",
            "default_master":.string(endpoint), "site_id":"fixture"])
        let store = ThalovantFileNoiseStore(directory: directory, identityScope: "fixture")
        let transport = HiveMindWSSTransport(identity: identity, noiseStore: store)
        let replies = Replies()
        transport.addBusHandler { event in Task { await replies.accept(event) } }
        for attempt in 0..<2 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for n in 0..<3 {
                    group.addTask {
                        try await transport.connect(timeout: 20)
                        try await transport.emitBus(type: "fixture.ping", data: ["n":.integer(n)], context: [:])
                    }
                }
                // The peer sends no HELLO/offer until all three connect calls
                // are suspended inside this socket's handshake gate.
                try await releaseHandshake(on: transport, endpoint: endpoint, batch: attempt + 1)
                try await group.waitForAll()
            }
            guard transport.connected && transport.handshakeComplete else { fatalError("Premature readiness") }
            let base = attempt * 5
            for _ in 0..<100 {
                if await replies.received() == base + 3 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard await replies.received() == base + 3 else { fatalError("Missing encrypted replies") }
            #if DEBUG
            let barrier = PhysicalWriteBarrier()
            transport._setNextApplicationWriteBarrier { await barrier.pause() }
            let cancelled = Task { try await transport.emitBus(type: "fixture.ping", data: ["n": .integer(3)], context: [:]) }
            let admissionDeadline = Date().addingTimeInterval(10)
            while !(await barrier.hasStarted()) {
                guard Date() < admissionDeadline else { throw FixtureFailure.barrierTimedOut }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let survivor = Task { try await transport.emitBus(type: "fixture.ping", data: ["n": .integer(4)], context: [:]) }
            cancelled.cancel()
            do { try await cancelled.value; fatalError("Caller cancellation was ignored") } catch is CancellationError {}
            guard transport.connected && transport.handshakeComplete else { fatalError("Caller cancellation closed shared session") }
            await barrier.release()
            try await survivor.value
            #endif
            for _ in 0..<100 {
                if await replies.received() == base + 5 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard await replies.received() == base + 5 else { fatalError("Missing retained-write or successor reply") }
            await transport.disconnect()
            guard !transport.connected && !transport.handshakeComplete else { fatalError("Stale readiness") }
            if attempt == 0 { try await waitForFirstSocketClose(endpoint: endpoint) }
        }
        print("Swift WSS two three-caller barriers, XX -> KK reconnect, ten encrypted exchanges and active-write cancellation isolation: passed")
    }
}
