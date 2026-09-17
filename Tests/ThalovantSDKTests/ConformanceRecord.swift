import CThalovantNoise
import Foundation
import XCTest

@testable import ThalovantSDK

/// Record what this SDK produced for each conformance case.
///
/// The parity gate can check that a test *names* a vector file. It cannot
/// check that the test ran it: a name reaching a loader call is evidence of
/// intent, not of execution. So the gate stopped asking about the test and
/// started asking about its output -- this writes what we computed, and the
/// checker compares it against what the Python reference computed for the same
/// case.
///
/// The digest has to agree across languages, so it is deliberately the same
/// recipe as the reference's `tests/conformance_record.py`: JSON with keys
/// sorted at every depth, no insignificant whitespace, non-ASCII left as
/// itself, SHA-256 of the UTF-8 bytes, and a whole number spelled without a
/// fractional part.
///
/// Set `THALOVANT_CONFORMANCE_OUT` to a path and run the suite; the results are
/// written when the test bundle finishes.
enum ConformanceRecord {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var results: [String: [String: String]] = [:]
    nonisolated(unsafe) private static var armed = false
    private static let target = ProcessInfo.processInfo.environment["THALOVANT_CONFORMANCE_OUT"]

    /// Canonical JSON, built by hand.
    ///
    /// `JSONSerialization` escapes `/` and offers no control over key order,
    /// and `JSONValue` keeps an integer and a whole double apart -- all of
    /// which are this language's spelling of a value rather than the value.
    static func canonical(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .integer(let number):
            return String(number)
        case .number(let number):
            // conversation-vectors.json carries activated_at as 1.0, and every
            // other SDK writes that value as 1.
            //
            // Refused rather than passed through when it is not whole. Only a
            // whole number inside 2^53 is written the same way by every
            // language here; 1.5 and 1e-7 have per-language spellings, and
            // recording one would be a digest for a value nobody produced. No
            // vector contains one, and if one ever does this should stop
            // rather than lie.
            precondition(
                number.rounded() == number && number.isFinite
                    && abs(number) <= 9_007_199_254_740_992,
                """
                conformance: cannot canonicalise \(number): only whole numbers \
                within 2^53 are spelled the same way in every language
                """)
            return String(Int64(number))
        case .string(let text):
            return quote(text)
        case .array(let items):
            return "[" + items.map(canonical).joined(separator: ",") + "]"
        case .object(let fields):
            return "{" + fields.keys.sorted().map { key in
                quote(key) + ":" + canonical(fields[key]!)
            }.joined(separator: ",") + "}"
        }
    }

    /// The same escaping Python's `json.dumps(ensure_ascii=False)` produces:
    /// quotes, backslashes and control characters, and nothing else -- notably
    /// not `/`, which Foundation would escape.
    private static func quote(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }

    static func canonicalDigest(_ value: JSONValue) -> String {
        sha256Hex(Array(canonical(value).utf8))
    }

    /// The SDK already carries a SHA-256 for the Noise handshake; this borrows
    /// it rather than adding a dependency for the sake of a test helper.
    private static func sha256Hex(_ bytes: [UInt8]) -> String {
        var context = thalovant_sha256_ctx()
        thalovant_sha256_init(&context)
        bytes.withUnsafeBufferPointer { buffer in
            thalovant_sha256_update(&context, buffer.baseAddress, buffer.count)
        }
        var digest = [UInt8](repeating: 0, count: 32)
        digest.withUnsafeMutableBufferPointer { out in
            thalovant_sha256_final(&context, out.baseAddress)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Record what this SDK produced for one case of one vector file.
    static func record(_ vectorFile: String, _ caseName: String, _ produced: JSONValue) {
        guard target != nil else { return }
        let digest = canonicalDigest(produced)
        lock.lock()
        defer { lock.unlock() }
        // Registered on first use rather than from a bundle observer:
        // swift-corelibs-xctest has no principal class to construct one from,
        // and atexit is the same hook the .NET recorder uses.
        if !armed {
            armed = true
            atexit { ConformanceRecord.write() }
        }
        if let previous = results[vectorFile]?[caseName] {
            precondition(previous == digest,
                         "\(vectorFile)/\(caseName): recorded twice with different outputs")
        }
        results[vectorFile, default: [:]][caseName] = digest
    }

    /// Called once the bundle has run. Every test here is one process, so this
    /// needs none of the shard merging the Node and Rust recorders do.
    static func write() {
        guard let target else { return }
        lock.lock()
        defer { lock.unlock() }
        var out: [String: Any] = [:]
        for (vectorFile, cases) in results {
            let stem = String(vectorFile.dropLast(".json".count))
            guard let url = Bundle.module.url(forResource: stem, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                continue
            }
            // The parsed JSON, not the bytes: a vendored copy is allowed to
            // differ in indentation and line endings, and the checker accepts
            // it on the same terms.
            out[vectorFile] = ["digest": canonicalDigest(parsed), "cases": cases]
        }
        let document: [String: Any] = ["schema_version": 1, "results": out]
        // Not `try?`. A path that is a directory, or unwritable, or whose
        // parent cannot be created, would otherwise leave the process
        // succeeding with no record at all -- or worse, with the record a
        // previous run left there, which is exactly the stale artifact this
        // whole mechanism exists to rule out. Failing loudly is the only
        // honest answer when the record cannot be published.
        do {
            let body = try JSONSerialization.data(
                withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            let path = URL(fileURLWithPath: target)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (String(decoding: body, as: UTF8.self) + "\n").write(
                to: path, atomically: true, encoding: .utf8)
        } catch {
            fatalError("conformance: cannot write \(target): \(error)")
        }
    }
}
