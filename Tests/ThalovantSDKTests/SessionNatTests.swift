import XCTest
@testable import ThalovantSDK

/// A hub rewrites a declared session id; replies must still be recognised.
///
/// hivemind-core derives a Layer-1 identity for every client-declared session
/// as `{conn_nonce}:{declared}` (HIVEMIND-BRIDGE-1 §4). Comparing the returned
/// id to the sent one for equality rejected every reply: `ask()` timed out
/// while the hub had already answered. Reproduced against a live hub 2026-09-03.
final class SessionNatTests: XCTestCase {
    func testNatRewrittenReplyIsRecognised() {
        XCTAssertTrue(sessionIdsMatch(expected: "my-session", actual: "d41d8cd98f00b204:my-session"))
    }

    func testUnrewrittenReplyIsStillRecognised() {
        XCTAssertTrue(sessionIdsMatch(expected: "my-session", actual: "my-session"))
    }

    func testReplyForADifferentSessionIsRejected() {
        XCTAssertFalse(sessionIdsMatch(expected: "my-session", actual: "nonce:other"))
        XCTAssertFalse(sessionIdsMatch(expected: "my-session", actual: "other"))
    }

    func testOnlyTheDeclaredHalfAfterTheFirstColonMatches() {
        // a bare hasSuffix would wrongly accept these
        XCTAssertFalse(sessionIdsMatch(expected: "abc", actual: "nonce:xabc"))
        XCTAssertFalse(sessionIdsMatch(expected: "abc", actual: "nonce:abc:def"))
        // a declared id containing a colon still matches as a whole
        XCTAssertTrue(sessionIdsMatch(expected: "a:b", actual: "nonce:a:b"))
        XCTAssertFalse(sessionIdsMatch(expected: "abc", actual: ""))
        XCTAssertFalse(sessionIdsMatch(expected: "abc", actual: "nonce:"))
    }
}
