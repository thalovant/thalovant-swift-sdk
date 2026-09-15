import XCTest
@testable import ThalovantSDK

/// What a phone calls a hub. It called them slugs until 2026-09-15.
final class HubsTests: XCTestCase {

    private func hub(_ json: String) -> JSONObject {
        try! ThalovantJSON.decodeObject(Data(json.utf8))
    }

    func testAHubIsCalledWhatAPersonWasShown() {
        // Exactly what a phone was offered: name IS the slug, and the readable
        // title sits in the catalog entry.
        XCTAssertEqual(
            hubDisplayName(hub(#"{"name":"ops-copilot","slug":"ops-copilot","spec":{"catalog":{"title":"Ops Copilot"}}}"#)),
            "Ops Copilot")
    }

    func testARealNameWinsWhenThereIsNoCatalogEntry() {
        XCTAssertEqual(hubDisplayName(hub(#"{"name":"The Kitchen","slug":"kitchen"}"#)), "The Kitchen")
    }

    func testASlugIsMadeReadableRatherThanShownRaw() {
        XCTAssertEqual(hubDisplayName(hub(#"{"slug":"daily-desk"}"#)), "Daily Desk")
        XCTAssertEqual(hubDisplayName(hub(#"{"slug":"local_pulse"}"#)), "Local Pulse")
        XCTAssertEqual(hubDisplayName(hub(#"{"name":"news-stream","slug":"news-stream"}"#)), "News Stream")
    }

    func testAHubDescribedWithNothingStillSaysSomething() {
        for json in [#"{"id":"1"}"#, #"{"name":"","slug":"   "}"#, #"{"spec":"nonsense"}"#, #"{"spec":{"catalog":[]}}"#] {
            XCTAssertEqual(hubDisplayName(hub(json)), "A Thalovant hub", json)
        }
    }
}
