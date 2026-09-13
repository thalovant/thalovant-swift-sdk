import Foundation
import XCTest

@testable import ThalovantSDK

private final class SessionCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() -> Int {
    lock.locked {
      count += 1
      return count
    }
  }
  var value: Int { lock.locked { count } }
}

final class SessionInventoryTests: XCTestCase {
  func testSharedPythonReferenceSurvivesSortedJSON() throws {
    let file = try XCTUnwrap(
      Bundle.module.url(forResource: "inventory-vectors", withExtension: "json"))
    let data = try ThalovantJSON.decodeObject(Data(contentsOf: file))
    let inventory = try Inventory.fromJSON(JSONEncoder().encode(data["inventory"]!))
    for row in data["examples"]!.arrayValue!.compactMap(\.objectValue) {
      XCTAssertEqual(
        inventory.intents[0].examples(
          language: row["language"]?.stringValue, limit: row["limit"]!.intValue!),
        row["expected"]!.arrayValue!.compactMap(\.stringValue))
    }
    for row in data["speaks"]!.arrayValue!.compactMap(\.objectValue) {
      XCTAssertEqual(
        inventory.skills[0].speaks(row["language"]!.stringValue!), row["expected"]!.boolValue)
    }
    XCTAssertNil(inventory.skills[1].speaks("en"))
  }

  private func client(_ fake: RuntimeFake) throws -> ThalovantClient {
    var identity = try ThalovantJSON.decodeObject(Fixtures.clientIdentify)
    identity["default_master"] = .string("wss://hub.example")
    return ThalovantClient(
      identity: try ThalovantIdentity(json: identity), transport: fake, replySettle: 0,
      emptyReplyWait: 0)
  }
  func testAmbiguousDispatchIsNotReplayedAndSubscriptionsSurviveReplacement() async throws {
    let first = RuntimeFake()
    let second = RuntimeFake()
    first.emitAction = { _ in throw ThalovantConnectionError("closed after send") }
    let clients = try [client(first), client(second)]
    let builds = SessionCounter()
    let received = SessionCounter()
    let session = HubSession(connect: { clients[min(builds.increment() - 1, 1)] }, warm: false)
    let subscription = try session.on("speak") { _ in _ = received.increment() }
    do {
      try await session.emit("action")
      XCTFail("Expected dispatch failure")
    } catch is ThalovantConnectionError {}
    XCTAssertEqual(builds.value, 1)
    XCTAssertEqual(first.emitted.count, 1)
    XCTAssertFalse(session.held)
    try await session.emit("next")
    first.deliver("speak")
    second.deliver("speak")
    XCTAssertEqual(builds.value, 2)
    XCTAssertEqual(received.value, 1)
    subscription.close()
    second.deliver("speak")
    XCTAssertEqual(received.value, 1)
    await session.close()
  }
  func testForegroundBypassesBackoffAndCloseIsTerminal() async throws {
    let attempts = SessionCounter()
    let connected = try client(RuntimeFake())
    let session = HubSession(
      connect: {
        if attempts.increment() == 1 { throw ThalovantConnectionError("unavailable") }
        return connected
      }, clock: { 100 }, warm: false)
    XCTAssertEqual(session.probeDelay(), 5)
    await session.warm()?.value
    await session.warm()?.value
    XCTAssertEqual(attempts.value, 1)
    XCTAssertEqual(session.retryAt, 110)
    XCTAssertEqual(session.retryWait, 20)
    try await session.emit("foreground")
    XCTAssertEqual(attempts.value, 2)
    XCTAssertEqual(session.retryWait, 10)
    XCTAssertEqual(session.probeDelay(), 60)
    await session.close()
    do {
      try await session.emit("closed")
      XCTFail("Expected terminal close")
    } catch is ThalovantConnectionError {}
    XCTAssertThrowsError(try session.on("speak") { _ in })
    XCTAssertNil(session.warm())
    XCTAssertEqual(attempts.value, 2)
  }
  func testCloseWaitsForActiveCallAndCancelledQueueDoesNotDispatch() async throws {
    let fake = RuntimeFake()
    let connected = try client(fake)
    let entered = AsyncGate()
    let release = AsyncGate()
    fake.emitAction = { _ in
      entered.open()
      try await release.wait(
        timeout: 5, timeoutError: ThalovantTimeoutError("Test release missing"))
    }
    let session = HubSession(connect: { connected }, warm: false)
    let owner = Task { try await session.emit("owner") }
    defer {
      release.open()
      owner.cancel()
    }
    try await entered.wait(timeout: 2, timeoutError: ThalovantTimeoutError("Test barrier missing"))
    let queued = Task { try await session.emit("queued") }
    queued.cancel()
    do {
      try await queued.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    let closed = AsyncGate()
    let closing = Task {
      await session.close()
      closed.open()
    }
    // Closure cannot complete while the admitted transport operation owns the connection.
    XCTAssertFalse(closed.isOpen)
    XCTAssertTrue(fake.connected)
    release.open()
    try await owner.value
    await closing.value
    XCTAssertFalse(fake.connected)
    XCTAssertEqual(fake.emitted.count, 1)
  }
  func testOriginFallbackPreservesHostAndCancellationDoesNotFallback() async throws {
    let preference = try OriginPreference(address: "10.0.0.2")
    let options = OriginAttempt(host: "hub.example", connectTimeout: 12)
    var attempts = [OriginAttempt]()
    let result: String = try await preference.connect(options) { attempt in
      attempts.append(attempt)
      if attempt.address != nil { throw ThalovantConnectionError("offline") }
      return "public"
    }
    XCTAssertEqual(result, "public")
    XCTAssertEqual(attempts.count, 2)
    XCTAssertTrue(attempts.allSatisfy { $0.host == "hub.example" })
    XCTAssertEqual(attempts[0].handshakeSeconds, 1.5)
    XCTAssertTrue(preference.coolingDown)
    let cancelled = try OriginPreference(address: "10.0.0.2")
    var count = 0
    do {
      let _: String = try await cancelled.connect(options) { _ in
        count += 1
        throw CancellationError()
      }
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    XCTAssertEqual(count, 1)
    XCTAssertFalse(cancelled.coolingDown)
  }
  private func sample() -> Inventory {
    Inventory(
      hubId: "hub", hubName: "Kitchen", source: "hub", generatedAt: "2026-09-13T00:00:00Z",
      skills: [
        Skill(
          id: "weather", title: "Weather", locales: ["en-us"],
          intents: [
            Intent(
              id: "weather.now", name: "weather.now", skillId: "weather", engine: "padatious",
              phrases: ["fr-fr": ["météo"], "en-us": ["weather", "what is the weather"]],
              languages: ["fr-fr", "en-us"])
          ]), Skill(id: "unknown", title: "Unknown"),
      ])
  }
  func testInventoryRoundTripPreservesLanguageOrderAndRejectsMalformedShape() throws {
    let inventory = try Inventory.fromJSON(sample().asJSON())
    XCTAssertTrue(inventory.live)
    XCTAssertTrue(inventory.hasPhrases)
    XCTAssertEqual(inventory.skills[0].speaks("en-gb"), true)
    XCTAssertEqual(inventory.skills[0].speaks("de"), false)
    XCTAssertNil(inventory.skills[1].speaks("en"))
    XCTAssertEqual(inventory.intents[0].examples(limit: 0), ["météo"])
    XCTAssertEqual(
      inventory.intents[0].examples(language: "en-gb", limit: 0),
      ["weather", "what is the weather"])
    XCTAssertEqual(languagesPresent(inventory), ["en-us", "fr-fr"])
    var raw = try ThalovantJSON.decodeObject(inventory.asJSON())
    raw.removeValue(forKey: "notes")
    XCTAssertThrowsError(try Inventory.fromJSON(JSONEncoder().encode(raw)))
    raw = try ThalovantJSON.decodeObject(inventory.asJSON())
    raw["cache_version"] = .bool(true)
    XCTAssertThrowsError(try Inventory.fromJSON(JSONEncoder().encode(raw)))
  }
  func testCachePrivacyTraversalCorruptionAndExpiry() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try InventoryCache(directory: directory)
    cache.store("valid", inventory: sample())
    XCTAssertNotNil(cache.load("valid"))
    let file = try cache.path("valid")
    let info = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual((info[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    cache.store("../../escape", inventory: sample())
    XCTAssertNil(cache.load("../../escape"))
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: file.path)
    XCTAssertNil(cache.load("valid"))
    try Data("{broken".utf8).write(to: file)
    XCTAssertNil(cache.load("valid"))
    cache.store("valid", inventory: sample())
    XCTAssertNotNil(cache.load("valid"))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
  }
  func testPolicyAndPresentationBoundaries() throws {
    for invalid in [0, -1, Double.nan, Double.infinity] {
      XCTAssertThrowsError(try HubSessionPolicy(retrySeconds: invalid))
    }
    XCTAssertThrowsError(try HubSessionPolicy(retrySeconds: 20, retryCeilingSeconds: 10))
    XCTAssertEqual(friendlyTitle("ovos-skill-weather.openvoiceos"), "Weather")
    XCTAssertEqual(commonAffix(["weather.intent", "time.intent"]).kind, "suffix")
    XCTAssertEqual(stripAffix("", kind: "suffix", token: ""), "")
    XCTAssertEqual(compareNames("Skill2", "Skill10"), .orderedAscending)
  }
}
