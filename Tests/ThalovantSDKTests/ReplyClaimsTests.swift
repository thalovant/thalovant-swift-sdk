import Foundation
import XCTest
@testable import ThalovantSDK
final class ReplyClaimsTests: XCTestCase {
    func testSharedReplyClaimVectors() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "reply-claim-vectors", withExtension: "json"))
        let data = try ThalovantJSON.decodeObject(Data(contentsOf: file))
        for row in data["cases"]!.arrayValue!.compactMap(\.objectValue) {
            let handled = row["handled"]!.boolValue!
            let failed = row["failed"]!.boolValue!
            let contexts = row["contexts"]!.arrayValue!.compactMap(\.objectValue)
            let metas = row["metas"]?.arrayValue ?? []
            let reply = ThalovantReply(text: "reply", displayText: "reply", utterances: [], handled: handled, ok: handled && !failed,
                sessionId: nil, requestId: nil,
                events: contexts.enumerated().map { index, context in
                    let meta = index < metas.count ? metas[index] : .null
                    let data: JSONObject = meta.objectValue != nil ? ["meta": meta] : [:]
                    return ThalovantEvent(name: "speak", data: data, context: context)
                },
                failureEvent: failed ? ThalovantEvent(name: "failure", data: [:], context: [:]) : nil)
            let expected = row["expected"]!.objectValue!
            XCTAssertEqual(reply.pipelineIds, expected["pipeline_ids"]!.arrayValue!.compactMap(\.stringValue))
            XCTAssertEqual(reply.skillIds, expected["skill_ids"]!.arrayValue!.compactMap(\.stringValue))
            XCTAssertEqual(reply.claimed, expected["claimed"]!.boolValue!)
        }
    }

    private func event(pipeline: String, skill: String, meta: JSONObject? = nil) -> ThalovantEvent {
        var data: JSONObject = [:]
        if let meta { data["meta"] = .object(meta) }
        return ThalovantEvent(name: "speak", data: data, context: ["pipeline_id": .string(pipeline), "skill_id": .string(skill)])
    }

    /// (a) A skill's own genuine fallback-tier answer, positively marked, is claimed.
    func testAssertedClaimFromFallbackTierIsClaimed() {
        let reply = ThalovantReply(
            text: "D'accord, la lumière du bureau est éteinte.", displayText: "", utterances: [], handled: true, ok: true,
            sessionId: nil, requestId: nil,
            events: [
                event(
                    pipeline: "ovos-fallback-pipeline-plugin", skill: "thalovant-skill-home.thalovant",
                    meta: [ThalovantEvents.thalovantClaimedMetaKey: true])
            ],
            failureEvent: nil)
        XCTAssertTrue(reply.claimed)
    }

    /// (b) Regression-critical: the fleet's real generic catch-all shape --
    /// fallback tier, a real skill_id, no meta assertion -- must stay unclaimed.
    func testFleetGenericCatchAllWithoutAssertionStaysUnclaimed() {
        let reply = ThalovantReply(
            text: "Je ne peux pas répondre à cela.", displayText: "", utterances: [], handled: true, ok: true,
            sessionId: nil, requestId: nil,
            events: [event(pipeline: "ovos-fallback-pipeline-plugin", skill: "thalovant-skill-custos-fallback.thalovant")],
            failureEvent: nil)
        XCTAssertFalse(reply.claimed)
    }

    /// (c) An assertion on a non-fallback reply is a no-op: already claimed, stays claimed.
    func testAssertionOnNonFallbackReplyIsANoOp() {
        let reply = ThalovantReply(
            text: "Il fait 22 degrés.", displayText: "", utterances: [], handled: true, ok: true,
            sessionId: nil, requestId: nil,
            events: [
                event(
                    pipeline: "ovos-padatious-pipeline-plugin", skill: "thalovant-skill-weather.thalovant",
                    meta: [ThalovantEvents.thalovantClaimedMetaKey: true])
            ],
            failureEvent: nil)
        XCTAssertTrue(reply.claimed)
    }

    /// (d) The assertion cannot rescue a failed reply: the ok/handled gate runs first.
    func testAssertionCannotRescueAFailedReply() {
        let reply = ThalovantReply(
            text: "", displayText: "", utterances: [], handled: true, ok: false,
            sessionId: nil, requestId: nil,
            events: [
                event(
                    pipeline: "ovos-fallback-pipeline-plugin", skill: "thalovant-skill-home.thalovant",
                    meta: [ThalovantEvents.thalovantClaimedMetaKey: true])
            ],
            failureEvent: ThalovantEvent(name: ThalovantEvents.intentUnmatched))
        XCTAssertFalse(reply.claimed)
    }

    /// (e) Only a literal `true` asserts the claim -- false, a string, a
    /// number, or the key missing are all inert.
    func testOnlyALiteralTrueAssertsTheClaim() {
        let badMetas: [JSONObject] = [
            [ThalovantEvents.thalovantClaimedMetaKey: false],
            [ThalovantEvents.thalovantClaimedMetaKey: "true"],
            [ThalovantEvents.thalovantClaimedMetaKey: 1],
            ["unrelated": "value"],
            [:],
        ]
        for meta in badMetas {
            let reply = ThalovantReply(
                text: "Je ne peux pas répondre à cela.", displayText: "", utterances: [], handled: true, ok: true,
                sessionId: nil, requestId: nil,
                events: [event(pipeline: "ovos-fallback-pipeline-plugin", skill: "thalovant-skill-custos-fallback.thalovant", meta: meta)],
                failureEvent: nil)
            XCTAssertFalse(reply.claimed, "meta \(meta) must be inert")
        }
    }
}
