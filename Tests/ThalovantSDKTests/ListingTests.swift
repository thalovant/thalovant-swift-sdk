import Foundation
import XCTest
@testable import ThalovantSDK

final class ListingTests: XCTestCase {
    func testQuestionReference() throws {
        for row in try fixture("question-vectors")["cases"]!.arrayValue!.compactMap(\.objectValue) {
            XCTAssertEqual(try ListingRules.bundled.asks(row["text"]!.stringValue!,lang:row["lang"]?.stringValue),row["expected"]?.boolValue,"\(row)")
        }
    }
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
    /// The budget counts matching work, not time: a pathological rule is cut,
    /// explicitly and identically every time, and an ordinary one never is.
    func testTheRuleBudgetIsWorkNotTime() throws {
        let costly = try ListingRules(data:data(#"{"sentence_ends":".!?","languages":{"xq":{"question_patterns":["(a+)+$"],"question_openers":["como"]}}}"#))
        let pathological = String(repeating:"a",count:40)+"x"
        for _ in 0..<5 {
            XCTAssertThrowsError(try costly.asks(pathological,lang:"xq")) { XCTAssertEqual($0 as? ListingRuleError, .regexBudgetExceeded) }
            XCTAssertEqual(costly.asSentence(pathological,lang:"xq"),"A"+pathological.dropFirst(),"a cut rule leaves the line bare")
            XCTAssertEqual(costly.asSentence("como esta el tiempo",lang:"xq"),"Como esta el tiempo?")
        }
        // A text past the input bound is cut before any rule runs, whatever it says.
        let ordinary = try ListingRules(data:data(#"{"sentence_ends":".!?","languages":{"xq":{"question_patterns":["\\bplim\\b"]}}}"#))
        let atBound = String(repeating:"b",count:ListingRules.maxRuleText-5)+" plim"
        XCTAssertTrue(try ordinary.asks(atBound,lang:"xq"))
        XCTAssertThrowsError(try ordinary.asks(atBound+" b",lang:"xq")) { XCTAssertEqual($0 as? ListingRuleError, .regexBudgetExceeded) }
        XCTAssertEqual(ordinary.asSentence(atBound+" b",lang:"xq"),"B"+(atBound+" b").dropFirst())
    }
    /// The work budget is shared by every rule in one call: many rules that are
    /// each affordable on a short text are cut together.
    func testManyAffordableRulesShareOneBudget() throws {
        let text = String(repeating:"a",count:18)+"x"
        let one = try ListingRules(data:data(#"{"languages":{"xq":{"question_patterns":["(a+)+$"]}}}"#))
        XCTAssertFalse(try one.asks(text,lang:"xq"),"one copy fits the budget")
        let many = try ListingRules(data:["languages":.object(["xq":.object(["question_patterns":.array(Array(repeating:.string("(a+)+$"),count:1024))])])])
        XCTAssertThrowsError(try many.asks(text,lang:"xq")) { XCTAssertEqual($0 as? ListingRuleError, .regexBudgetExceeded) }
        let small = try ListingRules(data:data(#"{"languages":{"xq":{"question_patterns":["(a+)+$"]}}}"#), stepLimit:10)
        XCTAssertThrowsError(try small.asks(text,lang:"xq"),"the limit is the one given")
    }
    /// A slow machine writes the same sentences. The Spanish reference case
    /// lost its full stop on a loaded macOS runner under the old 100 ms
    /// deadline; here every reference case runs while the CPU is saturated.
    func testReferenceCasesDoNotDependOnMachineSpeed() throws {
        let stop = UnsafeAtomicFlag()
        let busy = (0..<max(2, ProcessInfo.processInfo.activeProcessorCount * 2)).map { _ in
            Thread { var x = 0.0; while !stop.isSet { x = (x + 1).squareRoot() } }
        }
        busy.forEach { $0.start() }
        defer { stop.set() }
        for row in try fixture("listing-vectors")["cases"]!.arrayValue!.compactMap(\.objectValue) where row["kind"]?.stringValue == "sentence" {
            XCTAssertEqual(JSONValue.string(asSentence(row["text"]!.stringValue!,lang:row["lang"]?.stringValue)),row["expected"],"\(row)")
        }
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

    func testMultiplePatternsShareOneEvaluationDeadline() throws {
        let patterns = Array(repeating: JSONValue.string("^a+$"), count: 1024)
        let rules = try ListingRules(data:["languages":.object(["xq":.object(["question_patterns":.array(patterns)])])])
        let text = String(repeating:"a",count:100_000)+"x"
        let start = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try rules.asks(text,lang:"xq"))
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000_000,1.5)
        XCTAssertEqual(rules.asSentence(text,lang:"xq"),"A"+text.dropFirst())
    }
}

/// A stop signal for the busy threads above, read and written under a lock.
private final class UnsafeAtomicFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
