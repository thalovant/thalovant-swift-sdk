import XCTest
@testable import ThalovantSDK

private struct NoiseFixture: Decodable {
    struct Exchange: Decodable {
        let pattern, suite, protocolName, prologue: String
        let payloads, messages, plaintexts, transportI, transportR: [String]
        enum CodingKeys: String, CodingKey {
            case pattern, suite, prologue, payloads, messages, plaintexts
            case protocolName = "protocol", transportI = "transport_i", transportR = "transport_r"
        }
    }
    let password, nodeID, psk, staticI, staticR, ephemeralI, ephemeralR, publicI, publicR: String
    let hello, offer: JSONObject
    let exchanges: [Exchange]
    enum CodingKeys: String, CodingKey {
        case password, psk, hello, offer, exchanges
        case nodeID = "node_id", staticI = "static_i", staticR = "static_r"
        case ephemeralI = "ephemeral_i", ephemeralR = "ephemeral_r", publicI = "public_i", publicR = "public_r"
    }
}
private final class FixtureNoiseStore: ThalovantNoiseStore, @unchecked Sendable {
    let key: Data
    var pinValue: Data?
    init(key: Data, pin: Data? = nil) { self.key = key; pinValue = pin }
    func privateKey() throws -> Data { key }
    func pinnedKey(nodeID: String) throws -> Data? { pinValue }
    func pin(_ key: Data, nodeID: String) throws {
        guard pinValue == nil || pinValue == key else { throw noiseError("pin mismatch") }
        pinValue = key
    }
}

final class NoiseTests: XCTestCase {
    private func fixture() throws -> NoiseFixture {
        let path = try XCTUnwrap(Bundle.module.url(forResource: "noise-node", withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "noise-node", withExtension: "json"))
        return try JSONDecoder().decode(NoiseFixture.self, from: Data(contentsOf: path))
    }
    private func connection(_ v: NoiseFixture, _ e: NoiseFixture.Exchange, initiator: Bool = true) throws -> NoiseConnection {
        try NoiseConnection(pattern: e.pattern, psk: noiseUnhex(v.psk), prologue: noiseUnhex(e.prologue),
                            privateKey: noiseUnhex(initiator ? v.staticI : v.staticR),
                            pin: noiseUnhex(initiator ? v.publicR : v.publicI),
                            ephemeral: noiseUnhex(initiator ? v.ephemeralI : v.ephemeralR), initiator: initiator)
    }
    private func finish(_ v: NoiseFixture, _ e: NoiseFixture.Exchange, initiator: Bool = true) throws -> NoiseConnection {
        let state = try connection(v, e, initiator: initiator)
        for step in e.messages.indices {
            XCTAssertFalse(state.ready)
            if (step % 2 == 0) == initiator {
                XCTAssertEqual(noiseHex(try state.write(Data(e.payloads[step].utf8))), e.messages[step])
            } else {
                XCTAssertEqual(try state.read(noiseUnhex(e.messages[step])), Data(e.payloads[step].utf8))
            }
        }
        XCTAssertTrue(state.ready)
        XCTAssertEqual(noiseHex(state.remoteKey), initiator ? v.publicR : v.publicI)
        return state
    }
    func testArgonPSKMatchesIndependentNodeImplementation() throws {
        let v = try fixture()
        XCTAssertEqual(noiseHex(try noisePSK(password: v.password, nodeID: v.nodeID)), v.psk)
        XCTAssertEqual(noiseHex(try noisePSK(password: "password", nodeID: "node")),
                       "1db10de69fee89b9322e97f2c3dfbc7fb2965da7e60db896720e930a2c908d4e")
    }
    func testExactNodeXXAndKKTranscriptsAndTransportBothDirections() throws {
        let v = try fixture()
        for e in v.exchanges where e.suite == NoiseConnection.suite {
            let expectedPrologue = try noiseCanonical(.object(v.hello)) + noiseCanonical(.object(v.offer)) + e.protocolName
            XCTAssertEqual(noiseHex(Data(expectedPrologue.utf8)), e.prologue)
            for initiator in [true, false] {
                let state = try finish(v, e, initiator: initiator)
                for i in e.plaintexts.indices {
                    let payload = Data(e.plaintexts[i].utf8)
                    let encrypted = try state.encrypt(payload)
                    XCTAssertEqual(encrypted.count, 1)
                    XCTAssertEqual(noiseHex(encrypted[0]), (initiator ? e.transportI : e.transportR)[i])
                    let decoded = try XCTUnwrap(state.decrypt(noiseUnhex((initiator ? e.transportR : e.transportI)[i])))
                    XCTAssertEqual(decoded.0, payload); XCTAssertTrue(decoded.1)
                }
                XCTAssertThrowsError(try state.decrypt(noiseUnhex((initiator ? e.transportR : e.transportI)[0])))
                XCTAssertFalse(state.ready)
                XCTAssertThrowsError(try state.encrypt(Data("after failure".utf8)))
            }
        }
    }
    func testWrongPinTamperedTranscriptAndTruncatedHexFailClosed() throws {
        let v = try fixture(), e = try XCTUnwrap(v.exchanges.first { $0.pattern == "XXpsk2" && $0.suite == NoiseConnection.suite })
        let pin = Data(repeating: 0x55, count: 32)
        let state = try NoiseConnection(pattern: e.pattern, psk: noiseUnhex(v.psk), prologue: noiseUnhex(e.prologue),
                                        privateKey: noiseUnhex(v.staticI), pin: pin, ephemeral: noiseUnhex(v.ephemeralI))
        _ = try state.write(Data(e.payloads[0].utf8))
        XCTAssertThrowsError(try state.read(noiseUnhex(e.messages[1]))); XCTAssertFalse(state.ready)
        let tampered = try connection(v, e)
        _ = try tampered.write(Data(e.payloads[0].utf8))
        var bytes = try noiseUnhex(e.messages[1]); bytes[bytes.count - 1] ^= 1
        XCTAssertThrowsError(try tampered.read(bytes)); XCTAssertFalse(tampered.ready)
        XCTAssertThrowsError(try noiseUnhex("a")); XCTAssertThrowsError(try noiseUnhex("gg"))
    }
    func testOrderedChunksAndClosedSession() throws {
        let v = try fixture(), e = try XCTUnwrap(v.exchanges.first { $0.pattern == "XXpsk2" && $0.suite == NoiseConnection.suite })
        let i = try finish(v, e), r = try finish(v, e, initiator: false)
        let payload = Data(repeating: 0x61, count: 130_100)
        let chunks = try i.encrypt(payload)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertNil(try r.decrypt(chunks[0])); XCTAssertNil(try r.decrypt(chunks[1]))
        XCTAssertEqual(try r.decrypt(chunks[2])?.0, payload)
        i.close(); XCTAssertFalse(i.ready); XCTAssertThrowsError(try i.encrypt(payload))
    }
    func testR8WireNegotiationThenPinnedReconnect() throws {
        let v = try fixture()
        let identity = try ThalovantIdentity(json: ["access_key": "fixture", "password": .string(v.password),
            "default_master": "ws://localhost", "site_id": "fixture"])
        let store = FixtureNoiseStore(key: try noiseUnhex(v.staticI))
        for pattern in ["XXpsk2", "KKpsk0"] {
            let e = try XCTUnwrap(v.exchanges.first { $0.pattern == pattern && $0.suite == NoiseConnection.suite })
            let flow = NoiseNegotiator(identity: identity, store: store,
                                       derive: { _, _ in try noiseUnhex(v.psk) }, ephemeral: { try! noiseUnhex(v.ephemeralI) })
            XCTAssertTrue(try flow.receive(HiveMessage(msgType: "hello", payload: v.hello)).isEmpty)
            let first = try XCTUnwrap(flow.receive(HiveMessage(msgType: "shake", payload: v.offer)).first)
            XCTAssertEqual(first.payload["noise"]?["pattern"]?.stringValue, pattern)
            XCTAssertEqual(first.payload["noise"]?["suite"]?.stringValue, NoiseConnection.suite)
            XCTAssertEqual(first.payload["noise"]?["msg"]?.stringValue, e.messages[0])
            XCTAssertFalse(try XCTUnwrap(flow.connection).ready)
            let final = try flow.receive(HiveMessage(msgType: "shake", payload: ["noise": ["msg": .string(e.messages[1])]]))
            if pattern == "XXpsk2" { XCTAssertEqual(final.first?.payload["noise"]?["msg"]?.stringValue, e.messages[2]) }
            else { XCTAssertTrue(final.isEmpty) }
            XCTAssertEqual(store.pinValue, try noiseUnhex(v.publicR))
            XCTAssertTrue(try XCTUnwrap(flow.connection).ready)
            XCTAssertThrowsError(try flow.receive(HiveMessage(msgType: "hello", payload: v.hello)))
        }
    }
    func testUnsupportedOfferLegacyAndPlaintextBusAreRejected() throws {
        let v = try fixture(), identity = try ThalovantIdentity(json: ["access_key": "fixture", "password": "fixture", "default_master": "ws://localhost", "site_id": "fixture"])
        let store = FixtureNoiseStore(key: try noiseUnhex(v.staticI))
        let flow = NoiseNegotiator(identity: identity, store: store)
        XCTAssertThrowsError(try flow.receive(HiveMessage(msgType: "shake", payload: v.offer)))
        _ = try flow.receive(HiveMessage(msgType: "hello", payload: v.hello))
        XCTAssertThrowsError(try flow.receive(HiveMessage(msgType: "shake", payload: ["preshared_key": true])))
        XCTAssertThrowsError(try flow.receive(HiveMessage(msgType: "bus", payload: [:])))
        var offer = v.offer; offer["noise"] = ["patterns": ["XXpsk2"], "suites": ["25519_ChaChaPoly_SHA256"]]
        XCTAssertThrowsError(try flow.receive(HiveMessage(msgType: "shake", payload: offer)))
        XCTAssertThrowsError(try noiseCanonical(.number(3.5)))
    }
    func testFileStorePersistsAndRejectsPermissionsSymlinksAndPinChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThalovantFileNoiseStore(directory: directory, identityScope: "fixture")
        let key = try store.privateKey()
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(try ThalovantFileNoiseStore(directory: directory, identityScope: "fixture").privateKey(), key)
        let pin = Data(repeating: 0x11, count: 32)
        XCTAssertNil(try store.pinnedKey(nodeID: "hub"))
        try store.pin(pin, nodeID: "hub"); XCTAssertEqual(try store.pinnedKey(nodeID: "hub"), pin)
        XCTAssertThrowsError(try store.pin(Data(repeating: 0x22, count: 32), nodeID: "hub"))
        XCTAssertEqual(try store.pinnedKey(nodeID: "hub"), pin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try store.privateKey())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let keyPath = directory.appendingPathComponent("client-" + noiseHex(noiseHash(Data("fixture".utf8))))
        try FileManager.default.removeItem(at: keyPath)
        try FileManager.default.createSymbolicLink(at: keyPath, withDestinationURL: directory.appendingPathComponent("elsewhere"))
        XCTAssertThrowsError(try store.privateKey())
    }
    func testExistingEmptyOrTruncatedStaticKeyIsNeverReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThalovantFileNoiseStore(directory: directory, identityScope: "fixture")
        _ = try store.privateKey()
        let keyPath = directory.appendingPathComponent("client-" + noiseHex(noiseHash(Data("fixture".utf8))))
        for data in [Data(), Data([1, 2, 3])] {
            try data.write(to: keyPath)
            XCTAssertThrowsError(try store.privateKey())
            XCTAssertEqual(try Data(contentsOf: keyPath), data)
        }
    }
    func testMissingPinLookupDoesNotCreateADataFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThalovantFileNoiseStore(directory: directory, identityScope: "fixture")
        XCTAssertNil(try store.pinnedKey(nodeID: "hub"))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(try XCTUnwrap(files.first).hasSuffix(".lock"))
    }
    func testConcurrentProcessesCreateOnePersistentIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var location = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        var executable: URL?
        for _ in 0..<6 {
            let candidate = location.appendingPathComponent("ThalovantNoiseStoreFixture")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { executable = candidate; break }
            location.deleteLastPathComponent()
        }
        let helper = try XCTUnwrap(executable, "swift build/test must build the test fixture executable")
        let processes: [(Process, Pipe)] = try (0..<8).map { _ in
            let process = Process(), output = Pipe()
            process.executableURL = helper; process.arguments = [directory.path]
            process.standardOutput = output
            try process.run()
            return (process, output)
        }
        var publicKeys = Set<Data>()
        for (process, output) in processes {
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            publicKeys.insert(output.fileHandleForReading.readDataToEndOfFile())
        }
        XCTAssertEqual(publicKeys.count, 1)
        XCTAssertEqual(try XCTUnwrap(publicKeys.first).count, 65)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(files.contains { $0.hasPrefix(".new-") })
    }
    func testSendBeforeHandshakeAndPlaintextOptOutFail() async throws {
        let identity = try ThalovantIdentity(json: ["access_key": "fixture", "password": "fixture", "default_master": "ws://localhost", "site_id": "fixture"])
        let transport = HiveMindWSSTransport(identity: identity)
        for encrypt in [true, false] {
            do { try await transport.send(HiveMessage(msgType: "bus", payload: [:]), encrypt: encrypt); XCTFail("send must fail") }
            catch { XCTAssertTrue(error is ThalovantConnectionError) }
        }
        await transport.disconnect(); XCTAssertFalse(transport.connected); XCTAssertFalse(transport.handshakeComplete)
    }
}
