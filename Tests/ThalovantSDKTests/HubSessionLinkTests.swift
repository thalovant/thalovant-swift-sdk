import Foundation
import XCTest

@testable import ThalovantSDK

/// `HubSession` as a kept link -- `connect()`, `run()`, `stateChanges()` -- and
/// the Home Assistant link answered over it, end to end against an in-memory
/// hub whose connections end the way a real hub ends them.
final class HubSessionLinkTests: XCTestCase {

    private static let fast = try! HubSessionPolicy(
        retrySeconds: 0.05, retryCeilingSeconds: 0.2, probeSeconds: 0.05, probeDownSeconds: 0.05,
        refusalGraceSeconds: 0.4, settleSeconds: 0.1)

    /// Builds a client over a new fake for every attempt, as a real factory
    /// dials a new socket.
    private final class Hub: @unchecked Sendable {
        private let lock = NSLock()
        private var built: [LinkFake] = []
        /// The close code the hub refuses the next attempts with; nil admits.
        var refuseWith: Int? {
            get { lock.locked { refusal } }
            set { lock.locked { refusal = newValue } }
        }
        private var refusal: Int?
        var unreachable = false
        var lateCodes = false
        var attempts: Int { lock.locked { built.count } }
        var latest: LinkFake? { lock.locked { built.last } }

        func connect() async throws -> ThalovantClient {
            let fake = LinkFake()
            fake.holdUtterances = true
            fake.closeAfterHandshake = refuseWith
            fake.closeCodeArrivesLate = lateCodes
            lock.locked { built.append(fake) }
            if unreachable { throw ThalovantConnectionError("Could not reach the hub.") }
            let client = try fakeClient(fake)
            try await client.connect()
            return client
        }
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var all: [String] { lock.locked { stored } }
        func add(_ line: String) { lock.locked { stored.append(line) } }
    }

    private func session(_ hub: Hub, policy: HubSessionPolicy = fast, log: Lines? = nil) -> HubSession {
        HubSession(
            connect: { try await hub.connect() }, policy: policy, warm: false,
            debugLog: log.map { lines in { @Sendable line in lines.add(line) } })
    }

    func testRunKeepsTheLinkConnectOpenedAndDialsAgainWhenItDrops() async throws {
        let hub = Hub()
        let lines = Lines()
        let session = session(hub, log: lines)
        let changes = session.stateChanges()
        let states = Task { () -> [Bool] in
            var seen: [Bool] = []
            for await state in changes { seen.append(state) }
            return seen
        }
        try await session.connect()
        XCTAssertTrue(session.connected)
        XCTAssertEqual(hub.attempts, 1)
        let runner = Task { try await session.run() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(hub.attempts, 1, "the link connect() opened is the one run() keeps")
        hub.latest?.drop()
        try await eventually { hub.attempts == 2 && session.connected }
        await session.close()
        try await runner.value
        let seen = await states.value
        XCTAssertEqual(Array(seen.prefix(3)), [true, false, true])
        XCTAssertEqual(seen.last, false)
        XCTAssertTrue(lines.all.contains("hub link: dropped"), "\(lines.all)")
        XCTAssertTrue(lines.all.contains("hub link: connecting"), "\(lines.all)")
    }

    func testARefusalIsRetriedThroughTheGraceThenThrown() async throws {
        let hub = Hub()
        hub.refuseWith = 1005
        let session = session(hub)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try await session.run()
            XCTFail("expected a refusal")
        } catch is ThalovantHubRefusedError {}
        XCTAssertGreaterThanOrEqual(hub.attempts, 2, "the first refusals were 'not admitted yet'")
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.4)
        XCTAssertFalse(session.held)
        await session.close()
    }

    func testARefusalThatClearsInsideTheGraceConnects() async throws {
        let hub = Hub()
        hub.refuseWith = 1008
        let session = session(hub, policy: try HubSessionPolicy(
            retrySeconds: 0.05, retryCeilingSeconds: 0.1, probeSeconds: 0.05, probeDownSeconds: 0.05,
            refusalGraceSeconds: 30, settleSeconds: 0.1))
        let runner = Task { try await session.run() }
        try await eventually { hub.attempts >= 2 }
        hub.refuseWith = nil  // the hub admits it
        try await eventually { session.connected }
        await session.close()
        try await runner.value
    }

    func testAHubThatClosesRightAfterTheHandshakeRefusedIt() async throws {
        for code in [1000, 1005, 1008] {
            let hub = Hub()
            hub.refuseWith = code
            let session = session(hub)
            do {
                try await session.connect()
                XCTFail("\(code): expected a refusal")
            } catch is ThalovantHubRefusedError {}
            XCTAssertFalse(session.held, "\(code)")
            hub.refuseWith = nil
            try await session.connect()
            XCTAssertTrue(session.connected, "\(code)")
            await session.close()
        }
    }

    func testARefusalWhoseCloseCodeArrivesLateIsStillARefusal() async throws {
        let hub = Hub()
        hub.refuseWith = 1005
        hub.lateCodes = true
        let session = session(hub)
        do {
            try await session.connect()
            XCTFail("expected a refusal")
        } catch is ThalovantHubRefusedError {}
        await session.close()
    }

    func testAnyOtherEarlyCloseIsADropNotARefusal() async throws {
        for code in [1001, 1011, 1013, nil] as [Int?] {
            let hub = Hub()
            let session = session(hub)
            let fakeRefusal = code ?? 0  // 0: the socket went without a close
            hub.refuseWith = fakeRefusal
            do {
                try await session.connect()
                XCTFail("\(fakeRefusal): expected a connection error")
            } catch let error as ThalovantConnectionError {
                XCTAssertTrue(error.message.contains("right after the handshake"), error.message)
            }
            await session.close()
        }
    }

    func testAnUnreachableHubIsAConnectionErrorAndRunClimbsTheLadder() async throws {
        let hub = Hub()
        hub.unreachable = true
        let session = session(hub)
        do {
            try await session.connect()
            XCTFail("expected a connection error")
        } catch let error as any ThalovantConnectionFailure {
            XCTAssertFalse(error is ThalovantHubRefusedError)
        }
        XCTAssertEqual(session.retryWait, 0.1, "the ladder doubled")
        let runner = Task { try await session.run() }
        try await eventually { hub.attempts >= 4 }
        XCTAssertEqual(session.retryWait, 0.2, "and stopped at its ceiling")
        await session.close()
        try await runner.value
    }

    func testSubscriptionsFollowEveryClientTheSessionBuilds() async throws {
        let hub = Hub()
        let session = session(hub)
        let seen = Lines()
        let subscription = try session.on("hub.says") { seen.add($0.data["word"]?.stringValue ?? "") }
        let runner = Task { try await session.run() }
        try await eventually { session.connected }
        hub.latest?.deliver("hub.says", data: ["word": "one"])
        try await eventually { seen.all == ["one"] }
        hub.latest?.drop()
        try await eventually { hub.attempts == 2 && session.connected }
        hub.latest?.deliver("hub.says", data: ["word": "two"])
        try await eventually { seen.all == ["one", "two"] }
        subscription.close()
        hub.latest?.deliver("hub.says", data: ["word": "three"])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(seen.all, ["one", "two"])
        await session.close()
        try await runner.value
    }

    func testHomeRequestsAreAnsweredMidTurnBackAlongTheirRoute() async throws {
        let hub = Hub()
        let session = session(hub)
        let heard = Lines()
        let answering = try session.answerHomeRequests { request in
            heard.add(request.utterance)
            return HomeAnswer(speech: "<speak>Turned off the kitchen light.</speak>")
        }
        try await session.connect()
        let fake = try XCTUnwrap(hub.latest)
        // A turn the hub is still working on holds the session...
        let turn = Task { try await session.ask("what's on in the kitchen", timeout: 5) }
        try await eventually { fake.emitted.contains { $0.name == ThalovantEvents.recognizerLoopUtterance } }
        let asked = ProcessInfo.processInfo.systemUptime
        // ...while a home skill asks the home something.
        fake.deliver(
            HomeLink.requestMessageType,
            data: ["request_id": "r1", "utterance": "turn off the kitchen light", "lang": "en-US"],
            context: [
                "source": "thalovant-skill-home", "destination": ["ha-peer"],
                "session": ["session_id": "kitchen"],
            ])
        try await eventually { fake.emitted.contains { $0.name == HomeLink.responseMessageType } }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - asked, 1, "the answer waited behind the turn")
        let response = try XCTUnwrap(fake.emitted.first { $0.name == HomeLink.responseMessageType })
        XCTAssertEqual(heard.all, ["turn off the kitchen light"])
        XCTAssertEqual(response.data, [
            "request_id": "r1", "speech": "Turned off the kitchen light.", "response_type": "action_done",
            "continue_conversation": false,
        ])
        XCTAssertEqual(response.context["destination"], "thalovant-skill-home")
        XCTAssertEqual(response.context["source"], "ha-peer")
        XCTAssertEqual(response.context["session"]?["session_id"], "kitchen")
        turn.cancel()
        _ = try? await turn.value
        answering.close()
        await session.close()
    }

    func testClosingTheSubscriptionCancelsTheAnswersStillRunning() async throws {
        let hub = Hub()
        let session = session(hub)
        let entered = AsyncGate()
        let answering = try session.answerHomeRequests { _ in
            entered.open()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return HomeAnswer(speech: "never")
        }
        try await session.connect()
        let fake = try XCTUnwrap(hub.latest)
        fake.deliver(HomeLink.requestMessageType, data: ["request_id": "r1", "utterance": "slow"])
        try await entered.wait(timeout: 2, timeoutError: ThalovantTimeoutError("the handler never ran"))
        answering.close()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(fake.emitted.contains { $0.name == HomeLink.responseMessageType })
        await session.close()
    }

    func testAClosedSessionEndsItsStreamsAndItsRun() async throws {
        let session = session(Hub())
        await session.close()
        var states = session.stateChanges().makeAsyncIterator()
        let next = await states.next()
        XCTAssertNil(next)
        try await session.run()
        do {
            try await session.connect()
            XCTFail("expected a closed session")
        } catch is ThalovantConnectionError {}
    }

    func testCancellingRunStopsIt() async throws {
        let hub = Hub()
        hub.unreachable = true
        let session = session(hub)
        let runner = Task { try await session.run() }
        try await eventually { hub.attempts >= 1 }
        runner.cancel()
        do {
            try await runner.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        await session.close()
    }

    func testThePolicyRefusesWaitsThatCannotWork() {
        XCTAssertThrowsError(try HubSessionPolicy(refusalGraceSeconds: 0))
        XCTAssertThrowsError(try HubSessionPolicy(refusalGraceSeconds: .infinity))
        XCTAssertThrowsError(try HubSessionPolicy(settleSeconds: -1))
        XCTAssertThrowsError(try HubSessionPolicy(settleSeconds: .nan))
        let defaults = try? HubSessionPolicy()
        XCTAssertEqual(defaults?.refusalGraceSeconds, 600)
        XCTAssertEqual(defaults?.settleSeconds, 0.75)
        XCTAssertEqual(try? HubSessionPolicy(settleSeconds: 0).settleSeconds, 0)
    }

    func testAnEndedLifetimeKeepsTheFirstVerdictAndLearnsALateCode() {
        let dropped = LinkLifetime()
        dropped.end(closeCode: 0)
        XCTAssertTrue(dropped.ended.isOpen)
        XCTAssertNil(dropped.closeCode, "0 is no code")
        XCTAssertFalse(dropped.coded.isOpen)
        dropped.end(closeCode: 1005)
        XCTAssertEqual(dropped.closeCode, 1005, "the delegate reported it after the read failed")
        XCTAssertTrue(dropped.coded.isOpen)
        let refused = LinkLifetime()
        refused.end(closeCode: 1008)
        refused.end(closeCode: 1011)
        XCTAssertTrue(refused.refused)
        XCTAssertEqual(refused.closeCode, 1008)
    }
}
