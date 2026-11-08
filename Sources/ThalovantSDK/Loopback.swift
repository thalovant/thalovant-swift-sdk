import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// The loopback listener a browser sign-in waits on (RFC 8252 section 7.3).
//
// A program that signs in through the browser binds 127.0.0.1 on a port the
// system picks, sends the browser to the authorization page with
// http://127.0.0.1:<port>/callback as its redirect, and waits here for the
// browser to come back. Only GET /callback is served; anything else is a 404.
// A callback whose state is not this sign-in's is a 400 and changes nothing: a
// stray tab -- an old attempt's, another program's, a page probing local ports
// -- must not end a real sign-in. The first callback with the right state is
// accepted, the port stops listening, and its tab is answered once the caller
// says how the sign-in ended.
//
// Everything that decides what a request means is in
// `classifyLoopbackRequest`, which touches no socket, so it is checked against
// the shared vectors on its own. The listener is plain POSIX sockets on a
// thread of its own and writes nothing to a log, so the code and the state in a
// request line never reach one.

/// The one path the loopback listener answers.
let loopbackCallbackPath = "/callback"

/// What the accepted tab shows when the sign-in worked.
let loopbackSignedInText = "Signed in to Thalovant. You can close this tab."
/// What it shows when it did not: denied, failed, the exchange refused, or a timeout.
let loopbackNotCompletedText = "Sign-in was not completed."
/// What a tab whose answer belongs to another sign-in shows.
let loopbackWrongStateText = "This answer does not belong to the sign-in in progress."
/// What anything other than `GET /callback` shows.
let loopbackNotFoundText = "Not found."

/// Sent with every answer. The pages load nothing, and nothing they show may be
/// cached or leak the callback's address (code and state) as a referrer.
let loopbackPageHeaders: [(String, String)] = [
    ("Content-Type", "text/html; charset=utf-8"),
    ("Cache-Control", "no-store"),
    ("Referrer-Policy", "no-referrer"),
    ("Content-Security-Policy", "default-src 'none'"),
    ("X-Content-Type-Options", "nosniff"),
]

/// The `error` values RFC 6749 section 4.1.2.1 defines. Only these are kept
/// from a callback: anything else is a value somebody else chose, and it could
/// be the state or a code, which must never reach an error message.
let loopbackOAuthErrors: Set<String> = [
    "invalid_request", "unauthorized_client", "access_denied", "unsupported_response_type",
    "invalid_scope", "server_error", "temporarily_unavailable",
]

/// An accepted callback: the browser came back with this sign-in's state.
///
/// `code` when the person approved; `denied` for `error=access_denied`;
/// `failed` for any other `error` (kept only when it is one of
/// `loopbackOAuthErrors`, else nil), or for neither an error nor exactly one
/// non-empty code.
enum LoopbackCallback: Equatable, Sendable, CustomStringConvertible {
    case code(String)
    case denied
    case failed(error: String?)

    /// Never the code: this may be printed.
    var description: String {
        switch self {
        case .code: return "LoopbackCallback.code(<redacted>)"
        case .denied: return "LoopbackCallback.denied"
        case .failed(let error): return "LoopbackCallback.failed(error: \(error ?? "nil"))"
        }
    }
}

/// What the listener answers one request with, and the callback it accepts.
///
/// `(404, nil)` for anything but `GET` on exactly `/callback`; `(400, nil)`
/// when `state` is missing, given more than once, or not this sign-in's
/// (compared in constant time, as UTF-8 bytes); otherwise `(200, callback)`.
/// An `error` wins over a `code` sent with it: a refusal that also carries a
/// code is still a refusal. An `error` outside `loopbackOAuthErrors` is not
/// kept. Query values are decoded once, as a form decodes them.
func classifyLoopbackRequest(method: String, target: String, state: String) -> (status: Int, callback: LoopbackCallback?) {
    let path: Substring
    let query: Substring
    if let mark = target.firstIndex(of: "?") {
        path = target[..<mark]
        query = target[target.index(after: mark)...]
    } else {
        path = target[...]
        query = ""
    }
    guard method == "GET", path == loopbackCallbackPath else { return (404, nil) }
    var values: [String: [String]] = [:]
    for (key, value) in loopbackFormPairs(query) {
        values[key, default: []].append(value)
    }
    let given = values["state"] ?? []
    guard given.count == 1, constantTimeEqual(Array(given[0].utf8), Array(state.utf8)) else {
        return (400, nil)
    }
    if let errors = values["error"], !errors.isEmpty {
        if errors == ["access_denied"] { return (200, .denied) }
        return (200, .failed(error: loopbackOAuthErrors.contains(errors[0]) ? errors[0] : nil))
    }
    let codes = values["code"] ?? []
    if codes.count == 1, !codes[0].isEmpty { return (200, .code(codes[0])) }
    return (200, .failed(error: nil))
}

/// Whether two byte strings are equal, in time that depends only on their
/// lengths.
func constantTimeEqual(_ left: [UInt8], _ right: [UInt8]) -> Bool {
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices {
        difference |= left[index] ^ right[index]
    }
    return difference == 0
}

/// A query string's pairs, as an HTML form decodes them (Python's `parse_qsl`
/// with blank values kept): fields split on `&`, empty fields skipped, a field
/// without `=` an empty value, `+` a space, and `%XX` decoded once as UTF-8.
func loopbackFormPairs(_ query: Substring) -> [(String, String)] {
    var pairs: [(String, String)] = []
    for field in query.split(separator: "&", omittingEmptySubsequences: true) {
        if let equals = field.firstIndex(of: "=") {
            pairs.append((formDecode(field[..<equals]), formDecode(field[field.index(after: equals)...])))
        } else {
            pairs.append((formDecode(field), ""))
        }
    }
    return pairs
}

/// `+` as a space, then every `%XX` as the byte it names, decoded as UTF-8 with
/// ill-formed bytes replaced. A `%` without two hex digits after it stays as it
/// is. A character outside ASCII (a request line is read as Latin-1) is kept as
/// that character, as Python's `unquote` keeps it.
func formDecode(_ text: Substring) -> String {
    let scalars = Array(text.unicodeScalars)
    var out = ""
    var bytes: [UInt8] = []
    func flush() {
        if !bytes.isEmpty {
            out += String(decoding: bytes, as: UTF8.self)
            bytes.removeAll()
        }
    }
    func hex(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "0"..."9": return UInt8(scalar.value - 48)
        case "a"..."f": return UInt8(scalar.value - 87)
        case "A"..."F": return UInt8(scalar.value - 55)
        default: return nil
        }
    }
    var index = 0
    while index < scalars.count {
        let scalar = scalars[index]
        if !scalar.isASCII {
            flush()
            out.unicodeScalars.append(scalar)
            index += 1
        } else if scalar == "%", index + 2 < scalars.count,
                  let high = hex(scalars[index + 1]), let low = hex(scalars[index + 2]) {
            bytes.append(high << 4 | low)
            index += 3
        } else {
            bytes.append(scalar == "+" ? 0x20 : UInt8(scalar.value))
            index += 1
        }
    }
    flush()
    return out
}

/// A page that loads nothing: no script, no style sheet, no image, no link.
func loopbackPage(_ text: String) -> String {
    "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
        + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        + "<title>Thalovant</title></head><body><p>\(text)</p></body></html>\n"
}

/// A whole HTTP/1.1 answer: the status, `loopbackPageHeaders`, and a small page.
///
/// The answer to a `HEAD` carries no body (RFC 9110 section 9.3.2); its
/// `Content-Length` is the length the page would have had.
func loopbackResponse(status: Int, text: String, head: Bool = false) -> [UInt8] {
    let reasons = [200: "OK", 400: "Bad Request", 404: "Not Found"]
    let body = Array(loopbackPage(text).utf8)
    var lines = ["HTTP/1.1 \(status) \(reasons[status] ?? "Error")"]
    lines += loopbackPageHeaders.map { "\($0.0): \($0.1)" }
    lines += ["Content-Length: \(body.count)", "Connection: close", "", ""]
    return Array(lines.joined(separator: "\r\n").utf8) + (head ? [] : body)
}

/// The method and target of a request head, or nil when it has no request line.
///
/// Read as Latin-1, byte for byte, so that a byte outside ASCII is a character
/// that never matches rather than a decoding failure.
func loopbackRequestLine(_ head: ArraySlice<UInt8>) -> (method: String, target: String)? {
    var end = head.endIndex
    var index = head.startIndex
    while index + 1 < head.endIndex {
        if head[index] == 0x0D && head[index + 1] == 0x0A {
            end = index
            break
        }
        index += 1
    }
    let line = String(head[head.startIndex..<end].map { Character(Unicode.Scalar($0)) })
    let parts = line.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return nil }
    return (String(parts[0]), String(parts[1]))
}

#if os(macOS) || os(Linux)

/// Waits on 127.0.0.1 for the browser to bring this sign-in's answer back.
///
/// `start()` binds the port (before any URL is built), `wait(timeout:)`
/// returns the accepted callback or nil at the deadline, `finish(signedIn:)`
/// says which page its tab gets, and `close()` stops everything. Never binds
/// anything but the loopback address.
///
/// One thread runs a `poll(2)` loop over the listening socket, every
/// connection, and a pipe the other methods wake it with. Connections are
/// non-blocking and get one answer each; one that sends nothing never holds
/// the sign-in. After an answer the write side is shut and what the browser
/// still sends is read and dropped (at most `drainTimeout` and `drainLimit`)
/// before the connection closes: closing with bytes unread would reset it, and
/// macOS then throws away the answer the browser had not read yet.
final class LoopbackListener: @unchecked Sendable {
    /// The largest request head read; a callback's is a few hundred bytes.
    static let maxRequestHead = 16 * 1024
    /// How long an answer may take to write, and how long closing waits for
    /// the accepted tab to finish reading its page.
    static let closeGrace: TimeInterval = 1
    /// Connections held at once. A new one past this replaces the oldest
    /// connection that has not sent its head, so idle sockets cannot keep a
    /// real tab out.
    static let maxConnections = 64
    /// Connections accepted before the loop goes back to the rest of its work.
    static let acceptBatch = 16
    /// The most of what the browser still sends after an answer that is read
    /// and dropped before the connection closes anyway.
    static let drainLimit = 1024 * 1024

    let state: String
    /// How long one connection may take to send its request head.
    let readTimeout: TimeInterval
    /// How long, after an answer, what the browser still sends is read and dropped.
    let drainTimeout: TimeInterval

    private let lock = NSLock()
    // Shared with the loop thread, under `lock`.
    private var started = false
    private var exited = false
    private var closing = false
    private var accepted: LoopbackCallback?
    private var answer: Bool?
    private var waiter: CheckedContinuation<LoopbackCallback?, Never>?
    private var waitDeadline: UInt64 = 0
    private var waitCancelled = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var wakeWrite: Int32 = -1
    private var boundAddress: String?
    private var connectionCount = 0

    // The loop thread's own.
    private var listenFD: Int32 = -1
    private var wakeRead: Int32 = -1
    private var pending: [Int32: Pending] = [:]
    private var draining: [Int32: Drain] = [:]
    private var acceptedFD: Int32 = -1
    private var tabFD: Int32 = -1

    private struct Pending {
        var head: [UInt8] = []
        let opened: UInt64
        let deadline: UInt64
    }

    private struct Drain {
        let deadline: UInt64
        var dropped = 0
    }

    init(state: String, readTimeout: TimeInterval = 10, drainTimeout: TimeInterval = 2) {
        self.state = state
        self.readTimeout = readTimeout
        self.drainTimeout = drainTimeout
    }

    /// The address the listening socket is bound to, once started: always `127.0.0.1`.
    var localAddress: String? { lock.locked { boundAddress } }

    /// The connections the listener still holds: waiting for a head, waiting
    /// for the sign-in to end, or being drained.
    var openConnections: Int { lock.locked { connectionCount } }

    /// Binds 127.0.0.1 on a port the system picks, and returns the port.
    func start() throws -> Int {
        let listening = try Self.loopbackSocket()
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = in_addr_t(UInt32(0x7F00_0001).bigEndian)
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listening, $0, size) }
        }
        var named = sockaddr_in()
        var length = size
        let gotName = withUnsafeMutablePointer(to: &named) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listening, $0, &length) }
        }
        var pipeEnds: [Int32] = [-1, -1]
        guard bound == 0, listen(listening, 8) == 0, gotName == 0, pipe(&pipeEnds) == 0 else {
            let reason = Self.lastError()
            systemClose(listening)
            throw ThalovantApiError(message: "Could not listen on 127.0.0.1 for the browser sign-in: \(reason)")
        }
        for end in pipeEnds { Self.configure(end) }
        let port = Int(UInt16(bigEndian: named.sin_port))
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var host = named.sin_addr
        let shown = inet_ntop(AF_INET, &host, &text, socklen_t(text.count)) != nil ? String(cString: text) : nil
        listenFD = listening
        wakeRead = pipeEnds[0]
        lock.locked {
            wakeWrite = pipeEnds[1]
            boundAddress = shown
            started = true
        }
        let thread = Thread { [self] in run() }
        thread.name = "thalovant-loopback"
        thread.start()
        return port
    }

    /// The first accepted callback, or nil once `timeout` seconds have passed,
    /// the task is cancelled, or the listener is closed.
    ///
    /// Measured on the monotonic clock and never cut short: the loop checks the
    /// clock after every wake and waits again for what is left. A callback that
    /// is read only once the deadline has passed is not this wait's any more.
    func wait(timeout: TimeInterval) async -> LoopbackCallback? {
        let deadline = Self.now() &+ Self.nanoseconds(timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<LoopbackCallback?, Never>) in
                let immediate: LoopbackCallback?? = lock.locked {
                    if let accepted { return .some(accepted) }
                    if !started || exited || closing || waitCancelled || timeout <= 0 || waiter != nil {
                        return .some(nil)
                    }
                    waiter = continuation
                    waitDeadline = deadline
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                } else {
                    wake()
                }
            }
        } onCancel: {
            let waiting = lock.locked { () -> CheckedContinuation<LoopbackCallback?, Never>? in
                waitCancelled = true
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume(returning: nil)
        }
    }

    /// Answers the accepted tab: signed in, or not completed. The first word stands.
    ///
    /// The tab waits for this as long as the sign-in takes, with no deadline
    /// of its own: its page says how the sign-in ended, so it cannot be written
    /// before it has. `close()` always answers it.
    func finish(signedIn: Bool) {
        lock.locked {
            if answer == nil { answer = signedIn }
        }
        wake()
    }

    /// Stops listening, gives an accepted tab its page (and up to `closeGrace`
    /// to read it), and closes every other connection without waiting for it.
    func close() async {
        let running = lock.locked { () -> Bool in
            if answer == nil { answer = false }
            closing = true
            return started && !exited
        }
        wake()
        guard running else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = lock.locked { () -> Bool in
                if exited { return true }
                exitWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    /// Whether a wait whose deadline is `deadline` is over at `now`.
    static func waitIsOver(deadline: UInt64, now: UInt64) -> Bool { now >= deadline }

    private func wake() {
        lock.locked {
            guard wakeWrite >= 0 else { return }
            var byte: UInt8 = 1
            _ = write(wakeWrite, &byte, 1)
        }
    }

    // MARK: The loop

    private func run() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let now = Self.now()
            let (isClosing, answerNow, waiting, deadline) = lock.locked {
                (closing, answer, waiter != nil, waitDeadline)
            }
            if waiting && Self.waitIsOver(deadline: deadline, now: now) {
                expireWaiter()
            }
            if acceptedFD >= 0, let answerNow {
                let fd = acceptedFD
                acceptedFD = -1
                respond(fd, status: 200, text: answerNow ? loopbackSignedInText : loopbackNotCompletedText)
                if draining[fd] != nil { tabFD = fd }
            }
            for (fd, connection) in pending where now >= connection.deadline {
                // A head that never came: closed without an answer.
                pending[fd] = nil
                systemClose(fd)
            }
            for (fd, drain) in draining where now >= drain.deadline {
                stopDraining(fd)
            }
            publishCount()
            if isClosing {
                shutDown(&chunk)
                return
            }

            var fds = [pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            let listening = listenFD >= 0
            if listening { fds.append(pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)) }
            let reading = Array(pending.keys)
            let dropping = Array(draining.keys)
            for fd in reading + dropping { fds.append(pollfd(fd: fd, events: Int16(POLLIN), revents: 0)) }
            var next: [UInt64] = pending.values.map(\.deadline) + draining.values.map(\.deadline)
            if waiting { next.append(deadline) }
            let ready = poll(&fds, nfds_t(fds.count), Self.pollTimeout(until: next.min()))
            if ready < 0 {
                if errno != EINTR { usleep(10_000) }
                continue
            }
            if fds[0].revents != 0 {
                while read(wakeRead, &chunk, chunk.count) > 0 {}
            }
            if listening && fds[1].revents != 0 { acceptBatch(&chunk) }
            let first = listening ? 2 : 1
            for (offset, fd) in reading.enumerated() where fds[first + offset].revents != 0 {
                serve(fd, &chunk)
            }
            for (offset, fd) in dropping.enumerated() where fds[first + reading.count + offset].revents != 0 {
                drain(fd, &chunk)
            }
        }
    }

    private func expireWaiter() {
        let expired = lock.locked { () -> CheckedContinuation<LoopbackCallback?, Never>? in
            guard accepted == nil else { return nil }
            defer { waiter = nil }
            return waiter
        }
        expired?.resume(returning: nil)
    }

    /// Accepts at most `acceptBatch` connections, then lets the loop get on
    /// with callbacks, deadlines and closing: a flood of connections cannot
    /// starve it.
    private func acceptBatch(_ chunk: inout [UInt8]) {
        for _ in 0..<Self.acceptBatch {
            guard listenFD >= 0 else { return }
            let connection = accept(listenFD, nil, nil)
            guard connection >= 0 else {
                // Out of descriptors, say: the socket stays readable, so wait
                // a moment rather than spin on it.
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR && errno != ECONNABORTED {
                    usleep(10_000)
                }
                return
            }
            Self.configure(connection)
            if held >= Self.maxConnections {
                makeRoom(&chunk)
            }
            let now = Self.now()
            pending[connection] = Pending(opened: now, deadline: now &+ Self.nanoseconds(readTimeout))
        }
    }

    /// Serves every waiting connection that has something to read -- a
    /// callback the browser has sent is never the one closed -- then, if
    /// still full, closes the oldest connection that has not sent its head,
    /// else the one being drained longest.
    private func makeRoom(_ chunk: inout [UInt8]) {
        var ready = pending.keys.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        if !ready.isEmpty, poll(&ready, nfds_t(ready.count), 0) > 0 {
            for entry in ready where entry.revents != 0 { serve(entry.fd, &chunk) }
        }
        // Served, a callback is accepted and its tab still held: it counts.
        guard held >= Self.maxConnections else { return }
        if let oldest = pending.min(by: { $0.value.opened < $1.value.opened })?.key {
            pending[oldest] = nil
            systemClose(oldest)
        } else if let oldest = draining.min(by: { $0.value.deadline < $1.value.deadline })?.key {
            stopDraining(oldest)
        }
    }

    /// Reads what a connection sent; once its head is whole, answers it, or
    /// hands an accepted callback to `wait(timeout:)`.
    private func serve(_ fd: Int32, _ chunk: inout [UInt8]) {
        guard var connection = pending[fd] else { return }
        let count = recv(fd, &chunk, chunk.count, 0)
        if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            // Gone before sending a whole request head.
            pending[fd] = nil
            systemClose(fd)
            return
        }
        guard count > 0 else { return }
        connection.head.append(contentsOf: chunk[0..<count])
        let separator = Self.headEnd(connection.head)
        if separator == nil && connection.head.count + 1 - 4 <= Self.maxRequestHead {
            pending[fd] = connection
            return
        }
        pending[fd] = nil
        guard let separator, separator <= Self.maxRequestHead,
              let request = loopbackRequestLine(connection.head[0..<separator + 4]) else {
            // An answer to a HEAD carries no body, even when the head could
            // not be read whole: its method is the first word sent.
            respond(fd, status: 400, text: loopbackWrongStateText, head: connection.head.starts(with: Array("HEAD ".utf8)))
            return
        }
        let (status, callback) = classifyLoopbackRequest(method: request.method, target: request.target, state: state)
        let now = Self.now()
        let taken = lock.locked { () -> (Bool, CheckedContinuation<LoopbackCallback?, Never>?, CheckedContinuation<LoopbackCallback?, Never>?) in
            guard let callback, accepted == nil, !closing else { return (false, nil, nil) }
            accepted = callback
            defer { waiter = nil }
            // Read only once the wait was over: the sign-in has expired, and
            // its tab is told so when the listener closes.
            if waiter != nil && Self.waitIsOver(deadline: waitDeadline, now: now) { return (true, nil, waiter) }
            return (true, waiter, nil)
        }
        guard taken.0 else {
            // A second answer with the right state, after the first was
            // accepted, is not this sign-in's any more either.
            let answered = callback == nil ? status : 400
            respond(fd, status: answered, text: answered == 404 ? loopbackNotFoundText : loopbackWrongStateText,
                    head: request.method == "HEAD")
            return
        }
        acceptedFD = fd
        // The first accepted callback ends the listening; a tab already
        // connected is still answered.
        if listenFD >= 0 {
            systemClose(listenFD)
            listenFD = -1
        }
        taken.1?.resume(returning: callback)
        taken.2?.resume(returning: nil)
    }

    /// Writes one whole answer (within `closeGrace`), shuts the write side, and
    /// drains the connection until the browser closes its side.
    private func respond(_ fd: Int32, status: Int, text: String, head: Bool = false) {
        let bytes = loopbackResponse(status: status, text: text, head: head)
        let deadline = Self.now() &+ Self.nanoseconds(Self.closeGrace)
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes[sent...].withUnsafeBytes { buffer in
                send(fd, buffer.baseAddress, buffer.count, Self.sendFlags)
            }
            if wrote > 0 {
                sent += wrote
                continue
            }
            guard wrote < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { break }
            guard Self.now() < deadline else { break }
            var writable = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&writable, 1, Self.pollTimeout(until: deadline))
        }
        guard sent == bytes.count, shutdown(fd, Int32(SHUT_WR)) == 0 else {
            systemClose(fd)
            return
        }
        draining[fd] = Drain(deadline: Self.now() &+ Self.nanoseconds(drainTimeout))
    }

    /// Reads and drops what a drained connection sends; closes it at its end,
    /// on an error, or past `drainLimit`.
    private func drain(_ fd: Int32, _ chunk: inout [UInt8]) {
        guard var progress = draining[fd] else { return }
        while true {
            let count = recv(fd, &chunk, chunk.count, Int32(MSG_DONTWAIT))
            if count > 0 {
                progress.dropped += count
                if progress.dropped > Self.drainLimit {
                    stopDraining(fd)
                    return
                }
                continue
            }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                draining[fd] = progress
                return
            }
            stopDraining(fd)
            return
        }
    }

    private func stopDraining(_ fd: Int32) {
        draining[fd] = nil
        if fd == tabFD { tabFD = -1 }
        systemClose(fd)
    }

    /// Every connection the listener holds: waiting for a head, the accepted
    /// tab waiting for its page, or being drained. The cap applies to this.
    private var held: Int { pending.count + draining.count + (acceptedFD >= 0 ? 1 : 0) }

    private func publishCount() {
        let count = held
        lock.locked { connectionCount = count }
    }

    private func shutDown(_ chunk: inout [UInt8]) {
        if listenFD >= 0 {
            systemClose(listenFD)
            listenFD = -1
        }
        if acceptedFD >= 0 {
            let fd = acceptedFD
            acceptedFD = -1
            respond(fd, status: 200, text: loopbackNotCompletedText)
            if draining[fd] != nil { tabFD = fd }
        }
        // A browser opens connections it never sends anything on; those, and
        // every other answer still draining, are just closed.
        for fd in pending.keys { systemClose(fd) }
        pending = [:]
        for fd in draining.keys where fd != tabFD { stopDraining(fd) }
        // The accepted tab gets up to `closeGrace` to read its page and close.
        let grace = Self.now() &+ Self.nanoseconds(Self.closeGrace)
        while tabFD >= 0, Self.now() < grace {
            var readable = pollfd(fd: tabFD, events: Int16(POLLIN), revents: 0)
            if poll(&readable, 1, Self.pollTimeout(until: grace)) > 0 {
                drain(tabFD, &chunk)
            }
        }
        if tabFD >= 0 { stopDraining(tabFD) }
        publishCount()
        let (waiting, exits) = lock.locked { () -> (CheckedContinuation<LoopbackCallback?, Never>?, [CheckedContinuation<Void, Never>]) in
            systemClose(wakeWrite)
            wakeWrite = -1
            exited = true
            defer { waiter = nil; exitWaiters = [] }
            return (waiter, exitWaiters)
        }
        systemClose(wakeRead)
        wakeRead = -1
        waiting?.resume(returning: nil)
        for exit in exits { exit.resume() }
    }

    // MARK: Plumbing

    /// Where `\r\n\r\n` starts in a head, if it is there.
    private static func headEnd(_ head: [UInt8]) -> Int? {
        guard head.count >= 4 else { return nil }
        for index in 0...(head.count - 4)
        where head[index] == 0x0D && head[index + 1] == 0x0A && head[index + 2] == 0x0D && head[index + 3] == 0x0A {
            return index
        }
        return nil
    }

    private static func loopbackSocket() throws -> Int32 {
        #if canImport(Glibc)
        // Close-on-exec from the start: the browser this sign-in opens must
        // never inherit the port.
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else {
            throw ThalovantApiError(message: "Could not listen on 127.0.0.1 for the browser sign-in: \(lastError())")
        }
        configure(fd)
        return fd
    }

    /// Non-blocking, close-on-exec, and on Apple platforms no SIGPIPE.
    private static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        #if canImport(Darwin)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    #if canImport(Glibc)
    private static let sendFlags = Int32(MSG_NOSIGNAL)
    #else
    private static let sendFlags: Int32 = 0
    #endif

    private static func lastError() -> String {
        String(cString: strerror(errno))
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Seconds as nanoseconds, clamped: a negative or NaN wait is none, and an
    /// enormous one is a century.
    static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return seconds == .infinity ? 3_153_600_000_000_000_000 : 0 }
        return seconds >= 3_153_600_000 ? 3_153_600_000_000_000_000 : UInt64(seconds * 1_000_000_000)
    }

    /// Milliseconds until `deadline`, rounded up so that a wake is never early;
    /// -1 (forever) when there is nothing to wait for.
    private static func pollTimeout(until deadline: UInt64?) -> Int32 {
        guard let deadline else { return -1 }
        let now = now()
        guard deadline > now else { return 0 }
        let milliseconds = (deadline - now + 999_999) / 1_000_000
        return Int32(min(milliseconds, UInt64(Int32.max)))
    }
}

#if canImport(Glibc)
private func systemClose(_ fd: Int32) { if fd >= 0 { _ = Glibc.close(fd) } }
#else
private func systemClose(_ fd: Int32) { if fd >= 0 { _ = Darwin.close(fd) } }
#endif

#endif
