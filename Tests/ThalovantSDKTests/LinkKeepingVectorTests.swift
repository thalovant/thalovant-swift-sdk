import Foundation
import XCTest

@testable import ThalovantSDK

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        XCTAssertEqual(try XCTUnwrap(vectors()["cases"]?.arrayValue).count, 36)
    }

    func testCloseVectors() throws {
        let rows = try cases("close")
        XCTAssertEqual(rows.count, 17)
        for row in rows {
            let name = try XCTUnwrap(row["name"]?.stringValue)
            let refused = LinkLifetime.closeRefuses(
                code: row["code"]?.intValue,
                closedAfterHandshakeMs: row["when"]?.stringValue == "after_handshake" ? row["after_ms"]?.intValue : nil,
                codeLateMs: row["code_late_ms"]?.intValue ?? 0,
                afterAuthenticatedFrame: row["after_authenticated_frame"]?.boolValue ?? false
            )
            let produced: JSONValue = ["outcome": .string(refused ? "refused" : "dropped")]
            ConformanceRecord.record("link-keeping-vectors.json", name, produced)
            XCTAssertEqual(produced, row["expect"], name)
        }
    }

    /// What a connect ended as, in the vectors' words.
    private func outcome(_ error: Error?) -> String {
        guard let error else { return "connected" }
        let failure = error as? ThalovantConnectionError
        switch failure?.kind {
        case .refused? where failure?.clientKeyRejected == true: return "client_key_rejected"
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

    /// One connect as a kept link makes it -- the handshake, then the settle
    /// window -- since a close just after the handshake would otherwise race
    /// the connect returning. The error it ended with, if any.
    private func keptAttempt(_ hub: MemoryHub, _ store: MemoryNoiseStore, password: String? = nil) async throws -> Error? {
        let settle = TimeInterval(try XCTUnwrap(vectors()["policy"]?["settle_ms"]?.intValue)) / 1000
        let session = HubSession(
            connect: {
                let transport = try hub.transport(password: password, store: store)
                let client = ThalovantClient(identity: transport.identity, transport: transport)
                do {
                    try await client.connect(timeout: 10)
                } catch {
                    await client.close()
                    throw error
                }
                return client
            }, policy: try HubSessionPolicy(settleSeconds: settle), warm: false)
        defer { Task { await session.close() } }
        do {
            try await session.connect()
            return nil
        } catch {
            return error
        }
    }

    func testHandshakeVectors() async throws {
        let rows = try cases("handshake")
        XCTAssertEqual(rows.count, 11)
        for row in rows {
            let name = try XCTUnwrap(row["name"]?.stringValue)
            let situation = try XCTUnwrap(row["situation"]?.stringValue, name)
            let hub = MemoryHub()
            var store = MemoryNoiseStore()
            var password: String?
            if [
                "pinned", "password_changed_since_pinning", "hub_key_changed",
                "client_key_changed", "client_key_changed_pinned_here",
            ].contains(situation) {
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
            case "client_key_changed":
                store = MemoryNoiseStore()  // another program: its own folder, its own key
            case "client_key_changed_pinned_here":
                store.replaceClientKey()  // a new key, the hub pins kept
            case "closed_after_first_frame":
                hub.closeAfterHandshake = 1005
                hub.closeAfterHandshakeSpeaks = true
            default:
                break
            }
            let before = hub.patterns.count
            let result = outcome(try await keptAttempt(hub, store, password: password))
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
        XCTAssertEqual(rows.count, 8)
        for row in rows {
            let name = try XCTUnwrap(row["name"]?.stringValue)
            var supervisor = LinkSupervisor(policy: try HubSessionPolicy(
                retrySeconds: seconds("retry_ms"), retryCeilingSeconds: seconds("retry_ceiling_ms"),
                probeSeconds: seconds("probe_ms"), probeDownSeconds: seconds("probe_down_ms"),
                refusalGraceSeconds: seconds("refusal_grace_ms")))
            var produced: [JSONValue] = []
            for event in (row["events"]?.arrayValue ?? []).compactMap(\.objectValue) {
                // LinkOutcome is a public enum, so it has no case of its own
                // for the hub refusing the client's key: that is a refusal,
                // marked beside it, as HubSession.run() feeds it.
                let word = try XCTUnwrap(event["outcome"]?.stringValue)
                let keyRejected = word == "client_key_rejected"
                let outcome = try XCTUnwrap(keyRejected ? .refused : LinkOutcome(rawValue: word), name)
                let at = TimeInterval(try XCTUnwrap(event["at_ms"]?.intValue, name)) / 1000
                switch supervisor.after(outcome, at: at, clientKeyRejected: keyRejected) {
                case .hold:
                    produced.append(["action": "hold"])
                case .retry(let wait):
                    produced.append(["action": "retry", "wait_ms": .integer(Int((wait * 1000).rounded()))])
                case .giveUp(let given):
                    let reason = try XCTUnwrap(supervisor.giveUpReason, name)
                    XCTAssertEqual(given, reason == .keyChanged ? .keyChanged : .refused, name)
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
                // A refusal as XX ends, with nothing from the hub between: the
                // hub refusing this client's own key.
                XCTAssertEqual(error.clientKeyRejected, refused, error.message)
                XCTAssertTrue(
                    error.message.contains(refused ? "Re-pair, or share the key folder" : "right after the handshake"),
                    error.message)
            }
            XCTAssertFalse(session.held)
            await session.close()
        }
    }

    func testEveryFrameThatDecryptsCounts() async throws {
        let frames = try loadVectors("binary-frames")
        let wire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(frames["bus_frame"]?.stringValue)))
        for spoken in [SpokenFrame.json, .binary(wire), .firstChunk] {
            let hub = MemoryHub()
            hub.closeAfterHandshake = 1005
            hub.closeAfterHandshakeSpeaks = true
            hub.spoken = spoken
            let session = session(hub, MemoryNoiseStore())
            do {
                try await session.connect()
                XCTFail("\(spoken): expected the close to be read")
            } catch let error as ThalovantConnectionError {
                XCTAssertEqual(error.kind, .other, "\(spoken): the hub had spoken, so the close is a drop: \(error.message)")
                XCTAssertFalse(error.clientKeyRejected, "\(spoken)")
            }
            await session.close()
        }
    }

    func testTheSameCloseAfterKKIsAPlainRefusal() async throws {
        let hub = MemoryHub()
        let store = MemoryNoiseStore()
        let pinning = try await attempt(hub, store)
        XCTAssertNil(pinning)
        try await eventually { hub.clientPinned }
        hub.closeAfterHandshake = 1005
        let session = session(hub, store)
        do {
            try await session.connect()
            XCTFail("expected a refusal")
        } catch let error as ThalovantConnectionError {
            XCTAssertEqual(error.kind, .refused, error.message)
            XCTAssertFalse(error.clientKeyRejected, "the hub could complete KK only with the key it pinned")
        }
        // KK completed: no XX follows it.
        XCTAssertEqual(hub.patterns, ["XXpsk2", "KKpsk0"])
        await session.close()
    }

    func testRunStopsAtOnceWhenTheHubRefusesTheClientsKey() async throws {
        let hub = MemoryHub()
        let pinning = try await attempt(hub, MemoryNoiseStore())
        XCTAssertNil(pinning)
        try await eventually { hub.clientPinned }
        // Another program reading the same identity, with a key of its own.
        let session = session(hub, MemoryNoiseStore())
        do {
            try await session.run()
            XCTFail("expected the client's key refused")
        } catch let error as ThalovantConnectionError {
            XCTAssertEqual(error.kind, .refused, "still caught where a refusal is")
            XCTAssertTrue(error.clientKeyRejected, error.message)
        }
        // No retry through the refusal grace: one attempt, then run() ends.
        XCTAssertEqual(hub.attempts, 2)
        await session.close()
    }

    func testAFrameThatDecryptedEndsTheRefusalWindow() {
        let refused = LinkLifetime()
        refused.pattern = "XXpsk2"
        refused.heardAuthenticatedFrame()  // before the handshake: not the hub's word on it
        refused.completeHandshake()
        refused.end(closeCode: 1005)
        XCTAssertTrue(refused.refused)
        XCTAssertTrue(refused.clientKeyRejected)

        let spoke = LinkLifetime()
        spoke.pattern = "XXpsk2"
        spoke.completeHandshake()
        spoke.heardAuthenticatedFrame()
        spoke.end(closeCode: 1005)
        XCTAssertFalse(spoke.refused)
        XCTAssertFalse(spoke.clientKeyRejected)

        let kk = LinkLifetime()
        kk.pattern = "KKpsk0"
        kk.completeHandshake()
        kk.end(closeCode: 1008)
        XCTAssertTrue(kk.refused)
        XCTAssertFalse(kk.clientKeyRejected, "after KK the same close is a plain refusal")
        XCTAssertFalse(kk.refusalAfterHandshake().clientKeyRejected)
    }

    func testTheRefusedKeyErrorNamesTheKeyFolders() throws {
        let custom = FileManager.default.temporaryDirectory.appendingPathComponent("thalovant-\(UUID().uuidString)")
        let placed = noiseKeyFolders(ThalovantFileNoiseStore(directory: custom, identityScope: "hub-access"))
        XCTAssertEqual(placed.used, custom.standardizedFileURL.path)
        XCTAssertEqual(placed.other, ThalovantFileNoiseStore.defaultDirectory.standardizedFileURL.path)
        let usual = noiseKeyFolders(ThalovantFileNoiseStore(identityScope: "hub-access"))
        XCTAssertEqual(usual.used, ThalovantFileNoiseStore.defaultDirectory.standardizedFileURL.path)
        XCTAssertNil(usual.other)
        let memory = noiseKeyFolders(MemoryNoiseStore())
        XCTAssertNil(memory.used)
        XCTAssertNil(memory.other)

        let lifetime = LinkLifetime(keyFolder: placed.used, otherKeyFolder: placed.other)
        lifetime.pattern = "XXpsk2"
        lifetime.completeHandshake()
        lifetime.end(closeCode: nil)  // no close frame: a drop, not a refusal
        XCTAssertFalse(lifetime.refused)
        let error = ThalovantConnectionError.clientKeyRejected(keyFolder: placed.used, otherKeyFolder: placed.other)
        XCTAssertEqual(error.kind, .refused)
        XCTAssertTrue(error.clientKeyRejected)
        XCTAssertEqual(error.keyFolder, placed.used)
        XCTAssertEqual(error.otherKeyFolder, placed.other)
        XCTAssertTrue(error.message.contains(try XCTUnwrap(placed.used)), error.message)
        XCTAssertTrue(error.message.contains(try XCTUnwrap(placed.other)), error.message)
        XCTAssertTrue(error.message.contains("Re-pair, or share the key folder"), error.message)
        // A refusal built the ordinary way is never one of these.
        XCTAssertFalse(ThalovantConnectionError("refused", kind: .refused).clientKeyRejected)
    }

    func testACloseBeforeConnectReturnsIsStillReadByItsCode() async throws {
        // The hub closes as soon as it has read this side's HELLO, which can be
        // before connect() has seen its handshake gate open: the transport
        // reads that close by its code as the session would after connect().
        for (code, refused) in [(1005, true), (1008, true), (1011, false)] {
            for _ in 0..<20 {
                let hub = MemoryHub()
                hub.closeAfterHandshake = code
                let transport = try hub.transport(store: MemoryNoiseStore())
                do {
                    try await transport.connect(timeout: 10)
                    // connect() won the race: the link is up, and ends at once.
                    let lifetime = try XCTUnwrap(transport.lifetime)
                    try await lifetime.ended.wait(timeout: 2, timeoutError: ThalovantTimeoutError("never ended"))
                    await lifetime.awaitLateCode()
                    XCTAssertEqual(lifetime.refused, refused, "\(code)")
                } catch let error as ThalovantConnectionError {
                    XCTAssertEqual(error.kind == .refused, refused, "\(code): \(error.message)")
                    // A fresh store meets the hub with XX, so a refusal as it
                    // ends is the hub turning this client's key away.
                    XCTAssertEqual(error.clientKeyRejected, refused, "\(code): \(error.message)")
                    if !refused {
                        XCTAssertTrue(error.message.contains("right after the handshake"), error.message)
                    }
                }
                await transport.disconnect()
            }
        }
    }

    func testACloseAfterTheHandshakeButBeforeConnectReturnedIsReadByItsCode() async throws {
        // The window a macOS runner hit: the handshake completed, the hub
        // closed, and connect() saw the socket gone before it could return.
        // What connect() then throws is read from the close, as after it.
        let transport = try MemoryHub().transport(store: MemoryNoiseStore())
        let lost = noiseError("Connection closed during Noise negotiation.")
        for (code, lateMs, refused) in [(1005, 0, true), (1008, 0, true), (1000, 50, true), (1011, 0, false), (0, 0, false)] {
            let attempt = LinkLifetime()
            attempt.completeHandshake()
            attempt.end(closeCode: lateMs > 0 ? nil : code)
            if lateMs > 0 {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(lateMs) * 1_000_000)
                    attempt.end(closeCode: code)
                }
            }
            let verdict = await transport.classify(lost, socket: QuietSocket(), attempt: attempt)
            let error = try XCTUnwrap(verdict as? ThalovantConnectionError, "\(code)")
            XCTAssertEqual(error.kind == .refused, refused, "\(code) learnt \(lateMs) ms late")
            XCTAssertTrue(error.message.contains("right after the handshake"), error.message)
        }
        // One that had not ended is what it was.
        let open = LinkLifetime()
        open.completeHandshake()
        let kept = await transport.classify(lost, socket: QuietSocket(), attempt: open)
        XCTAssertEqual((kept as? ThalovantConnectionError)?.message, lost.message)
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

/// A socket that has nothing to say: no upgrade status, no close code.
private final class QuietSocket: HiveSocket {
    func resume() {}
    func receive() async throws -> URLSessionWebSocketTask.Message { throw CancellationError() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
    var peerCloseCode: Int? { nil }
    var upgradeStatus: Int? { nil }
}
