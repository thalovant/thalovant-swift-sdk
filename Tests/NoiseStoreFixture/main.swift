// Test-only subprocess used to validate cross-process first-use locking.
import Foundation
import ThalovantSDK
import CThalovantNoise

guard CommandLine.arguments.count == 2 else { exit(2) }
let store = ThalovantFileNoiseStore(directory: URL(fileURLWithPath: CommandLine.arguments[1]), identityScope: "process-fixture")
do {
    let key = try store.privateKey()
    var publicKey = [UInt8](repeating: 0, count: 32)
    guard thalovant_x25519_public([UInt8](key), &publicKey) == 0 else { exit(3) }
    // Only the public key leaves this child process.
    print(publicKey.map { String(format: "%02x", $0) }.joined())
} catch {
    fputs("Noise store child failed: \(error)\n", stderr)
    exit(1)
}
