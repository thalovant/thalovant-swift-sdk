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
            let reply = ThalovantReply(text: "reply", displayText: "reply", utterances: [], handled: handled, ok: handled && !failed,
                sessionId: nil, requestId: nil, events: row["contexts"]!.arrayValue!.compactMap(\.objectValue).map { ThalovantEvent(name: "speak", data: [:], context: $0) },
                failureEvent: failed ? ThalovantEvent(name: "failure", data: [:], context: [:]) : nil)
            let expected = row["expected"]!.objectValue!
            XCTAssertEqual(reply.pipelineIds, expected["pipeline_ids"]!.arrayValue!.compactMap(\.stringValue))
            XCTAssertEqual(reply.skillIds, expected["skill_ids"]!.arrayValue!.compactMap(\.stringValue))
            XCTAssertEqual(reply.claimed, expected["claimed"]!.boolValue!)
        }
    }
}
