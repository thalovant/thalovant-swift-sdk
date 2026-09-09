import Foundation
import CThalovantNoise
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Persist a client static key and authenticated hub pins across reconnects and
/// application restarts. Implement with Keychain or another protected store if
/// file storage is unsuitable. Methods must be thread safe; keys are 32 bytes.
/// Never replace a conflicting pin implicitly: a changed hub key is an error.
public protocol ThalovantNoiseStore: Sendable {
    func privateKey() throws -> Data
    func pinnedKey(nodeID: String) throws -> Data?
    func pin(_ key: Data, nodeID: String) throws
}

/// Secure POSIX files (0700 directory, 0600 files, no symlink following), with a
/// process lock for first-use creation. Keys never enter identity serialization.
public final class ThalovantFileNoiseStore: ThalovantNoiseStore, @unchecked Sendable {
    private let directory: URL
    private let scope: String
    private let lock = NSLock()

    public init(directory: URL? = nil, identityScope: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".thalovant")
        self.directory = directory ?? base.appendingPathComponent("Thalovant/noise-swift", isDirectory: true)
        self.scope = noiseHex(noiseHash(Data(identityScope.utf8)))
    }

    public func privateKey() throws -> Data {
        try lockedFile("client-\(scope)") { existing in
            if let existing { return (existing, nil) }
            let key = noiseRandomKey()
            return (key, key)
        }
    }

    public func pinnedKey(nodeID: String) throws -> Data? {
        try lockedFile(pinName(nodeID)) { ($0, nil) }
    }

    public func pin(_ key: Data, nodeID: String) throws {
        guard key.count == 32 else { throw noiseError("Hub static key must contain 32 bytes.") }
        let _: Bool = try lockedFile(pinName(nodeID)) { existing in
            guard existing == nil || existing == key else {
                throw noiseError("Hub static key conflicts with its stored pin. Verify the hub key before explicitly resetting its pin.")
            }
            return (true, existing == nil ? key : nil)
        }
    }

    private func pinName(_ nodeID: String) -> String {
        "hub-\(scope)-\(noiseHex(noiseHash(Data(nodeID.utf8))))"
    }

    private func lockedFile<T>(_ name: String, _ body: (Data?) throws -> (T, Data?)) throws -> T {
        try lock.locked {
            let fm = FileManager.default
            try createDirectory(directory)
            let attributes = try fm.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw noiseError("Noise state directory must be owned by the current user with mode 0700.")
            }
            let path = directory.appendingPathComponent(name).path
            // The lock is separate from key material. Merely looking up a pin
            // must not create an empty data file that resembles corruption.
            let lockFD = open(path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
            guard lockFD >= 0 else { throw noiseError("Cannot open protected Noise state lock.") }
            defer { _ = close(lockFD) }
            guard flock(lockFD, LOCK_EX) == 0 else { throw noiseError("Cannot lock Noise state.") }
            defer { _ = flock(lockFD, LOCK_UN) }
            try validateFile(lockFD, expectedSize: 0)

            var existing: Data?
            let readFD = open(path, O_RDONLY | O_NOFOLLOW)
            if readFD >= 0 {
                defer { _ = close(readFD) }
                // Existing empty/truncated data is never a first-use identity.
                try validateFile(readFD, expectedSize: 32)
                var bytes = [UInt8](repeating: 0, count: 32)
                guard read(readFD, &bytes, 32) == 32 else { throw noiseError("Cannot read Noise state.") }
                existing = Data(bytes)
            } else if errno != ENOENT {
                throw noiseError("Cannot read protected Noise state.")
            }
            let (result, replacement) = try body(existing)
            if let replacement {
                guard replacement.count == 32, existing == nil else { throw noiseError("Refusing to replace existing Noise state.") }
                let staged = directory.appendingPathComponent(".new-" + UUID().uuidString).path
                let writeFD = open(staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
                guard writeFD >= 0 else { throw noiseError("Cannot stage protected Noise state.") }
                defer { _ = close(writeFD); _ = unlink(staged) }
                let count = replacement.withUnsafeBytes { write(writeFD, $0.baseAddress, 32) }
                guard count == 32, fsync(writeFD) == 0 else { throw noiseError("Cannot persist Noise state.") }
                // Linking a fully written file publishes atomically without
                // overwriting an unexpected file created by another process.
                guard link(staged, path) == 0 else { throw noiseError("Noise state appeared during creation; refusing to replace it.") }
                guard unlink(staged) == 0 else { throw noiseError("Cannot finish publishing Noise state.") }
                let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard directoryFD >= 0 else { throw noiseError("Cannot open Noise state directory.") }
                defer { _ = close(directoryFD) }
                guard fsync(directoryFD) == 0 else { throw noiseError("Cannot persist Noise state directory.") }
            }
            return result
        }
    }

    private func createDirectory(_ url: URL) throws {
        // Foundation may create with default permissions before chmod. POSIX
        // mkdir applies 0700 atomically, including concurrent first use.
        if mkdir(url.path, mode_t(0o700)) == 0 { return }
        let error = errno
        if error == EEXIST { return }
        if error == ENOENT {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { throw noiseError("Cannot create Noise state directory.") }
            try createDirectory(parent)
            if mkdir(url.path, mode_t(0o700)) == 0 || errno == EEXIST { return }
        }
        throw noiseError("Cannot create protected Noise state directory.")
    }

    private func validateFile(_ fd: Int32, expectedSize: Int) throws {
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_uid == getuid(),
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_mode & 0o077 == 0, status.st_nlink == 1,
              status.st_size == expectedSize else {
            throw noiseError("Noise state must be a private regular file with its exact expected size; restore corrupted state.")
        }
    }

}

func noiseError(_ text: String) -> ThalovantConnectionError { ThalovantConnectionError(text) }
func noiseHex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
func noiseUnhex(_ text: String) throws -> Data {
    let bytes = Array(text.utf8)
    guard bytes.count % 2 == 0 else { throw noiseError("Malformed Noise hex message.") }
    func digit(_ c: UInt8) -> UInt8? {
        switch c { case 48...57: return c - 48; case 65...70: return c - 55; case 97...102: return c - 87; default: return nil }
    }
    var out = Data(); out.reserveCapacity(bytes.count / 2)
    for i in stride(from: 0, to: bytes.count, by: 2) {
        guard let a = digit(bytes[i]), let b = digit(bytes[i + 1]) else { throw noiseError("Malformed Noise hex message.") }
        out.append(a * 16 + b)
    }
    return out
}
func noiseRandomKey() -> Data {
    var random = SystemRandomNumberGenerator()
    return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
}
func noiseHash(_ data: Data) -> Data {
    var out = [UInt8](repeating: 0, count: 32)
    data.withUnsafeBytes { thalovant_sha256($0.bindMemory(to: UInt8.self).baseAddress, data.count, &out) }
    return Data(out)
}
func noisePSK(password: String, nodeID: String) throws -> Data {
    let password = Array(password.utf8), node = Array(nodeID.utf8)
    let count = Int(THALOVANT_NOISE_PSK_MEMORY_WORDS)
    let scratch = UnsafeMutablePointer<UInt64>.allocate(capacity: count)
    defer { scratch.deallocate() } // C wipes all 64 MiB before returning.
    var out = [UInt8](repeating: 0, count: 32)
    let result = thalovant_noise_psk(password, password.count, node, node.count, scratch, count, &out)
    guard result == 0 else { throw noiseError("Cannot derive the HiveMind Noise PSK.") }
    return Data(out)
}

/// Canonical JSON uses Unicode key order, literal UTF-8 and unescaped slashes,
/// matching Python json.dumps(sort_keys=True, separators=(',',':'), ensure_ascii=False).
/// Negotiation numbers must be integers: nonintegral floats fail closed rather
/// than risking a different transcript across platform JSON implementations.
func noiseCanonical(_ value: JSONValue) throws -> String {
    switch value {
    case .object(let object):
        let keys = object.keys.sorted { Array($0.unicodeScalars).lexicographicallyPrecedes(Array($1.unicodeScalars)) }
        return "{" + (try keys.map { try noiseCanonical(.string($0)) + ":" + noiseCanonical(object[$0]!) }).joined(separator: ",") + "}"
    case .array(let array): return "[" + (try array.map(noiseCanonical)).joined(separator: ",") + "]"
    case .number: throw noiseError("Floating-point Noise negotiation fields are unsupported.")
    default:
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

final class NoiseConnection: @unchecked Sendable {
    static let suite = "25519_AESGCM_SHA256"
    private let lock = NSLock()
    private var state = thalovant_noise()
    private var reassembly: Data?
    private var reassemblyJSON = false
    let pattern: String

    init(pattern: String, psk: Data, prologue: Data, privateKey: Data, pin: Data?,
         ephemeral: Data = noiseRandomKey(), initiator: Bool = true) throws {
        guard ["XXpsk2", "KKpsk0"].contains(pattern), psk.count == 32, privateKey.count == 32,
              ephemeral.count == 32, pin == nil || pin?.count == 32 else { throw noiseError("Invalid Noise key or pattern.") }
        self.pattern = pattern
        let p = [UInt8](psk), prologue = [UInt8](prologue), key = [UInt8](privateKey), ephemeral = [UInt8](ephemeral)
        let result: Int32
        if let pin {
            result = thalovant_noise_init(&state, pattern == "XXpsk2" ? 1 : 2, initiator ? 1 : 0, p, prologue, prologue.count, key, ephemeral, [UInt8](pin))
        } else {
            result = thalovant_noise_init(&state, pattern == "XXpsk2" ? 1 : 2, initiator ? 1 : 0, p, prologue, prologue.count, key, ephemeral, nil)
        }
        guard result == 0 else { throw noiseError("Cannot initialize Noise handshake.") }
    }
    deinit { thalovant_noise_wipe(&state, MemoryLayout<thalovant_noise>.size) }
    var ready: Bool { lock.locked { state.ready == 1 && state.failed == 0 } }
    var remoteKey: Data { lock.locked { withUnsafeBytes(of: state.remote_static) { Data($0) } } }
    func close() { lock.locked { thalovant_noise_wipe(&state, MemoryLayout<thalovant_noise>.size); state.failed = 1; reassembly = nil } }

    private func operation(_ input: Data, _ action: Int) throws -> Data {
        let bytes = [UInt8](input)
        var out = [UInt8](repeating: 0, count: max(128, bytes.count + 96)), count = 0
        let capacity = out.count
        let result: Int32
        switch action {
        case 0: result = thalovant_noise_write(&state, bytes, bytes.count, &out, capacity, &count)
        case 1: result = thalovant_noise_read(&state, bytes, bytes.count, &out, capacity, &count)
        case 2: result = thalovant_noise_encrypt(&state, bytes, bytes.count, &out, capacity, &count)
        default: result = thalovant_noise_decrypt(&state, bytes, bytes.count, &out, capacity, &count)
        }
        guard result == 0 else { throw noiseError("Noise authentication or frame sequencing failed; reconnect with a fresh session.") }
        return Data(out.prefix(count))
    }
    func write(_ payload: Data = Data()) throws -> Data { try lock.locked { try operation(payload, 0) } }
    func read(_ message: Data) throws -> Data { try lock.locked { try operation(message, 1) } }
    func encrypt(_ payload: Data, isJSON: Bool = true) throws -> [Data] {
        try lock.locked {
            guard payload.count <= 32 * 1024 * 1024 else { throw noiseError("Noise message exceeds 32 MiB.") }
            if payload.count <= 65_000 { return [try operation(Data([isJSON ? 0 : 1]) + payload, 2)] }
            var frames: [Data] = []
            for offset in stride(from: 0, to: payload.count, by: 65_000) {
                let end = min(offset + 65_000, payload.count)
                let marker: UInt8 = offset == 0 ? (isJSON ? 2 : 3) : (end == payload.count ? 5 : 4)
                frames.append(try operation(Data([marker]) + payload.subdata(in: offset..<end), 2))
            }
            return frames
        }
    }
    func decrypt(_ frame: Data) throws -> (Data, Bool)? {
        try lock.locked {
            let clear = try operation(frame, 3)
            let marker = clear[0], payload = clear.dropFirst()
            if marker < 2 { return (Data(payload), marker == 0) }
            if marker < 4 { reassembly = Data(); reassemblyJSON = marker == 2 }
            guard var buffer = reassembly, buffer.count <= 32 * 1024 * 1024 - payload.count else {
                thalovant_noise_wipe(&state, MemoryLayout<thalovant_noise>.size); state.failed = 1; reassembly = nil
                throw noiseError("Noise message exceeds the reassembly limit.")
            }
            buffer.append(payload)
            if marker == 5 { reassembly = nil; return (buffer, reassemblyJSON) }
            reassembly = buffer; return nil
        }
    }
}

/// Cleartext binding shared by production WSS and network-free wire fixtures.
/// The authenticated transport HELLO is emitted only after the final handshake
/// frame has been sent; the socket owner controls that completion boundary.
final class NoiseNegotiator {
    let identity: ThalovantIdentity
    let store: any ThalovantNoiseStore
    private let derive: (String, String) throws -> Data
    private let ephemeral: () -> Data
    private var hello: JSONObject?
    private var nodeID: String?
    private(set) var connection: NoiseConnection?

    init(identity: ThalovantIdentity, store: any ThalovantNoiseStore,
         derive: @escaping (String, String) throws -> Data = noisePSK,
         ephemeral: @escaping () -> Data = noiseRandomKey) {
        self.identity = identity; self.store = store; self.derive = derive; self.ephemeral = ephemeral
    }
    func receive(_ message: HiveMessage) throws -> [HiveMessage] {
        if message.msgType == "hello" {
            guard hello == nil, connection == nil, let id = message.payload["node_id"]?.stringValue, !id.isEmpty else {
                throw noiseError("Noise requires one initial HELLO carrying node_id.")
            }
            hello = message.payload; nodeID = id; return []
        }
        guard ["shake", "handshake"].contains(message.msgType),
              let params = message.payload["noise"]?.objectValue else {
            throw noiseError("This runtime requires a HiveMind v3 Noise handshake; legacy or cleartext messages are rejected.")
        }
        if let msg = params["msg"]?.stringValue {
            guard let connection, !connection.ready, let nodeID else { throw noiseError("Unexpected Noise handshake continuation.") }
            _ = try connection.read(noiseUnhex(msg))
            var replies: [HiveMessage] = []
            if !connection.ready { replies.append(HiveMessage(msgType: "shake", payload: ["noise": .object(["msg": .string(noiseHex(try connection.write()))])])) }
            guard connection.ready else { throw noiseError("Noise handshake did not complete.") }
            try store.pin(connection.remoteKey, nodeID: nodeID)
            return replies
        }
        guard connection == nil, let hello, let nodeID,
              let version = message.payload["max_protocol_version"]?.intValue, version >= 3,
              let patterns = params["patterns"]?.arrayValue,
              let suites = params["suites"]?.arrayValue,
              suites.contains(.string(NoiseConnection.suite)) else {
            throw noiseError("The hub does not offer a mutually supported v3 Noise suite after HELLO.")
        }
        let pin = try store.pinnedKey(nodeID: nodeID)
        let pattern: String
        if pin != nil && patterns.contains(.string("KKpsk0")) { pattern = "KKpsk0" }
        else if patterns.contains(.string("XXpsk2")) { pattern = "XXpsk2" }
        else { throw noiseError("The hub does not offer a mutually supported Noise pattern.") }
        let protocolName = "Noise_\(pattern)_\(NoiseConnection.suite)"
        let prologue = Data((try noiseCanonical(.object(hello)) + noiseCanonical(.object(message.payload)) + protocolName).utf8)
        let state = try NoiseConnection(pattern: pattern, psk: derive(identity.password, nodeID), prologue: prologue,
                                        privateKey: store.privateKey(), pin: pin, ephemeral: ephemeral())
        let bytes = try state.write(Data("{\"binarize\":false,\"encodings\":[]}".utf8))
        connection = state
        return [HiveMessage(msgType: "shake", payload: ["noise": .object([
            "pattern": .string(pattern), "suite": .string(NoiseConnection.suite), "msg": .string(noiseHex(bytes))
        ])])]
    }
}

extension NoiseConnection: CustomReflectable, CustomStringConvertible {
    var description: String { "NoiseConnection(pattern: \(pattern), secrets: <redacted>)" }
    var customMirror: Mirror { Mirror(self, children: ["pattern": pattern, "secrets": "<redacted>"]) }
}
extension NoiseNegotiator: CustomReflectable, CustomStringConvertible {
    var description: String { "NoiseNegotiator(secrets: <redacted>)" }
    var customMirror: Mirror { Mirror(self, children: ["secrets": "<redacted>"]) }
}
