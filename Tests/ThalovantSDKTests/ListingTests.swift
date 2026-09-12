import Foundation
import XCTest
@testable import ThalovantSDK

final class ListingTests: XCTestCase {
    private func data(_ text: String) throws -> JSONObject { try JSONDecoder().decode(JSONObject.self,from:Data(text.utf8)) }
    private func fixture(_ name: String) throws -> JSONObject {
        let url = try XCTUnwrap(Bundle.module.url(forResource:name,withExtension:"json"))
        return try JSONDecoder().decode(JSONObject.self,from:Data(contentsOf:url))
    }
    func testPublishedPythonListingReferenceCases() throws {
        for row in try fixture("listing-vectors")["cases"]!.arrayValue!.compactMap(\.objectValue) {
            let lang = row["lang"]?.stringValue; let actual: JSONValue
            switch row["kind"]!.stringValue! {
            case "sentence": actual = .string(asSentence(row["text"]!.stringValue!,lang:lang))
            case "speakable": actual = .string(speakableWithLanguage(row["text"]!.stringValue!,lang:lang))
            default: actual = .array(ListingRules.bundled.rank(row["phrases"]!.arrayValue!.compactMap(\.stringValue),lang:lang).map(JSONValue.string))
            }
            XCTAssertEqual(actual,row["expected"],"\(row)")
        }
    }
    func testOvosLanguageMatchingReferenceCases() throws {
        for row in try fixture("language-matching-vectors")["cases"]!.arrayValue!.compactMap(\.objectValue) {
            XCTAssertEqual(closestLanguage(row["target"]!.stringValue!,available:row["available"]!.arrayValue!.compactMap(\.stringValue)),row["expected"]?.stringValue,"\(row)")
        }
    }
    func testSelectedLocaleAndRenderedLimits() {
        let intent = HubIntent(skillId:"s",name:"n",engine:"padatious",phrases:["fr-FR":["volume {level} pour cent"],"en-US":["volume {level} percent"]],languages:["fr-FR","en-US"])
        XCTAssertEqual(intent.examplesWithListing(sentence:true),["Volume cinquante pour cent."])
        XCTAssertEqual(intent.examplesWithListing(lang:"en-GB",sentence:true,slots:["level":"ten"]),["Volume ten percent."])
        let repeated = HubIntent(skillId:"s",name:"n",engine:"padatious",phrases:["en-US":["[please]","(repeat|say) that (again|)","[please] repeat that","volume [to] {level} percent"]])
        for limit in [0,2] { XCTAssertEqual(repeated.examplesWithListing(lang:"en-US",limit:limit,sentence:true),["Repeat that.","Volume fifty percent."]) }
        XCTAssertEqual(repeated.examples(lang:"en-US",limit:0),repeated.phrases["en-US"])
    }
    func testIndependentOptionalRulesAndOwnedData() throws {
        var tree = try data(#"{"sentence_ends":".!?","languages":{"xq":{"question_patterns":["(?i)^is it","(?m)^can it"],"slot_examples":{"thing":"the widget"}}}}"#)
        let rules = try ListingRules(data:tree); tree["languages"] = .object([:])
        XCTAssertEqual(rules.asSentence("is it ready",lang:"xq"),"Is it ready?")
        XCTAssertEqual(rules.asSentence("can it work",lang:"xq"),"Can it work?")
        XCTAssertEqual(rules.asSentence("go home",lang:"xq"),"Go home.")
        XCTAssertEqual(rules.asSentence("what time is it",lang:"en"),"What time is it")
        XCTAssertEqual(rules.speakable("open {thing}",lang:"xq-ZZ"),"open the widget")
        let anywhere = try ListingRules(data:data(#"{"sentence_ends":".!?","languages":{"xq":{"question_words_anywhere":["plim"]}}}"#))
        XCTAssertEqual(anywhere.asSentence("go plim now",lang:"xq"),"Go plim now?")
    }
    func testBareDataAndInvalidOrExpensiveRules() throws {
        let bare = try ListingRules(data:nil); XCTAssertFalse(bare.available)
        XCTAssertEqual(bare.asSentence("do i need a jacket",lang:"en"),"Do i need a jacket")
        XCTAssertEqual(bare.speakable("volume [to] {level} percent",lang:"en"),"volume level percent")
        XCTAssertThrowsError(try ListingRules(data:data(#"{"languages":{"xq":{"question_patterns":["("]}}}"#)))
        let costly = try ListingRules(data:data(#"{"sentence_ends":".!?","languages":{"xq":{"question_patterns":["(a+)+$"]}}}"#))
        let text = String(repeating:"a",count:100000)+"x"
        let start = Date()
        XCTAssertThrowsError(try costly.asks(text,lang:"xq"))
        XCTAssertLessThan(Date().timeIntervalSince(start),2)
        XCTAssertTrue(costly.asSentence(text,lang:"xq") == "A"+text.dropFirst())
    }

    func testUnicodeNonBoundaries() throws {
        let rules = try ListingRules(data: JSONDecoder().decode(JSONObject.self,from:Data(#"{"languages":{"xq":{"question_patterns":["\\Bété\\B"]}}}"#.utf8)))
        XCTAssertFalse(try rules.asks("été",lang:"xq"))
        XCTAssertTrue(try rules.asks("pétéx",lang:"xq"))
    }

    func testManifestLanguageSpellingPreservesOrder() {
        let intent = HubIntent(skillId:"s",name:"n",engine:"padatious",phrases:["en_us":["English"],"fr_fr":["Français"]],languages:["fr-FR","en-US"])
        XCTAssertEqual(intent.examples(limit:1),["Français"])
        let exact = HubIntent(skillId:"s",name:"n",engine:"padatious",phrases:["fr-FR":["Exact"],"fr_fr":["Other"]],languages:["fr-FR"])
        XCTAssertEqual(exact.examples(limit:1),["Exact"])
    }
}
