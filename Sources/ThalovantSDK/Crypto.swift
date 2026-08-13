import Foundation

/// AES-128-GCM primitives compatible with the HiveMind runtime wire format.
///
/// The runtime key is the first 16 UTF-8 bytes of the identity `crypto_key`.
/// Encrypted JSON frames are `{"ciphertext": hex, "tag": hex, "nonce": hex}`
/// with a 16-byte random nonce, exactly like the Node and Go SDKs.
///
/// The implementation is pure Swift (NIST FIPS-197 AES + SP 800-38D GCM) so it
/// behaves identically on Apple platforms and Linux with zero dependencies.
public enum ThalovantCrypto {
    static let binaryNonceSize = 16
    static let authTagSize = 16

    /// First 16 characters of the crypto key, encoded as UTF-8 (mirrors the
    /// sibling SDKs). Returns `nil` for missing/blank keys.
    public static func runtimeKey(_ raw: String?) -> [UInt8]? {
        guard let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty else {
            return nil
        }
        return Array(String(normalized.prefix(16)).utf8)
    }

    /// Encrypts a plaintext into the JSON envelope used on WSS frames.
    public static func encryptJSON(key: String, plaintext: String) throws -> String {
        guard let runtimeKey = runtimeKey(key), runtimeKey.count == 16 else {
            throw ThalovantConnectionError("Missing or invalid crypto key.")
        }
        var nonce = [UInt8]()
        nonce.reserveCapacity(binaryNonceSize)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<binaryNonceSize {
            nonce.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        let sealed = AESGCM.seal(key: runtimeKey, nonce: nonce, plaintext: Array(plaintext.utf8))
        let envelope: JSONObject = [
            "ciphertext": .string(hexEncode(sealed.ciphertext)),
            "tag": .string(hexEncode(sealed.tag)),
            "nonce": .string(hexEncode(nonce)),
        ]
        return try ThalovantJSON.encodeToString(envelope)
    }

    /// Decrypts the JSON envelope used on WSS frames. Field values may be hex
    /// (the SDK default) or base64; the encoding is detected from the nonce.
    public static func decryptJSON(key: String, envelope: JSONObject) throws -> String {
        guard let runtimeKey = runtimeKey(key), runtimeKey.count == 16 else {
            throw ThalovantConnectionError("Missing or invalid crypto key.")
        }
        let nonceText = envelope["nonce"]?.stringValue ?? ""
        let tagText = envelope["tag"]?.stringValue ?? ""
        let ciphertextText = envelope["ciphertext"]?.stringValue ?? ""
        let useHex = isHexEncodedNonce(nonceText)
        guard
            let nonce = useHex ? hexDecode(nonceText) : base64Decode(nonceText),
            let tag = useHex ? hexDecode(tagText) : base64Decode(tagText),
            let ciphertext = useHex ? hexDecode(ciphertextText) : base64Decode(ciphertextText)
        else {
            throw ThalovantConnectionError("Invalid encrypted payload encoding.")
        }
        guard let plaintext = AESGCM.open(key: runtimeKey, nonce: nonce, ciphertext: ciphertext, tag: tag) else {
            throw ThalovantConnectionError("Failed to decrypt HiveMind payload (bad key or corrupt frame).")
        }
        guard let text = String(bytes: plaintext, encoding: .utf8) else {
            throw ThalovantConnectionError("Decrypted HiveMind payload is not valid UTF-8.")
        }
        return text
    }

    static func isHexEncodedNonce(_ value: String) -> Bool {
        guard !value.isEmpty, value.count % 2 == 0 else { return false }
        guard value.allSatisfy({ $0.isHexDigit }) else { return false }
        let byteCount = value.count / 2
        return byteCount == binaryNonceSize || byteCount == 12
    }

    static func hexEncode(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func hexDecode(_ text: String) -> [UInt8]? {
        guard text.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    static func base64Decode(_ text: String) -> [UInt8]? {
        guard let data = Data(base64Encoded: text) else { return nil }
        return Array(data)
    }
}

/// Minimal AES-128-GCM (encrypt-only AES core; GCM per NIST SP 800-38D,
/// supporting arbitrary nonce lengths including the 16-byte HiveMind nonce).
enum AESGCM {
    static func seal(key: [UInt8], nonce: [UInt8], plaintext: [UInt8]) -> (ciphertext: [UInt8], tag: [UInt8]) {
        let roundKeys = AES128.expandKey(key)
        let hashKey = AES128.encryptBlock([UInt8](repeating: 0, count: 16), roundKeys: roundKeys)
        let j0 = initialCounter(nonce: nonce, hashKey: hashKey)
        let ciphertext = counterModeCrypt(input: plaintext, roundKeys: roundKeys, initialCounter: increment32(j0))
        let tag = computeTag(hashKey: hashKey, j0: j0, ciphertext: ciphertext, roundKeys: roundKeys)
        return (ciphertext, tag)
    }

    static func open(key: [UInt8], nonce: [UInt8], ciphertext: [UInt8], tag: [UInt8]) -> [UInt8]? {
        guard tag.count == 16 else { return nil }
        let roundKeys = AES128.expandKey(key)
        let hashKey = AES128.encryptBlock([UInt8](repeating: 0, count: 16), roundKeys: roundKeys)
        let j0 = initialCounter(nonce: nonce, hashKey: hashKey)
        let expected = computeTag(hashKey: hashKey, j0: j0, ciphertext: ciphertext, roundKeys: roundKeys)
        var difference: UInt8 = 0
        for index in 0..<16 {
            difference |= expected[index] ^ tag[index]
        }
        guard difference == 0 else { return nil }
        return counterModeCrypt(input: ciphertext, roundKeys: roundKeys, initialCounter: increment32(j0))
    }

    private static func initialCounter(nonce: [UInt8], hashKey: [UInt8]) -> [UInt8] {
        if nonce.count == 12 {
            return nonce + [0, 0, 0, 1]
        }
        var ghashInput = nonce
        let padding = (16 - nonce.count % 16) % 16
        ghashInput += [UInt8](repeating: 0, count: padding)
        ghashInput += [UInt8](repeating: 0, count: 8)
        ghashInput += lengthBlock(bitCount: UInt64(nonce.count) * 8)
        return ghash(hashKey: hashKey, input: ghashInput)
    }

    private static func computeTag(hashKey: [UInt8], j0: [UInt8], ciphertext: [UInt8], roundKeys: [[UInt8]]) -> [UInt8] {
        // No additional authenticated data is used on this wire.
        var ghashInput = ciphertext
        let padding = (16 - ciphertext.count % 16) % 16
        ghashInput += [UInt8](repeating: 0, count: padding)
        ghashInput += lengthBlock(bitCount: 0)  // AAD length
        ghashInput += lengthBlock(bitCount: UInt64(ciphertext.count) * 8)
        let hash = ghash(hashKey: hashKey, input: ghashInput)
        let keystream = AES128.encryptBlock(j0, roundKeys: roundKeys)
        var tag = [UInt8](repeating: 0, count: 16)
        for index in 0..<16 {
            tag[index] = hash[index] ^ keystream[index]
        }
        return tag
    }

    private static func counterModeCrypt(input: [UInt8], roundKeys: [[UInt8]], initialCounter: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count)
        var counter = initialCounter
        var offset = 0
        while offset < input.count {
            let keystream = AES128.encryptBlock(counter, roundKeys: roundKeys)
            let chunk = min(16, input.count - offset)
            for index in 0..<chunk {
                output[offset + index] = input[offset + index] ^ keystream[index]
            }
            counter = increment32(counter)
            offset += chunk
        }
        return output
    }

    private static func increment32(_ block: [UInt8]) -> [UInt8] {
        var result = block
        var carry: UInt16 = 1
        for index in stride(from: 15, through: 12, by: -1) {
            let sum = UInt16(result[index]) + carry
            result[index] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }
        return result
    }

    private static func lengthBlock(bitCount: UInt64) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 8)
        for index in 0..<8 {
            block[7 - index] = UInt8((bitCount >> (UInt64(index) * 8)) & 0xFF)
        }
        return block
    }

    /// GHASH over GF(2^128) with the reduction polynomial from SP 800-38D.
    private static func ghash(hashKey: [UInt8], input: [UInt8]) -> [UInt8] {
        precondition(input.count % 16 == 0, "GHASH input must be block aligned")
        let (hHigh, hLow) = toWords(hashKey, offset: 0)
        var yHigh: UInt64 = 0
        var yLow: UInt64 = 0
        var offset = 0
        while offset < input.count {
            let (blockHigh, blockLow) = toWords(input, offset: offset)
            yHigh ^= blockHigh
            yLow ^= blockLow
            (yHigh, yLow) = gfMultiply(xHigh: yHigh, xLow: yLow, yHigh: hHigh, yLow: hLow)
            offset += 16
        }
        return fromWords(high: yHigh, low: yLow)
    }

    /// Bitwise GF(2^128) multiplication (X * Y) per SP 800-38D algorithm 1.
    private static func gfMultiply(xHigh: UInt64, xLow: UInt64, yHigh: UInt64, yLow: UInt64) -> (UInt64, UInt64) {
        var zHigh: UInt64 = 0
        var zLow: UInt64 = 0
        var vHigh = yHigh
        var vLow = yLow
        for bitIndex in 0..<128 {
            let bit: UInt64
            if bitIndex < 64 {
                bit = (xHigh >> (63 - UInt64(bitIndex))) & 1
            } else {
                bit = (xLow >> (63 - UInt64(bitIndex - 64))) & 1
            }
            if bit == 1 {
                zHigh ^= vHigh
                zLow ^= vLow
            }
            let lsb = vLow & 1
            vLow = (vLow >> 1) | (vHigh << 63)
            vHigh >>= 1
            if lsb == 1 {
                vHigh ^= 0xE100_0000_0000_0000
            }
        }
        return (zHigh, zLow)
    }

    private static func toWords(_ bytes: [UInt8], offset: Int) -> (UInt64, UInt64) {
        var high: UInt64 = 0
        var low: UInt64 = 0
        for index in 0..<8 {
            high = (high << 8) | UInt64(bytes[offset + index])
            low = (low << 8) | UInt64(bytes[offset + 8 + index])
        }
        return (high, low)
    }

    private static func fromWords(high: UInt64, low: UInt64) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8((high >> ((7 - UInt64(index)) * 8)) & 0xFF)
            bytes[8 + index] = UInt8((low >> ((7 - UInt64(index)) * 8)) & 0xFF)
        }
        return bytes
    }
}

/// AES-128 block encryption (FIPS-197). Only encryption is needed: GCM uses
/// the forward cipher for both sealing and opening.
enum AES128 {
    private static let sbox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]

    private static let roundConstants: [UInt8] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]

    /// Expands a 16-byte key into 11 round keys of 16 bytes each.
    static func expandKey(_ key: [UInt8]) -> [[UInt8]] {
        precondition(key.count == 16, "AES-128 requires a 16-byte key")
        var words: [[UInt8]] = (0..<4).map { Array(key[($0 * 4)..<($0 * 4 + 4)]) }
        for wordIndex in 4..<44 {
            var temp = words[wordIndex - 1]
            if wordIndex % 4 == 0 {
                temp = [temp[1], temp[2], temp[3], temp[0]].map { sbox[Int($0)] }
                temp[0] ^= roundConstants[wordIndex / 4 - 1]
            }
            words.append((0..<4).map { words[wordIndex - 4][$0] ^ temp[$0] })
        }
        return (0..<11).map { round in
            var roundKey = [UInt8]()
            roundKey.reserveCapacity(16)
            for wordIndex in 0..<4 {
                roundKey += words[round * 4 + wordIndex]
            }
            return roundKey
        }
    }

    static func encryptBlock(_ block: [UInt8], roundKeys: [[UInt8]]) -> [UInt8] {
        precondition(block.count == 16, "AES block must be 16 bytes")
        var state = block
        addRoundKey(&state, roundKeys[0])
        for round in 1..<10 {
            subBytes(&state)
            shiftRows(&state)
            mixColumns(&state)
            addRoundKey(&state, roundKeys[round])
        }
        subBytes(&state)
        shiftRows(&state)
        addRoundKey(&state, roundKeys[10])
        return state
    }

    private static func addRoundKey(_ state: inout [UInt8], _ roundKey: [UInt8]) {
        for index in 0..<16 {
            state[index] ^= roundKey[index]
        }
    }

    private static func subBytes(_ state: inout [UInt8]) {
        for index in 0..<16 {
            state[index] = sbox[Int(state[index])]
        }
    }

    /// State is column-major: byte index = 4 * column + row.
    private static func shiftRows(_ state: inout [UInt8]) {
        let input = state
        for row in 1..<4 {
            for column in 0..<4 {
                state[4 * column + row] = input[4 * ((column + row) % 4) + row]
            }
        }
    }

    private static func mixColumns(_ state: inout [UInt8]) {
        for column in 0..<4 {
            let a0 = state[4 * column]
            let a1 = state[4 * column + 1]
            let a2 = state[4 * column + 2]
            let a3 = state[4 * column + 3]
            state[4 * column] = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3
            state[4 * column + 1] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3
            state[4 * column + 2] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3)
            state[4 * column + 3] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3)
        }
    }

    private static func xtime(_ value: UInt8) -> UInt8 {
        (value << 1) ^ ((value & 0x80) != 0 ? 0x1B : 0x00)
    }
}
