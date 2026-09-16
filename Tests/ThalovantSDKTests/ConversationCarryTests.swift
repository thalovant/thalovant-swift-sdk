import XCTest
@testable import ThalovantSDK

/// Carrying a conversation between the turns of a named session.
///
/// A hub keeps nothing for one: OVOS-SESSION-2 §2.2 makes the orchestrator
/// stateless, so the carrier a client sends is the whole snapshot and whatever
/// the last turn activated is discarded the moment it ends. Without
/// `converse_handlers` the converse pipeline has no skill to poll and every
/// follow-up reaches the fallback instead of the skill that just answered.
///
/// The cases are `contracts/conformance/conversation-vectors.json` and
/// `mesh-vectors.json`, shared with every other SDK so that being on par is
/// something a machine checks rather than something a digest asserts.
final class ConversationCarryTests: XCTestCase {

    func testTheCarryMatchesTheSharedVectors() throws {
        for row in try fixture("conversation-vectors")["cases"]!.arrayValue!.compactMap(\.objectValue) {
            let previous = row["previous"]?.objectValue ?? [:]
            let session = row["session"]?.objectValue ?? [:]
            let carried = carryConversation(previous: previous, session: session)
            // Recorded before the assert: what this SDK produced, not a
            // restatement of what the vector says it should have.
            if case .some(.string(let name)) = row["name"] {
                ConformanceRecord.record("conversation-vectors.json", name, JSONValue.object(carried))
            }
            XCTAssertEqual(JSONValue.object(carried), row["expected"], "\(row["name"] ?? .null)")
        }
    }

    func testTheCarriedFieldsAreTheOnesTheVectorsName() throws {
        let want = try fixture("conversation-vectors")["carried_fields"]!.arrayValue!
            .compactMap(\.stringValue).sorted()
        XCTAssertEqual(conversationSessionFields.sorted(), want)
    }

    func testTheFieldsTheVectorsForbidNeverTravel() throws {
        // A remembered `lang` would pin a bilingual conversation to whichever
        // language it opened in, which is the failure this list prevents.
        for field in try fixture("conversation-vectors")["never_carried"]!.arrayValue!.compactMap(\.stringValue) {
            XCTAssertFalse(conversationSessionFields.contains(field), field)
        }
    }

    func testTheHiveKindsAreTheOnesTheVectorsName() throws {
        let want = try fixture("mesh-vectors")["kinds"]!.arrayValue!.compactMap(\.stringValue).sorted()
        XCTAssertEqual(hiveKinds.sorted(), want)
    }

    func testThisClientsOwnTrafficIsNotAHiveKind() throws {
        // `query` and `cascade` belong to ask; subscribing to one here would
        // quietly compete for the same replies.
        for refused in try fixture("mesh-vectors")["refused_kinds"]!.arrayValue!.compactMap(\.stringValue) {
            XCTAssertFalse(hiveKinds.contains(refused), refused)
        }
    }

    private func fixture(_ name: String) throws -> JSONObject {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: url))
    }
}
