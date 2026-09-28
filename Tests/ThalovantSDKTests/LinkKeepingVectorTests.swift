import Foundation
import XCTest

@testable import ThalovantSDK

/// Keeping a hub link up, against the vectors every SDK shares
/// (`link-keeping-vectors.json`, vendored and pinned by the parity contract).
///
/// `close` cases hold the transport's reading of a close to the vectors
/// (`LinkLifetime.closeRefuses`). `handshake` cases run a real connect of
/// `HiveMindWSSTransport` -- its negotiation, its KK-then-XX retry and its
/// reading of the failure -- against an in-memory hub that speaks the hub's
/// side of the Noise handshake with the SDK's own Noise code and records the
/// pattern each attempt chose. `supervise` cases drive `LinkSupervisor`, the
/// decision `HubSession.run()` asks after every attempt.
final class LinkKeepingVectorTests: XCTestCase {

    private func vectors() throws -> JSONObject { try loadVectors("link-keeping-vectors") }

    private func cases(_ kind: String) throws -> [JSONObject] {
        try XCTUnwrap(vectors()["cases"]?.arrayValue).compactMap(\.objectValue)
            .filter { $0["kind"]?.stringValue == kind }
    }

    func testThePolicyIsTheSDKs() throws {
        let policy = try XCTUnwrap(vectors()["policy"]?.objectValue)
        let defaults = try HubSessionPolicy()
        XCTAssertEqual(Int(defaults.retrySeconds * 1000), policy["retry_ms"]?.intValue)
        XCTAssertEqual(Int(defaults.retryCeilingSeconds * 1000), policy["retry_ceiling_ms"]?.intValue)
        XCTAssertEqual(Int(defaults.probeSeconds * 1000), policy["probe_ms"]?.intValue)
        XCTAssertEqual(Int(defaults.probeDownSeconds * 1000), policy["probe_down_ms"]?.intValue)
        XCTAssertEqual(Int(defaults.refusalGraceSeconds * 1000), policy["refusal_grace_ms"]?.intValue)
        XCTAssertEqual(Int(defaults.settleSeconds * 1000), policy["settle_ms"]?.intValue)
        XCTAssertEqual(LinkLifetime.refusalSettleMs, policy["settle_ms"]?.intValue)
        XCTAssertEqual(LinkLifetime.closeCodeGraceMs, policy["close_code_grace_ms"]?.intValue)
        XCTAssertEqual(
            .array(LinkLifetime.refusalCloseCodes.sorted().map { .integer($0) }), policy["refusal_close_codes"])
        XCTAssertEqual(try XCTUnwrap(vectors()["cases"]?.arrayValue).count, 29)
    }

    func testCloseVectors() throws {
        let rows = try cases("close")
        XCTAssertEqual(rows.count, 14)
        for row in rows {
            let name = try XCTUnwrap(row["name"]?.stringValue)
            let refused = LinkLifetime.closeRefuses(
                code: row["code"]?.intValue,
                closedAfterHandshakeMs: row["when"]?.stringValue == "after_handshake" ? row["after_ms"]?.intValue : nil,
                codeLateMs: row["code_late_ms"]?.intValue ?? 0
            )
            let produced: JSONValue = ["outcome": .string(refused ? "refused" : "dropped")]
            ConformanceRecord.record("link-keeping-vectors.json", name, produced)
            XCTAssertEqual(produced, row["expect"], name)
        }
    }

    /// What a connect ended as, in the vectors' words.
    private func outcome(_ error: Error?) -> String {
        guard let error else { return "connected" }
        switch (error as? ThalovantConnectionError)?.kind {
        case .refused?: return "refused"
        case .keyChanged?: return "key_changed"
        default: return "failed"
        }
    }

    /// One connect through a fresh transport; the error it ended with, if any.
    private func attempt(_ hub: MemoryHub, _ store: MemoryNoiseStore, password: String? = nil) async throws -> Error? {
        let transport = try hub.transport(password: password, store: store)
        defer { Task { await transport.disconnect() } }
        do {
            try await transport.connect(timeout: 10)
            return nil
        } catch {
            return error
        }
    }

    func testHandshakeVectors() async throws {
        let rows = try cases("handshake")
        XCTAssertEqual(rows.count, 8)
        for row in rows {
            let name = try XCTUnwrap(row["name"]?.stringValue)
            let situation = try XCTUnwrap(row["situation"]?.stringValue, name)
            let hub = MemoryHub()
            let store = MemoryNoiseStore()
            var password: String?
            if ["pinned", "password_changed_since_pinning", "hub_key_changed"].contains(situation) {
                // First contact pins both ways.
                let first = try await attempt(hub, store)
                XCTAssertNil(first, "\(name): \(String(describing: first))")
                try await eventually { hub.clientPinned }
            }
            switch situation {
            case "wrong_password":
                password = "a-wrong-password"
            case "password_changed_since_pinning":
                hub.password = "the-password-now"  // the hub's side changed
                password = "the-right-password"
            case "hub_key_changed":
                hub.staticKey = noiseRandomKey()  // the hub was replaced
                hub.offerKK = try XCTUnwrap(row["hub_offers_kk"]?.boolValue, name)
            case "upgrade_status":
                hub.upgradeStatus = try XCTUnwrap(row["status"]?.intValue, name)
            default:
                break
            }
            let before = hub.patterns.count
            let result = outcome(try await attempt(hub, store, password: password))
            let patterns = hub.patterns.dropFirst(before).map { JSONValue.string(String($0.prefix(2))) }
            let produced: JSONValue = ["outcome": .string(result), "patterns": .array(Array(patterns))]
            ConformanceRecord.record("link-keeping-vectors.json", name, produced)
            XCTAssertEqual(produced, row["expect"], name)
        }
    }

    func testSuperviseVectors() throws {
        let policy = try XCTUnwrap(vectors()["policy"]?.objectValue)
        func seconds(_ key: String) throws -> TimeInterval {
            TimeInterval(try XCTUnwrap(policy[key]?.intValue)) / 1000
        }
        let rows = try cases("supervise")
        XCTAssertEqual(rows.count, 7)
        for row in rows {
            let name = try XCTUnwrap(row["name"]?.stringValue)
            var supervisor = LinkSupervisor(policy: try HubSessionPolicy(
                retrySeconds: seconds("retry_ms"), retryCeilingSeconds: seconds("retry_ceiling_ms"),
                probeSeconds: seconds("probe_ms"), probeDownSeconds: seconds("probe_down_ms"),
                refusalGraceSeconds: seconds("refusal_grace_ms")))
            var produced: [JSONValue] = []
            for event in (row["events"]?.arrayValue ?? []).compactMap(\.objectValue) {
                let outcome = try XCTUnwrap(LinkOutcome(rawValue: try XCTUnwrap(event["outcome"]?.stringValue)), name)
                let at = TimeInterval(try XCTUnwrap(event["at_ms"]?.intValue, name)) / 1000
                switch supervisor.after(outcome, at: at) {
                case .hold:
                    produced.append(["action": "hold"])
                case .retry(let wait):
                    produced.append(["action": "retry", "wait_ms": .integer(Int((wait * 1000).rounded()))])
                case .giveUp(let reason):
                    produced.append(["action": "give_up", "reason": .string(reason.rawValue)])
                }
            }
            let value = JSONValue.array(produced)
            ConformanceRecord.record("link-keeping-vectors.json", name, value)
            XCTAssertEqual(value, row["expect"], name)
        }
    }

    // MARK: The same rules, through a kept link

    /// Quick retries; the settle wait stays generous, since a close ends it
    /// early and a busy runner must not see a refused link counted as up.
    private static let fast = try! HubSessionPolicy(
        retrySeconds: 0.05, retryCeilingSeconds: 0.1, probeSeconds: 0.05, probeDownSeconds: 0.05,
        refusalGraceSeconds: 30, settleSeconds: 0.75)

    private func session(_ hub: MemoryHub, _ store: MemoryNoiseStore) -> HubSession {
        HubSession(
            connect: {
                let transport = try hub.transport(store: store)
                let client = ThalovantClient(identity: transport.identity, transport: transport)
                do {
                    try await client.connect(timeout: 10)
                } catch {
                    await client.close()
                    throw error
                }
                return client
            }, policy: Self.fast, warm: false)
    }

    func testRunStopsAtOnceWhenTheHubKeyChanged() async throws {
        let hub = MemoryHub()
        let store = MemoryNoiseStore()
        let pinning = try await attempt(hub, store)
        XCTAssertNil(pinning)
        try await eventually { hub.clientPinned }  // pins both ways
        hub.staticKey = noiseRandomKey()
        let session = session(hub, store)
        do {
            try await session.run()
            XCTFail("expected a changed key")
        } catch let error as ThalovantConnectionError {
            XCTAssertEqual(error.kind, .keyChanged)
        }
        // KK against the old key fails, XX follows at once and meets the pin:
        // run() ends there rather than retrying for ever.
        XCTAssertEqual(hub.patterns.suffix(2), ["KKpsk0", "XXpsk2"])
        XCTAssertEqual(hub.attempts, 3)
        await session.close()
    }

    func testARealCloseRightAfterTheHandshake() async throws {
        for (code, late, refused) in [
            (1005, 0, true), (1000, 0, true), (1008, 0, true), (1011, 0, false), (1001, 0, false), (0, 0, false),
            // A code URLSession reports late: well inside the 250 ms grace,
            // and well past it.
            (1005, 50, true), (1008, 600, false),
        ] {
            let hub = MemoryHub()
            hub.closeAfterHandshake = code
            hub.closeCodeLateMs = late
            let session = session(hub, MemoryNoiseStore())
            do {
                try await session.connect()
                XCTFail("\(code): expected the close to be read")
            } catch let error as ThalovantConnectionError {
                XCTAssertEqual(error.kind == .refused, refused, "\(code) learnt \(late) ms late: \(error.message)")
                XCTAssertTrue(error.message.contains("right after the handshake"), error.message)
            }
            XCTAssertFalse(session.held)
            await session.close()
        }
    }

    func testTheRetryAfterAFailedKKHappensInsideOneConnect() async throws {
        let hub = MemoryHub()
        let store = MemoryNoiseStore()
        let pinning = try await attempt(hub, store)
        XCTAssertNil(pinning)
        try await eventually { hub.clientPinned }
        hub.password = "rotated"
        // Both sides have the new password: KK simply works.
        let transport = try hub.transport(password: "rotated", store: store)
        try await transport.connect(timeout: 10)
        XCTAssertEqual(hub.patterns.last, "KKpsk0")
        await transport.disconnect()
        // A client still holding the old password: KK fails, and the XX attempt
        // made at once inside the same connect says it is the password.
        let stale = try hub.transport(password: "the-right-password", store: store)
        do {
            try await stale.connect(timeout: 10)
            XCTFail("expected a refusal")
        } catch let error as ThalovantConnectionError {
            XCTAssertEqual(error.kind, .refused)
        }
        XCTAssertEqual(hub.patterns.suffix(2), ["KKpsk0", "XXpsk2"])
        await stale.disconnect()
    }
}
