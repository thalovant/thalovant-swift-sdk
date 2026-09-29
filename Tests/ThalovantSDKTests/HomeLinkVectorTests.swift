import Foundation
import XCTest

@testable import ThalovantSDK

/// The Home Assistant link on the data plane, against the vectors every SDK
/// shares (`home-link-vectors.json`, vendored and pinned by the parity
/// contract).
///
/// `reply_context` cases check the routing alone, and `speech` cases the plain
/// text. Every `answer` and `deadline` case runs through
/// `ThalovantClient.answerHomeRequest` -- the handler, its deadline, the
/// payload, and the reply sent over a transport -- and the transport must have
/// carried exactly the one `thalovant.home.response` the SDK returned, routed
/// back the way the request came; in a `deadline` case the transport takes
/// `send_ms` to put it on the wire, and a reply withdrawn at the hub's bound
/// never reaches it.
final class HomeLinkVectorTests: XCTestCase {

    func testHomeLinkVectors() async throws {
        let vectors = try loadVectors("home-link-vectors")
        let cases = try XCTUnwrap(vectors["cases"]?.arrayValue).compactMap(\.objectValue)
        XCTAssertEqual(cases.count, 35)
        for row in cases {
            let name = try XCTUnwrap(row["name"]?.stringValue)
            let produced: JSONValue
            switch row["kind"]?.stringValue {
            case "reply_context":
                produced = .object(replyContext(row["context"]?.objectValue))
            case "speech":
                produced = .string(plainSpeech(try XCTUnwrap(row["text"]?.stringValue, name)))
            case "queued":
                produced = try await queuedCase(row, name)
            case "deadline":
                let fake = LinkFake()
                fake.sendMilliseconds = try XCTUnwrap(row["send_ms"]?.intValue, name)
                let client = try fakeClient(fake)
                let event = ThalovantEvent(
                    name: HomeLink.requestMessageType,
                    data: try XCTUnwrap(row["request"]?.objectValue, name),
                    context: ["source": "skill"]
                )
                let hubTimeout = try XCTUnwrap(row["hub_timeout_ms"]?.doubleValue, name) / 1000
                let started = ProcessInfo.processInfo.systemUptime
                let sent = try await client.answerHomeRequest(
                    event,
                    timeout: try XCTUnwrap(row["timeout_ms"]?.doubleValue, name) / 1000,
                    hubTimeout: hubTimeout,
                    handler: handler(try XCTUnwrap(row["handler"]?.objectValue, name))
                )
                // Back soon after the hub's bound, whatever the handler or the
                // transport did. The slack is a busy CI runner's scheduling, not
                // the SDK's: a macOS runner woke 140 ms late once. That nothing
                // went out after the bound is checked below, not timed.
                XCTAssertLessThanOrEqual(ProcessInfo.processInfo.systemUptime - started, hubTimeout + 0.5, name)
                var outcome: JSONObject = ["replied": .bool(sent != nil)]
                if let sent {
                    XCTAssertEqual(fake.emitted.map(\.name), [HomeLink.responseMessageType], name)
                    XCTAssertEqual(fake.emitted.first?.data, sent, name)
                    outcome["response"] = .object(sent)
                } else {
                    // Withdrawn: give a send that was cut short the time it
                    // would have taken, and see that it never went out.
                    try await Task.sleep(nanoseconds: UInt64(fake.sendMilliseconds) * 1_000_000 + 50_000_000)
                    XCTAssertEqual(fake.emitted.count, 0, name)
                }
                produced = .object(outcome)
            default:
                let fake = LinkFake()
                let client = try fakeClient(fake)
                let event = ThalovantEvent(
                    name: HomeLink.requestMessageType,
                    data: try XCTUnwrap(row["request"]?.objectValue, name),
                    context: ["source": "skill"]
                )
                let answered = try await client.answerHomeRequest(
                    event,
                    timeout: row["timeout_ms"]?.doubleValue.map { $0 / 1000 } ?? HomeLink.handlerTimeout,
                    handler: handler(try XCTUnwrap(row["handler"]?.objectValue, name))
                )
                let payload = try XCTUnwrap(answered, name)
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

    /// A reply that waits behind another frame, over a real link to an
    /// in-memory hub: another frame holds the send path for `busy_ms`, then
    /// the same link must carry another message.
    private func queuedCase(_ row: JSONObject, _ name: String) async throws -> JSONValue {
        let hub = MemoryHub()
        let transport = try hub.transport(store: MemoryNoiseStore())
        let client = ThalovantClient(identity: transport.identity, transport: transport)
        try await client.connect(timeout: 10)
        defer { Task { await client.close() } }
        let socket = try XCTUnwrap(hub.lastSocket, name)
        let release = AsyncGate()
        socket.holdNextSend(release)
        // Another frame is being written ...
        let busy = Task { try await client.emit("another.frame") }
        try await eventually { socket.sendHeld }
        let written = Task {
            // ... for busy_ms.
            try await Task.sleep(nanoseconds: UInt64(try XCTUnwrap(row["busy_ms"]?.intValue, name)) * 1_000_000)
            release.open()
        }
        let event = ThalovantEvent(
            name: HomeLink.requestMessageType, data: try XCTUnwrap(row["request"]?.objectValue, name),
            context: ["source": "skill", "destination": "ha"])
        let sent = try await client.answerHomeRequest(
            event, hubTimeout: try XCTUnwrap(row["hub_timeout_ms"]?.doubleValue, name) / 1000,
            handler: handler(try XCTUnwrap(row["handler"]?.objectValue, name)))
        try await written.value
        try await busy.value
        // Time enough for a withdrawn reply to go out late, if it would.
        try await Task.sleep(nanoseconds: 200_000_000)
        let responses = hub.receivedMessages.filter { $0.type == HomeLink.responseMessageType }.map(\.data)
        XCTAssertEqual(responses, sent.map { [$0] } ?? [], "\(name): never sent late, never twice")
        // The same link carries the next message.
        try await client.emit("still.there")
        var kept = true
        do {
            try await eventually { hub.received.last == "still.there" }
        } catch {
            kept = false
        }
        kept = kept && hub.attempts == 1 && transport.connected && transport.lastError == nil
        var produced: JSONObject = ["replied": .bool(sent != nil), "link_kept": .bool(kept)]
        if let sent { produced["response"] = .object(sent) }
        return .object(produced)
    }

    /// The reference's `_handler`: raise, sleep, or answer what the case says.
    private func handler(_ spec: JSONObject) -> HomeHandler {
        { _ in
            if spec["raises"]?.boolValue == true {
                throw ThalovantRuntimeError("the conversation agent is gone")
            }
            if let milliseconds = spec["sleep_ms"]?.intValue {
                try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
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
        XCTAssertEqual(vectors["reply_timeout_ms"]?.intValue, Int(HomeLink.hubTimeout * 1000))
        XCTAssertEqual(HomeLink.handlerTimeout, HomeLink.hubTimeout - 1)
    }

    func testAHandlerThatIgnoresCancellationIsStillAnsweredInTime() async throws {
        let fake = LinkFake()
        let client = try fakeClient(fake)
        let event = ThalovantEvent(
            name: HomeLink.requestMessageType, data: ["request_id": "r1", "utterance": "open the gate"])
        let started = ProcessInfo.processInfo.systemUptime
        let payload = try await client.answerHomeRequest(event, timeout: 0.1, hubTimeout: 1) { _ in
            // Deaf to cancellation: a task group would wait the whole two seconds.
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { resume.resume() }
            }
            return HomeAnswer(speech: "too late")
        }
        // Far less than the two seconds the handler holds on; the margin is for
        // a busy runner.
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.0)
        XCTAssertEqual(payload?["error_code"], .string("timeout"))
        XCTAssertEqual(payload?["speech"], .string(""))
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
        // Only real markup goes: a "<" not before a letter is text.
        XCTAssertEqual(plainSpeech("5 < 6 and 7 > 3"), "5 < 6 and 7 > 3")
        XCTAssertEqual(plainSpeech("a < b"), "a < b")
        XCTAssertEqual(plainSpeech("<br/>x<br />y<P CLASS='a'>z</P>"), "xyz")
        XCTAssertEqual(plainSpeech("<!-- one\ntwo -->ok<?pi x?>"), "ok")
        XCTAssertEqual(plainSpeech("<unclosed & open"), "<unclosed & open")
        // The portable references, and no others.
        XCTAssertEqual(plainSpeech("&lt;speak&gt; is &quot;SSML&quot; &amp; more"), "<speak> is \"SSML\" & more")
        XCTAssertEqual(plainSpeech("caf&#233; &#xE9;t&#XE9; &eacute;"), "café été &eacute;")
        XCTAssertEqual(plainSpeech("&AMP; &Amp; &#12345678; &#x1234567;"), "&AMP; &Amp; &#12345678; &#x1234567;")
        XCTAssertEqual(plainSpeech("&#00065;&#x0041;"), "AA")
        // Unicode White_Space, and nothing else.
        XCTAssertEqual(plainSpeech("line\u{2028}break\u{85}next\u{3000}end"), "line break next end")
        XCTAssertEqual(plainSpeech("zero\u{200B}width"), "zero\u{200B}width")
        XCTAssertEqual(stripSsml("<speak>Hello</speak>"), "Hello")
    }

    func testMarkupRemovalIsLinear() {
        let pathological: [String: String] = [
            "an unclosed tag and spaces": "<b" + String(repeating: " ", count: 50_000),
            "an unclosed tag and nested quotes": "<b " + String(repeating: "\"'", count: 25_000),
            "quoted greater-than signs": String(repeating: "<a \">\"", count: 10_000),
            "quotes that never close": String(repeating: "<a '", count: 20_000),
            "comments that never close": String(repeating: "<!--", count: 20_000),
            "instructions that never close": String(repeating: "<?", count: 30_000),
            "tags that never close": String(repeating: "<b <i <u ", count: 10_000),
            "nothing but less-than signs": String(repeating: "<", count: 60_000),
            "closing tags that never close": String(repeating: "</a", count: 20_000),
        ]
        for (name, text) in pathological {
            let started = ProcessInfo.processInfo.systemUptime
            _ = stripSsml(text)
            _ = plainSpeech(text)
            // A few tens of milliseconds; a backtracking pattern took minutes.
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2, name)
        }
    }

    func testMarkupRemovalIsTheDocumentedRule() throws {
        // The rule as a regular expression: fine as a reference on short text,
        // where backtracking costs nothing.
        let rule = try NSRegularExpression(
            pattern: #"<!--.*?-->|<\?.*?\?>|</?[A-Za-z](?:[^>"']|"[^"]*"|'[^']*')*>"#,
            options: [.dotMatchesLineSeparators])
        let alphabet = Array("<>/!?-\"' ab=")
        var seed: UInt64 = 20_260_928
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        for _ in 0..<20_000 {
            let text = String((0..<next(15)).map { _ in alphabet[next(alphabet.count)] })
            let expected = rule.stringByReplacingMatches(
                in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
            XCTAssertEqual(stripSsml(text), expected, text)
        }
        XCTAssertEqual(stripSsml("<a,b>c"), "c", "the rule, which the old pattern did not quite follow")
        XCTAssertEqual(stripSsml("<a  / >x<a/>y<a />z"), "xyz")
    }

    func testSpeechTrimsWhiteSpaceOnly() {
        // U+001C..U+001F are separators to some trims, but not White_Space.
        XCTAssertEqual(plainSpeech("\u{1C} Hi \u{1F}"), "\u{1C} Hi \u{1F}")
        XCTAssertEqual(plainSpeech(" \u{3000} Hi  "), "Hi")
    }

    func testAWithdrawnReplyNeitherGoesOutNorTearsTheLinkDown() async throws {
        let hub = MemoryHub()
        let transport = try hub.transport(store: MemoryNoiseStore())
        let client = ThalovantClient(identity: transport.identity, transport: transport)
        try await client.connect(timeout: 10)
        let socket = try XCTUnwrap(hub.lastSocket)
        let release = AsyncGate()
        socket.holdNextSend(release)
        // A frame already being written: it is finished.
        let first = Task { try await client.emit("first.frame") }
        try await eventually { socket.sendHeld }
        // A reply queued behind it, withdrawn at the hub's bound.
        let event = ThalovantEvent(
            name: HomeLink.requestMessageType, data: ["request_id": "q1"], context: ["source": "skill"])
        let sent = try await client.answerHomeRequest(event, timeout: 0.05, hubTimeout: 0.2) { _ in
            HomeAnswer(speech: "Done.")
        }
        XCTAssertNil(sent)
        release.open()
        try await first.value
        // The link is as it was: the next frame goes out, the withdrawn one never did.
        try await client.emit("after.frame")
        try await eventually { hub.received == ["first.frame", "after.frame"] }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(hub.received, ["first.frame", "after.frame"])
        XCTAssertTrue(transport.connected && transport.handshakeComplete)
        XCTAssertNil(transport.lastError)
        await client.close()
    }

    func testReplyingNeedsAType() async throws {
        let client = try fakeClient(LinkFake())
        do {
            try await client.reply(to: ThalovantEvent(name: "x"), type: "  ")
            XCTFail("expected a refusal")
        } catch is ThalovantRuntimeError {}
    }

    func testAReplyThatCannotBeSentInTimeIsWithdrawn() async throws {
        let fake = LinkFake()
        fake.sendMilliseconds = 500
        let client = try fakeClient(fake)
        let event = ThalovantEvent(name: HomeLink.requestMessageType, data: ["request_id": "w1"])
        let sent = try await client.answerHomeRequest(event, timeout: 0.05, hubTimeout: 0.2) { _ in
            HomeAnswer(speech: "Done.")
        }
        XCTAssertNil(sent)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(fake.emitted.count, 0, "a withdrawn reply never goes out")
    }

    func testAWithdrawnReplyDoesNotWaitForASendThatIgnoresCancellation() async throws {
        let replier = StubbornReplier()
        let event = ThalovantEvent(name: HomeLink.requestMessageType, data: ["request_id": "w2"])
        let started = ProcessInfo.processInfo.systemUptime
        let sent = try await replier.answerHomeRequest(event, timeout: 0.05, hubTimeout: 0.3) { _ in
            HomeAnswer(speech: "Done.")
        }
        let took = ProcessInfo.processInfo.systemUptime - started
        XCTAssertNil(sent, "not sent within the bound")
        // The send holds on for two seconds whatever happens; the answer came
        // back at the bound instead of waiting for it.
        XCTAssertLessThan(took, 1.0)
        XCTAssertGreaterThanOrEqual(took, 0.29)
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

/// A transport whose send takes two seconds and ignores being cancelled, as a
/// frame already being written does.
private final class StubbornReplier: ThalovantReplying, @unchecked Sendable {
    func reply(to event: ThalovantEvent, type: String, data: JSONObject, context: JSONObject) async throws {
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { resume.resume() }
        }
    }
}
