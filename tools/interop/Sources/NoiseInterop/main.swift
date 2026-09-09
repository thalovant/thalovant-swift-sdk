import Foundation
import ThalovantSDK

actor Replies {
    var count = 0
    func accept(_ event: JSONObject) { if event["type"]?.stringValue == "fixture.pong" { count += 1 } }
    func received() -> Int { count }
}
@main struct Interop {
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
            try await transport.connect(timeout: 20)
            guard transport.connected && transport.handshakeComplete else { fatalError("Premature readiness") }
            for n in 0..<3 { try await transport.emitBus(type: "fixture.ping", data: ["n":.integer(n)], context: [:]) }
            for _ in 0..<100 {
                if await replies.received() == (attempt + 1) * 3 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard await replies.received() == (attempt + 1) * 3 else { fatalError("Missing encrypted replies") }
            await transport.disconnect()
            guard !transport.connected && !transport.handshakeComplete else { fatalError("Stale readiness") }
        }
        print("Swift WSS XX -> KK reconnect, six encrypted exchanges: passed")
    }
}
