import XCTest
import CThalovantNoise

final class CModuleTests: XCTestCase {
    func testUmbrellaExposesAES256GCMWithNISTVector() {
        // NIST SP 800-38D AES256 zero key/IV and one zero plaintext block,
        // also exercised by thalovant-embedded-c/tests/test_noise.c.
        let key = [UInt8](repeating: 0, count: 32)
        let nonce = [UInt8](repeating: 0, count: 12)
        let plain = [UInt8](repeating: 0, count: 16)
        var ciphertext = [UInt8](repeating: 0, count: 16)
        var tag = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(thalovant_aes256_gcm_encrypt(key, nonce, nonce.count, nil, 0,
                                                  plain, plain.count, &ciphertext, &tag), 0)
        XCTAssertEqual(ciphertext, [0xce, 0xa7, 0x40, 0x3d, 0x4d, 0x60, 0x6b, 0x6e,
                                    0x07, 0x4e, 0xc5, 0xd3, 0xba, 0xf3, 0x9d, 0x18])
        XCTAssertEqual(tag, [0xd0, 0xd1, 0xc8, 0xa7, 0x99, 0x99, 0x6b, 0xf0,
                            0x26, 0x5b, 0x98, 0xb5, 0xd4, 0x8a, 0xb9, 0x19])
    }
}
