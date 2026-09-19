import Foundation
import XCTest
@testable import ThalovantSDK

/// What an ask does when the hub refuses it, against the vectors every SDK
/// shares.
///
/// `contracts/conformance/refusal-vectors.json` in the Python SDK, vendored
/// here and pinned by the parity contract: a refusal becomes a typed error
/// carrying the hub's code and, for a spent quota, its numbers; an unmatched
/// intent is an unanswered question; and a denial with no request id is taken
/// only by the ask that can be the one it refused.
final class RefusalVectorTests: XCTestCase {

    private func cases() throws -> JSONObject {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "refusal-vectors", withExtension: "json"))
        return try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: url))
    }

    private func event(_ wire: [String: JSONValue]) -> ThalovantEvent {
        ThalovantEvent(
            name: wire["type"]?.stringValue ?? "",
            data: wire["data"]?.objectValue ?? [:],
            context: wire["context"]?.objectValue ?? [:]
        )
    }

    func testEveryFailureEventBecomesTheErrorItsVectorNames() throws {
        for row in try cases()["classification"]!.arrayValue!.compactMap(\.objectValue) {
            let name = row["name"]?.stringValue ?? ""
            let expect = row["expect"]!.objectValue!
            let produced = Refusal.error(for: event(row["event"]!.objectValue!))
            if expect["kind"]?.stringValue == "unanswered" {
                guard let unanswered = produced as? ThalovantUnansweredError else {
                    return XCTFail("\(name): wanted an unanswered question, got \(produced)")
                }
                // What the person said, which is what a caller shows.
                XCTAssertEqual(unanswered.said, expect["said"]?.stringValue, name)
                continue
            }
            guard let refused = produced as? ThalovantPolicyDeniedError else {
                return XCTFail("\(name): wanted a refusal, got \(produced)")
            }
            var quota: JSONValue = .null
            if let numbers = refused.quota {
                // `.integer`, as the vectors decode them: JSONValue keeps
                // whole numbers and doubles apart, so comparing as doubles
                // would never match.
                quota = .object([
                    "period": .string(numbers.period),
                    "limit": .integer(numbers.limit),
                    "used": .integer(numbers.used),
                    "reset_after": .integer(numbers.resetAfter),
                ])
            }
            let actual = JSONValue.object([
                "kind": .string("refused"),
                "denied_type": .string(refused.deniedType),
                "code": .string(refused.code),
                "reason": .string(refused.reason),
                "allowed": .array(refused.allowed.map { .string($0) }),
                "quota": quota,
            ])
            XCTAssertEqual(actual, .object(expect), name)
        }
    }

    func testADenialIsTakenOnlyByTheAskItCanBelongTo() throws {
        for row in try cases()["correlation"]!.arrayValue!.compactMap(\.objectValue) {
            let requestId: String? = switch row["request_id"]?.stringValue {
            case "own": "req-own"
            case "other": "req-other"
            default: nil
            }
            let taken = Refusal.belongsToAsk(
                requestId: requestId,
                ownRequestId: "req-own",
                deniedType: row["denied_type"]?.stringValue,
                asksInFlight: row["asks_in_flight"]?.intValue ?? 0,
                queriesInFlight: row["queries_in_flight"]?.intValue ?? 0,
                sendsInFlight: row["sends_in_flight"]?.intValue ?? 0
            )
            XCTAssertEqual(taken, row["taken"]?.boolValue, row["name"]?.stringValue ?? "")
        }
    }

    func testTheGraceWindowIsTheOneTheVectorsName() throws {
        XCTAssertEqual(
            Refusal.untrackedUtteranceGrace,
            try cases()["untracked_grace_seconds"]?.doubleValue
        )
    }

    private func client(_ fake: RuntimeFake) throws -> ThalovantClient {
        var identity = try ThalovantJSON.decodeObject(Fixtures.clientIdentify)
        identity["default_master"] = .string("wss://hub.example")
        return ThalovantClient(identity: try ThalovantIdentity(json: identity),
            transport: fake, replySettle: 0, emptyReplyWait: 0)
    }

    func testASendThatNeverConnectedIsNotInFlight() async throws {
        // A connect that fails publishes nothing, so there is nothing for the
        // hub to refuse -- and a phantom would suppress a real refusal for the
        // whole grace window.
        let fake = RuntimeFake()
        fake.connectError = ThalovantConnectionError("no route to the hub")
        let sdk = try client(fake)
        defer { Task { await sdk.close() } }
        do {
            try await sdk.sendUtterance("turn the lights off")
            XCTFail("the send should have failed")
        } catch is ThalovantConnectionError {}
        XCTAssertEqual(sdk.utterancesInFlight().sends, 0)
    }

    func testAPublishThatErroredStillCountsBecauseTheHubMayHoldIt() async throws {
        // The transport can fail after the hub already has the frame, and the
        // hub refuses what it holds. Forgetting the send would leave the next
        // ask as the only candidate for a denial that was never its own.
        let fake = RuntimeFake()
        fake.emitAction = { _ in throw ThalovantConnectionError("the write reported a failure") }
        let sdk = try client(fake)
        defer { Task { await sdk.close() } }
        do {
            try await sdk.sendUtterance("turn the lights off")
            XCTFail("the send should have failed")
        } catch is ThalovantConnectionError {}
        XCTAssertEqual(sdk.utterancesInFlight().sends, 1)
    }

    func testTheVectorsCoverEveryKindOfRefusal() throws {
        // A copy that quietly lost its quota or its unanswered case would still pass.
        let classification = try cases()["classification"]!.arrayValue!.compactMap(\.objectValue)
        let codes = Set(classification.compactMap { $0["expect"]?.objectValue?["code"]?.stringValue })
        for code in ["acl_disallowed_type",
                     ThalovantPolicyDeniedError.quotaExceededCode,
                     ThalovantPolicyDeniedError.backendUnavailableCode] {
            XCTAssertTrue(codes.contains(code), code)
        }
        let kinds = Set(classification.compactMap { $0["expect"]?.objectValue?["kind"]?.stringValue })
        XCTAssertEqual(kinds, ["refused", "unanswered"])
        let taken = Set(try cases()["correlation"]!.arrayValue!.compactMap { $0.objectValue?["taken"]?.boolValue })
        XCTAssertEqual(taken, [true, false])
    }
}
