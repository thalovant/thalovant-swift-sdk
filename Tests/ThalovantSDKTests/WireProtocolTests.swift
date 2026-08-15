import Foundation
import XCTest

@testable import ThalovantSDK

/// Unit tests for the pure encode/decode half of the WSS wire protocol.
/// (Exercising the socket itself needs a live hub, so it is out of scope.)
final class WireProtocolTests: XCTestCase {
    func testAuthorizationIsBase64UserAgentColonAccessKey() {
        let token = HiveWire.authorization(userAgent: "ThalovantSwiftSDK/0.1.3", accessKey: "access-1")
        XCTAssertEqual(token, Data("ThalovantSwiftSDK/0.1.3:access-1".utf8).base64EncodedString())
    }

    func testAuthorizedEndpointAppendsQueryParameter() throws {
        let url = try HiveWire.authorizedEndpoint("wss://hub.example.com/ws", authorization: "abc+d=")
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "hub.example.com")
        XCTAssertEqual(url.path, "/ws")
        XCTAssertTrue(url.query?.contains("authorization=") ?? false)
    }

    func testAuthorizedEndpointReplacesExistingAuthorization() throws {
        let url = try HiveWire.authorizedEndpoint(
            "wss://hub.example.com/ws?authorization=old&keep=1",
            authorization: "new"
        )
        let query = url.query ?? ""
        XCTAssertTrue(query.contains("authorization=new"))
        XCTAssertFalse(query.contains("authorization=old"))
        XCTAssertTrue(query.contains("keep=1"))
    }

    func testAuthorizedEndpointRejectsNonWebSocketSchemes() {
        XCTAssertThrowsError(try HiveWire.authorizedEndpoint("https://hub.example.com", authorization: "x")) { error in
            XCTAssertTrue(error is ThalovantConnectionError)
        }
    }

    func testHelloMessageShape() throws {
        let hello = HiveWire.helloMessage(siteId: "site-1", publicKey: nil, sessionId: "thalovant-swift-abc")
        let text = try HiveWire.encode(hello)
        let object = try ThalovantJSON.decodeObject(text)
        XCTAssertEqual(object["msg_type"]?.stringValue, "hello")
        XCTAssertEqual(object["payload"]?["pubkey"]?.stringValue, "")
        XCTAssertEqual(object["payload"]?["site_id"]?.stringValue, "site-1")
        XCTAssertEqual(object["payload"]?["session"]?["session_id"]?.stringValue, "thalovant-swift-abc")
        // Every frame carries the full HiveMind field set, with explicit nulls.
        XCTAssertEqual(object["metadata"], .object([:]))
        XCTAssertEqual(object["route"], .array([]))
        for key in ["node", "target_site_id", "target_pubkey", "source_peer"] {
            XCTAssertEqual(object[key], .null, "expected explicit null for \(key)")
        }
    }

    func testBusMessageShape() throws {
        let message = HiveWire.busMessage(
            type: ThalovantEvents.recognizerLoopUtterance,
            data: utterancePayload(text: "hello hub", lang: "en-us"),
            context: contextWithCorrelation([:], sessionId: "s-1", siteId: "site-1", lang: "en-us", requestId: "r-1")
        )
        let object = try ThalovantJSON.decodeObject(try HiveWire.encode(message))
        XCTAssertEqual(object["msg_type"]?.stringValue, "bus")
        let payload = try XCTUnwrap(object["payload"]?.objectValue)
        XCTAssertEqual(payload["type"]?.stringValue, "recognizer_loop:utterance")
        XCTAssertEqual(payload["data"]?["utterances"], .array([.string("hello hub")]))
        XCTAssertEqual(payload["data"]?["lang"]?.stringValue, "en-us")
        let context = try XCTUnwrap(payload["context"]?.objectValue)
        XCTAssertEqual(context["request_id"]?.stringValue, "r-1")
        XCTAssertEqual(context["thalovant_request_id"]?.stringValue, "r-1")
        XCTAssertEqual(context["session"]?["session_id"]?.stringValue, "s-1")
        XCTAssertEqual(context["session"]?["site_id"]?.stringValue, "site-1")
        XCTAssertEqual(context["session"]?["request_id"]?.stringValue, "r-1")
        XCTAssertEqual(context["session"]?["lang"]?.stringValue, "en-us")
    }

    func testDecodePlaintextFrame() throws {
        let text = """
        {"msg_type": "handshake", "payload": {"preshared_key": true}, "route": [], "node": null}
        """
        let message = try HiveWire.decode(text: text)
        XCTAssertEqual(message.msgType, "handshake")
        XCTAssertEqual(message.payload["preshared_key"]?.boolValue, true)
        XCTAssertNil(message.node)
    }

    func testEncryptedFrameRoundTrip() throws {
        let key = "0123456789abcdefextra"
        let original = HiveWire.busMessage(
            type: "speak",
            data: ["utterance": "hi"],
            context: ["session": .object(["session_id": "s-1"])]
        )
        let wireText = try HiveWire.encode(original, cryptoKey: key, encrypt: true)
        // The frame on the wire is an encrypted envelope, not plaintext JSON.
        let envelope = try ThalovantJSON.decodeObject(wireText)
        XCTAssertNotNil(envelope["ciphertext"])
        XCTAssertNotNil(envelope["tag"])
        XCTAssertNotNil(envelope["nonce"])
        XCTAssertNil(envelope["msg_type"])

        let decoded = try HiveWire.decode(text: wireText, cryptoKey: key)
        XCTAssertEqual(decoded, original)
    }

    func testEncodeWithoutKeyStaysPlaintext() throws {
        let message = HiveWire.busMessage(type: "speak", data: [:], context: [:])
        let text = try HiveWire.encode(message, cryptoKey: nil, encrypt: true)
        XCTAssertEqual(try ThalovantJSON.decodeObject(text)["msg_type"]?.stringValue, "bus")
    }

    func testDecodeBinaryFrame() throws {
        let text = #"{"msg_type": "bus", "payload": {"type": "speak", "data": {"utterance": "hi"}}}"#
        let message = try HiveWire.decode(data: Data(text.utf8))
        XCTAssertEqual(message.msgType, "bus")
        XCTAssertEqual(message.payload["type"]?.stringValue, "speak")
    }

    func testPresharedKeyHandshakeDetection() {
        XCTAssertTrue(HiveWire.isPresharedKeyHandshake(["preshared_key": true]))
        XCTAssertTrue(HiveWire.isPresharedKeyHandshake(["preshared_key": "salt"]))
        XCTAssertFalse(HiveWire.isPresharedKeyHandshake([:]))
        XCTAssertFalse(HiveWire.isPresharedKeyHandshake(["preshared_key": false]))
        XCTAssertFalse(HiveWire.isPresharedKeyHandshake(["preshared_key": .null]))
        XCTAssertFalse(HiveWire.isPresharedKeyHandshake(["preshared_key": true, "handshake": .object([:])]))
        XCTAssertFalse(HiveWire.isPresharedKeyHandshake(["preshared_key": true, "envelope": "x"]))
    }

    func testHiveMessageDecodingToleratesMissingOptionalFields() throws {
        let message = try HiveWire.decode(text: #"{"msg_type": "bus", "payload": {}}"#)
        XCTAssertEqual(message.metadata, [:])
        XCTAssertEqual(message.route, [])
        XCTAssertNil(message.targetSiteId)
    }
}

/// Unit tests for the ask() reply-aggregation state machine: request-id
/// correlation, fragment dedupe, handled/failure transitions.
final class AskCorrelationTests: XCTestCase {
    private func speak(_ text: String, requestId: String?) -> ThalovantEvent {
        var context: JSONObject = [:]
        if let requestId {
            context = contextWithCorrelation([:], requestId: requestId)
        }
        return ThalovantEvent(name: ThalovantEvents.speak, data: ["utterance": .string(text)], context: context)
    }

    func testIgnoresEventsWithOtherOrMissingRequestIds() {
        let state = AskState()
        state.process(speak("wrong", requestId: "other"), requestId: "r-1")
        state.process(speak("uncorrelated", requestId: nil), requestId: "r-1")
        XCTAssertTrue(state.snapshot().fragments.isEmpty)
        XCTAssertFalse(state.progressGate.isOpen)
    }

    func testCollectsAndDedupesFragments() {
        let state = AskState()
        state.process(speak("Hello   there", requestId: "r-1"), requestId: "r-1")
        state.process(speak("Hello there", requestId: "r-1"), requestId: "r-1")
        state.process(speak("Second line", requestId: "r-1"), requestId: "r-1")
        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.fragments, ["Hello there", "Second line"])
        XCTAssertTrue(state.progressGate.isOpen)
        XCTAssertTrue(state.replyGate.isOpen)
        XCTAssertNil(snapshot.failureEvent)
    }

    func testHandledEventOpensProgressWithoutFragments() {
        let state = AskState()
        let handled = ThalovantEvent(
            name: ThalovantEvents.utteranceHandled,
            data: [:],
            context: contextWithCorrelation([:], requestId: "r-1")
        )
        state.process(handled, requestId: "r-1")
        let snapshot = state.snapshot()
        XCTAssertTrue(snapshot.handled)
        XCTAssertTrue(state.progressGate.isOpen)
        XCTAssertFalse(state.replyGate.isOpen)
        XCTAssertTrue(snapshot.fragments.isEmpty)
    }

    func testPolicyDeniedBecomesFailure() {
        let state = AskState()
        let denied = ThalovantEvent(
            name: ThalovantEvents.policyDenied,
            data: ["utterance": "Denied by policy."],
            context: contextWithCorrelation([:], requestId: "r-1")
        )
        state.process(denied, requestId: "r-1")
        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.failureEvent?.name, "hive.policy.denied")
        XCTAssertTrue(state.progressGate.isOpen)
    }

    func testRequestIdFallsBackToSessionAndData() {
        let inContext = ThalovantEvent(name: "speak", data: [:], context: ["request_id": "r-1"])
        XCTAssertEqual(inContext.requestId, "r-1")
        let inSession = ThalovantEvent(name: "speak", data: [:], context: ["session": .object(["request_id": "r-2"])])
        XCTAssertEqual(inSession.requestId, "r-2")
        let inData = ThalovantEvent(name: "speak", data: ["request_id": "r-3"], context: [:])
        XCTAssertEqual(inData.requestId, "r-3")
        let correlation = ThalovantEvent(name: "speak", data: [:], context: ["correlation_id": "r-4"])
        XCTAssertEqual(correlation.requestId, "r-4")
    }

    func testEventTextAndUtterances() {
        let event = ThalovantEvent(
            name: "speak",
            data: ["utterance": "<speak>Hello</speak>", "utterances": .array(["<speak>Hello</speak>"])]
        )
        XCTAssertEqual(event.text, "<speak>Hello</speak>")
        XCTAssertEqual(event.displayText, "Hello")
        XCTAssertEqual(event.utterances, ["<speak>Hello</speak>"])
        XCTAssertTrue(
            ThalovantEvent(name: ThalovantEvents.intentFailure).isFailure
        )
        XCTAssertFalse(ThalovantEvent(name: "speak").isFailure)
    }

    func testClientRejectsNonWssProtocols() throws {
        let identity = try ThalovantIdentity(json: try ThalovantJSON.decodeObject(Fixtures.clientIdentify))
        XCTAssertThrowsError(try ThalovantClient(identity: identity, hubProtocol: .mqtt)) { error in
            XCTAssertTrue(error is ThalovantUnsupportedProtocolError)
        }
        XCTAssertThrowsError(try ThalovantClient(identity: identity, hubProtocol: .https)) { error in
            XCTAssertTrue(error is ThalovantUnsupportedProtocolError)
        }
    }

    func testClientRequiresWssEndpoint() throws {
        // https default_master only, no wss endpoint anywhere.
        let identity = try ThalovantIdentity(json: [
            "access_key": "k", "password": "p", "site_id": "s",
            "default_master": "https://hub.example.com",
        ])
        XCTAssertThrowsError(try ThalovantClient(identity: identity)) { error in
            XCTAssertTrue(error is ThalovantUnsupportedProtocolError)
        }
    }

    func testTransportEndpointURLCarriesAuthorization() throws {
        let identity = try ThalovantIdentity(json: [
            "access_key": "access-1", "password": "p", "site_id": "s",
            "default_master": "https://hub.example.com",
            "data_plane_endpoints": .object(["wss": "wss://hub.example.com/ws"]),
        ])
        let transport = HiveMindWSSTransport(identity: identity, userAgent: "ThalovantSwiftSDK/0.1.3")
        let url = try transport.endpointURL()
        XCTAssertEqual(url.host, "hub.example.com")
        XCTAssertEqual(url.path, "/ws")
        // The decoded query value must be the exact base64 credential.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let value = components?.queryItems?.first { $0.name == "authorization" }?.value
        XCTAssertEqual(value, Data("ThalovantSwiftSDK/0.1.3:access-1".utf8).base64EncodedString())
    }
}
