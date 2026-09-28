import Foundation
import XCTest

@testable import ThalovantSDK

/// The Home Assistant link on the data plane, against the vectors every SDK
/// shares (`home-link-vectors.json`, vendored and pinned by the parity
/// contract).
///
/// `reply_context` cases check the routing alone. Every `answer` case runs
/// through `ThalovantClient.answerHomeRequest` -- the handler, its deadline,
/// the payload, and the reply sent over a transport -- and the transport must
/// have carried exactly the one `thalovant.home.response` the SDK returned,
/// routed back the way the request came.
final class HomeLinkVectorTests: XCTestCase {

    func testHomeLinkVectors() async throws {
        let vectors = try loadVectors("home-link-vectors")
        let cases = try XCTUnwrap(vectors["cases"]?.arrayValue).compactMap(\.objectValue)
        XCTAssertEqual(cases.count, 11)
        for row in cases {
            let name = try XCTUnwrap(row["name"]?.stringValue)
            let produced: JSONValue
            if row["kind"]?.stringValue == "reply_context" {
                produced = .object(replyContext(row["context"]?.objectValue))
            } else {
                let fake = LinkFake()
                let client = try fakeClient(fake)
                let event = ThalovantEvent(
                    name: HomeLink.requestMessageType,
                    data: try XCTUnwrap(row["request"]?.objectValue, name),
                    context: ["source": "skill"]
                )
                let payload = try await client.answerHomeRequest(
                    event,
                    timeout: row["timeout_seconds"]?.doubleValue ?? HomeLink.handlerTimeout,
                    handler: handler(try XCTUnwrap(row["handler"]?.objectValue, name))
                )
                produced = .object(payload)
                let sent = fake.emitted
                XCTAssertEqual(sent.map(\.name), [HomeLink.responseMessageType], name)
                XCTAssertEqual(sent.first?.data, payload, name)
                XCTAssertEqual(sent.first?.context, replyContext(event.context), name)
                XCTAssertEqual(sent.first?.context["destination"], "skill", name)
            }
            ConformanceRecord.record("home-link-vectors.json", name, produced)
            XCTAssertEqual(produced, row["expect"], name)
        }
    }

    /// The reference's `_handler`: raise, sleep, or answer what the case says.
    private func handler(_ spec: JSONObject) -> HomeHandler {
        { _ in
            if spec["raises"]?.boolValue == true {
                throw ThalovantRuntimeError("the conversation agent is gone")
            }
            if let seconds = spec["sleep_seconds"]?.doubleValue {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            return HomeAnswer(
                speech: spec["speech"]?.stringValue ?? "",
                responseType: HomeResponseType(rawValue: spec["response_type"]?.stringValue ?? "action_done"),
                errorCode: spec["error_code"]?.stringValue.map(HomeErrorCode.init(rawValue:)),
                continueConversation: spec["continue_conversation"]?.boolValue ?? false
            )
        }
    }

    func testTheContractListsMatchTheSDK() throws {
        let vectors = try loadVectors("home-link-vectors")
        XCTAssertEqual(.array(HomeResponseType.all.map { .string($0.rawValue) }), vectors["response_types"])
        XCTAssertEqual(.array(HomeErrorCode.all.map { .string($0.rawValue) }), vectors["error_codes"])
        XCTAssertEqual(.string(HomeLink.requestMessageType), vectors["request_type"])
        XCTAssertEqual(.string(HomeLink.responseMessageType), vectors["response_type"])
        XCTAssertEqual(vectors["reply_timeout_seconds"]?.doubleValue, HomeLink.hubTimeout)
        XCTAssertEqual(HomeLink.handlerTimeout, HomeLink.hubTimeout - 1)
    }

    func testAHandlerThatIgnoresCancellationIsStillAnsweredInTime() async throws {
        let fake = LinkFake()
        let client = try fakeClient(fake)
        let event = ThalovantEvent(
            name: HomeLink.requestMessageType, data: ["request_id": "r1", "utterance": "open the gate"])
        let started = ProcessInfo.processInfo.systemUptime
        let payload = try await client.answerHomeRequest(event, timeout: 0.1) { _ in
            // Deaf to cancellation: a task group would wait the whole two seconds.
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { resume.resume() }
            }
            return HomeAnswer(speech: "too late")
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
        XCTAssertEqual(payload["error_code"], .string("timeout"))
        XCTAssertEqual(payload["speech"], .string(""))
        XCTAssertEqual(fake.emitted.count, 1)
    }

    func testCancellingTheAnswerSendsNothing() async throws {
        let fake = LinkFake()
        let client = try fakeClient(fake)
        let entered = AsyncGate()
        let event = ThalovantEvent(name: HomeLink.requestMessageType, data: ["request_id": "r1"])
        let answering = Task {
            try await client.answerHomeRequest(event) { _ in
                entered.open()
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return HomeAnswer(speech: "never")
            }
        }
        try await entered.wait(timeout: 2, timeoutError: ThalovantTimeoutError("handler never ran"))
        answering.cancel()
        do {
            _ = try await answering.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(fake.emitted.count, 0)
    }

    func testAnAnswersOwnConversationWinsAndAnEmptyOneEchoes() {
        let request = HomeRequest(event: ThalovantEvent(
            name: HomeLink.requestMessageType,
            data: ["request_id": "r1", "utterance": "and the hall?", "conversation_id": "conv-1", "lang": "en-US"]))
        XCTAssertEqual(request.lang, "en-US")
        XCTAssertEqual(homeResponse(to: request, answer: HomeAnswer(conversationId: "conv-2"))["conversation_id"], "conv-2")
        XCTAssertEqual(homeResponse(to: request, answer: HomeAnswer(conversationId: ""))["conversation_id"], "conv-1")
        // An error code is only ever sent with an error.
        XCTAssertNil(homeResponse(to: request, answer: HomeAnswer(errorCode: .timeout))["error_code"])
        XCTAssertEqual(homeResponse(to: request, answer: .error(.agentUnavailable))["error_code"], "agent_unavailable")
        XCTAssertEqual(
            homeResponse(to: request, answer: HomeAnswer(responseType: .error))["error_code"], "unknown",
            "an error with no code is outside the contract")
    }

    func testSpeechIsPlainText() {
        XCTAssertEqual(plainSpeech(nil), "")
        XCTAssertEqual(plainSpeech("  <b>Bold</b>\tand\r\n<i>italic</i>  "), "Bold and italic")
        XCTAssertEqual(plainSpeech("5 < 6 and 7 > 3"), "5 3", "the reference's pattern takes `< 6 and 7 >` for a tag")
        XCTAssertEqual(plainSpeech("a < b"), "a < b", "a `<` that never closes is not markup")
        XCTAssertEqual(plainSpeech("&lt;speak&gt; is &quot;SSML&quot; &amp; more"), "<speak> is \"SSML\" & more")
        XCTAssertEqual(plainSpeech("caf&#233; &#xE9;t&eacute; &#65"), "café été A")
        XCTAssertEqual(plainSpeech("&Eacute;&szlig;&Omega;&rarr;&spades;"), "Éß\u{3A9}→♠")
        XCTAssertEqual(plainSpeech("&#128; &#0; &#xD800; &#1;x"), "€ \u{FFFD} \u{FFFD} x")
        XCTAssertEqual(plainSpeech("it costs 5&nbsp;&euro;&mdash;cheap&hellip;"), "it costs 5 €—cheap…")
        XCTAssertEqual(plainSpeech("&unknown; & &;"), "&unknown; & &;")
        // Unterminated and run-on names, as html.unescape reads them.
        for (text, python) in [
            ("fish &amp chips &copy2026", "fish & chips ©2026"), ("&ampx", "&x"), ("&notit;", "¬it;"),
            ("&notin;", "∉"), ("a&lt3", "a<3"), ("&AMP;", "&"), ("&amp;&amp", "&&"), ("&ampamp;", "&amp;"),
            ("Il fait 21&#160;&deg;C &agrave; Paris", "Il fait 21 °C à Paris"), ("&#x80; and &#xD800;", "€ and \u{FFFD}"),
            ("&#0000000000000065;", "A"), ("&#99999999999;", "\u{FFFD}"), ("&#x81;", "\u{81}"),
        ] {
            XCTAssertEqual(plainSpeech(text), python, text)
        }
        XCTAssertEqual(plainSpeech("line\u{2028}break\u{1C}sep"), "line break sep")
    }

    func testReplyingNeedsAType() async throws {
        let client = try fakeClient(LinkFake())
        do {
            try await client.reply(to: ThalovantEvent(name: "x"), type: "  ")
            XCTFail("expected a refusal")
        } catch is ThalovantRuntimeError {}
    }

    func testAReplyLaysItsContextOverTheRequestsBeforeTheSwap() async throws {
        let fake = LinkFake()
        let client = try fakeClient(fake)
        let event = ThalovantEvent(
            name: "mycroft.volume.get",
            context: ["source": "skill", "destination": ["peer-1", "peer-2"], "session": ["session_id": "s1"]])
        try await client.reply(to: event, type: "mycroft.volume.get.response", data: ["percent": 40],
                               context: ["source": "audio"])
        let sent = try XCTUnwrap(fake.emitted.first)
        XCTAssertEqual(sent.name, "mycroft.volume.get.response")
        XCTAssertEqual(sent.data, ["percent": 40])
        XCTAssertEqual(sent.context["destination"], "audio")
        XCTAssertEqual(sent.context["source"], "peer-1")
        XCTAssertEqual(sent.context["session"], ["session_id": "s1"])
    }

    func testTheRecorderSpellsAVectorsFractionsAsTheReferenceDoes() {
        for (value, python) in [
            (0.2, "0.2"), (0.01, "0.01"), (0.05, "0.05"), (0.02, "0.02"), (123.456, "123.456"), (-0.5, "-0.5"),
            (0.0001, "0.0001"), (0.00001, "1e-05"), (1.5e-7, "1.5e-07"), (2.5e-300, "2.5e-300"),
            (1234567890123.5, "1234567890123.5"),
        ] {
            XCTAssertEqual(ConformanceRecord.pythonRepr(value), python)
        }
        XCTAssertEqual(ConformanceRecord.canonical(["t": .number(0.2), "n": .number(5)], fractions: true), #"{"n":5,"t":0.2}"#)
    }
}
