import XCTest
@testable import ThalovantSDK

/// The tag to retry a listing with, when the hub had nothing under the one
/// asked for.
///
/// These answers are CLDR's, not this SDK's, and must match the Python
/// reference: a managed port that disagreed about which language to retry
/// would list a different hub.
final class UsualFormTests: XCTestCase {

    func testARegionalTagBecomesTheFormSkillsRegister() {
        XCTAssertEqual(usualForm("en-CA"), "en-us")
        XCTAssertEqual(usualForm("en-AT"), "en-us")
        XCTAssertEqual(usualForm("fr-BE"), "fr-fr")
        XCTAssertEqual(usualForm("pt-AO"), "pt-br")
        XCTAssertEqual(usualForm("pt-PT"), "pt-br")
        XCTAssertEqual(usualForm("de-AT"), "de-de")
    }

    func testATagAlreadyUsualHasNothingToRetryWith() {
        // nil rather than the same tag, so a hub that answered is never asked
        // twice.
        XCTAssertNil(usualForm("en-US"))
        XCTAssertNil(usualForm("en-us"))
        XCTAssertNil(usualForm("fr-FR"))
    }

    func testALanguageNobodyHasHeardOfIsNilAndNotAGuess() {
        // `maximize` does not fail on an unknown language: it walks down to
        // "und" and takes the root locale's region, so "zzz" would come back
        // "zzz-us" -- a confident United States for a language that does not
        // exist.
        XCTAssertNil(usualForm("zzz"))
        XCTAssertNil(usualForm(""))
        XCTAssertNil(usualForm("xx-YY"))
    }
}
