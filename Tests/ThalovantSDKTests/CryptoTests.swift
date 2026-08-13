import Foundation
import XCTest

@testable import ThalovantSDK

final class CryptoTests: XCTestCase {
    private func hex(_ text: String) -> [UInt8] {
        ThalovantCrypto.hexDecode(text)!
    }

    // NIST GCM test case 1: empty plaintext, 12-byte IV.
    func testNistVectorEmptyPlaintext() {
        let sealed = AESGCM.seal(
            key: [UInt8](repeating: 0, count: 16),
            nonce: [UInt8](repeating: 0, count: 12),
            plaintext: []
        )
        XCTAssertEqual(sealed.ciphertext, [])
        XCTAssertEqual(ThalovantCrypto.hexEncode(sealed.tag), "58e2fccefa7e3061367f1d57a4e7455a")
    }

    // NIST GCM test case 2: one zero block, 12-byte IV.
    func testNistVectorSingleBlock() {
        let sealed = AESGCM.seal(
            key: [UInt8](repeating: 0, count: 16),
            nonce: [UInt8](repeating: 0, count: 12),
            plaintext: [UInt8](repeating: 0, count: 16)
        )
        XCTAssertEqual(ThalovantCrypto.hexEncode(sealed.ciphertext), "0388dace60b6a392f328c2b971b2fe78")
        XCTAssertEqual(ThalovantCrypto.hexEncode(sealed.tag), "ab6e47d42cec13bdf53a67b21257bddf")
    }

    /// Known-answer vector generated with Node.js `crypto`
    /// (`aes-128-gcm`, 16-byte nonce) — the exact configuration the Node SDK
    /// uses on the HiveMind wire. Proves cross-SDK interoperability.
    func testNodeSdkInteropVector() {
        let key = Array("0123456789abcdef".utf8)
        let nonce = hex("000102030405060708090a0b0c0d0e0f")
        let plaintext = Array(#"{"msg_type":"bus","payload":{"type":"speak"}}"#.utf8)
        let sealed = AESGCM.seal(key: key, nonce: nonce, plaintext: plaintext)
        XCTAssertEqual(
            ThalovantCrypto.hexEncode(sealed.ciphertext),
            "eecae278f07b4787d3b62d79b68abd4a8ff45bb2414001531bef052e4bc58e1878e780fe92d226f6597a3fda42"
        )
        XCTAssertEqual(ThalovantCrypto.hexEncode(sealed.tag), "9df782125f2077b8d91c96d9efecaff0")

        let opened = AESGCM.open(key: key, nonce: nonce, ciphertext: sealed.ciphertext, tag: sealed.tag)
        XCTAssertEqual(opened, plaintext)
    }

    func testTamperedTagFails() {
        let key = Array("0123456789abcdef".utf8)
        let nonce = hex("000102030405060708090a0b0c0d0e0f")
        let sealed = AESGCM.seal(key: key, nonce: nonce, plaintext: Array("hello".utf8))
        var badTag = sealed.tag
        badTag[0] ^= 0x01
        XCTAssertNil(AESGCM.open(key: key, nonce: nonce, ciphertext: sealed.ciphertext, tag: badTag))
        var badCiphertext = sealed.ciphertext
        badCiphertext[0] ^= 0x01
        XCTAssertNil(AESGCM.open(key: key, nonce: nonce, ciphertext: badCiphertext, tag: sealed.tag))
    }

    func testRuntimeKeyTruncatesToSixteenUtf8Characters() {
        XCTAssertEqual(
            ThalovantCrypto.runtimeKey("0123456789abcdefEXTRA-IGNORED"),
            Array("0123456789abcdef".utf8)
        )
        XCTAssertNil(ThalovantCrypto.runtimeKey(nil))
        XCTAssertNil(ThalovantCrypto.runtimeKey("   "))
    }

    func testEncryptDecryptJSONEnvelopeRoundTrip() throws {
        let key = "0123456789abcdefextra"
        let plaintext = #"{"msg_type":"hello","payload":{}}"#
        let envelopeText = try ThalovantCrypto.encryptJSON(key: key, plaintext: plaintext)
        let envelope = try ThalovantJSON.decodeObject(envelopeText)
        // Hex-encoded fields with a 16-byte nonce, like the Node SDK.
        let nonce = try XCTUnwrap(envelope["nonce"]?.stringValue)
        XCTAssertEqual(nonce.count, 32)
        XCTAssertTrue(ThalovantCrypto.isHexEncodedNonce(nonce))
        XCTAssertNotNil(envelope["ciphertext"]?.stringValue)
        XCTAssertEqual(envelope["tag"]?.stringValue?.count, 32)

        let decrypted = try ThalovantCrypto.decryptJSON(key: key, envelope: envelope)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testDecryptJSONDetectsBase64Encoding() throws {
        let key = "0123456789abcdef"
        let nonce = hex("000102030405060708090a0b0c0d0e0f")
        let plaintext = "base64 payload"
        let sealed = AESGCM.seal(key: Array(key.utf8), nonce: nonce, plaintext: Array(plaintext.utf8))
        let envelope: JSONObject = [
            "ciphertext": .string(Data(sealed.ciphertext).base64EncodedString()),
            "tag": .string(Data(sealed.tag).base64EncodedString()),
            "nonce": .string(Data(nonce).base64EncodedString()),
        ]
        XCTAssertEqual(try ThalovantCrypto.decryptJSON(key: key, envelope: envelope), plaintext)
    }

    func testDecryptWithWrongKeyThrows() throws {
        let envelopeText = try ThalovantCrypto.encryptJSON(key: "correct-key-1234", plaintext: "secret")
        let envelope = try ThalovantJSON.decodeObject(envelopeText)
        XCTAssertThrowsError(try ThalovantCrypto.decryptJSON(key: "incorrect-key-99", envelope: envelope))
    }
}
