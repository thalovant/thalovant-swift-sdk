import XCTest
@testable import ThalovantSDK

/// A hub substitutes its own session id; the request id is what correlates.
///
/// Observed against a live hub on 2026-09-03: a client declaring
/// `session_id="observe-me"` gets every reply back carrying the hub's own
/// uuid. Comparing session ids rejected replies the request id had already
/// identified as ours, so `ask()` timed out while the hub had answered.
///
/// The filter under test lives inline in Client.addBusListener; this pins the
/// decision table it implements.
final class SessionNatTests: XCTestCase {
    private func accepts(askedSession: String?, askedRequest: String?,
                         replySession: String?, replyRequest: String?) -> Bool {
        if let askedRequest, let replyRequest { return replyRequest == askedRequest }
        if let askedSession, let replySession { return replySession == askedSession }
        return true
    }

    func testMatchingRequestIdWinsOverSubstitutedSession() {
        XCTAssertTrue(accepts(askedSession: "observe-me", askedRequest: "req-1",
                              replySession: "71048b7f-e7b0", replyRequest: "req-1"))
    }

    func testWrongRequestIdRejectedEvenIfSessionsAgree() {
        XCTAssertFalse(accepts(askedSession: "same", askedRequest: "req-1",
                               replySession: "same", replyRequest: "req-2"))
    }

    func testWithoutRequestIdsTheSessionStillDecides() {
        XCTAssertTrue(accepts(askedSession: "s1", askedRequest: nil,
                              replySession: "s1", replyRequest: nil))
        XCTAssertFalse(accepts(askedSession: "s1", askedRequest: nil,
                               replySession: "s2", replyRequest: nil))
    }
}
