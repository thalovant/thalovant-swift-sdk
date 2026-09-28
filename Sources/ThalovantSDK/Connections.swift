import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How long `waitForAdmission` waits by default: a hub admits a new connection
/// in about ninety seconds.
public let defaultAdmissionTimeout: TimeInterval = 180

/// Seconds between two reads of an operation a caller is waiting on.
public let defaultOperationPollInterval: TimeInterval = 2

extension ThalovantApiError {
    /// A 422 whose problem is about `connection_type`: the API does not know
    /// the kind of connection it was asked for.
    ///
    /// Read from the problem's `detail` and `code`, and from each validation
    /// error's `loc` and `msg` -- never from the rest of the body. A
    /// validation error echoes what was sent as `input`, and the request
    /// always carries `spec.connection_type`, so a 422 about any other field
    /// would otherwise read as "this kind is not supported".
    var refusesConnectionType: Bool {
        guard statusCode == 422 else { return false }
        var said = [detail, errorCode].compactMap { $0 }
        for key in ["errors", "detail"] {
            for entry in problem?[key]?.arrayValue ?? [] {
                guard let entry = entry.objectValue else { continue }
                switch entry["loc"] {
                case .array(let parts)?:
                    said.append(parts.map(Self.locationPart).joined(separator: "."))
                case .string(let location)?:
                    said.append(location)
                default:
                    break
                }
                if let message = entry["msg"]?.stringValue { said.append(message) }
            }
        }
        return said.contains { $0.contains("connection_type") || $0.contains("connectionType") }
    }

    private static func locationPart(_ part: JSONValue) -> String {
        switch part {
        case .string(let text): return text
        case .integer(let number): return String(number)
        case .number(let number): return String(number)
        default: return ""
        }
    }
}

extension ThalovantControlPlane {

    // MARK: Connections

    /// `GET /v1/clients/{clientId}`: one connection, with the `etag` a change
    /// or a delete needs.
    public func getClient(_ clientId: String) async throws -> JSONObject {
        try await requestObject("GET", "/v1/clients/\(encodePathComponent(clientId))")
    }

    /// `DELETE /v1/clients/{clientId}`: deletes a connection.
    ///
    /// The API wants the connection's current `etag` as `If-Match`. Without
    /// one this reads it first; if another writer changed the connection in
    /// between (HTTP 412) it reads the etag once more and retries, once. A
    /// connection that is already gone (HTTP 404, on either request) counts as
    /// deleted.
    public func deleteClient(_ clientId: String, etag: String? = nil) async throws {
        let path = "/v1/clients/\(encodePathComponent(clientId))"
        var etag = etag
        for attempt in 0..<2 {
            do {
                let current: String
                if let etag {
                    current = etag
                } else {
                    let resource = try await getClient(clientId)
                    guard let read = optionalString(resource["etag"]) else {
                        throw ThalovantApiError(message: "Thalovant API client resource is missing its etag.")
                    }
                    current = read
                }
                _ = try await requestData("DELETE", path, headers: ["If-Match": current])
                return
            } catch let error as ThalovantApiError {
                if error.statusCode == 404 { return }
                if error.statusCode != 412 || attempt == 1 { throw error }
                etag = nil
            }
        }
    }

    /// Deletes and refuses a connection the API did not make of the kind asked.
    ///
    /// An API that ignores `spec.connection_type` would hand out an ordinary
    /// connection with the grants of one, so a create whose answer does not
    /// repeat the kind is undone before it fails.
    func requireConnectionType(_ client: JSONObject, _ connectionType: String) async throws {
        let echoed = client["spec"]?["connection_type"]?.stringValue
        if echoed == connectionType { return }
        var cleanup = ""
        if let clientId = client["id"]?.stringValue, !clientId.isEmpty {
            do {
                try await deleteClient(clientId, etag: optionalString(client["etag"]))
            } catch is ThalovantApiError {
                cleanup = " Deleting the connection it made instead (\(clientId)) failed; remove it in the dashboard."
            }
        }
        throw ThalovantApiError(
            message: "The Thalovant API did not make a '\(connectionType)' connection "
                + "(it answered '\(echoed ?? "no type")').\(cleanup)",
            kind: .unsupportedConnectionType
        )
    }

    // MARK: Admission

    /// Waits until the hub has admitted a new connection: about ninety seconds
    /// after `createClientIdentity` made it.
    ///
    /// Follows the result's `operation`, polling `GET /v1/operations/{id}`
    /// every `pollInterval` seconds. Returns once it is `ready`, and at once
    /// when there is nothing to wait on: no operation, or one the API no
    /// longer tracks (HTTP 404). A 5xx while polling is ridden out, and so is
    /// a 429 -- a Free plan allows 60 requests a minute, and a wait must not
    /// end over one of them -- for the wait the API names
    /// (`ThalovantApiError.retryAfterSeconds`), never past `timeout`. No read
    /// runs past `timeout` either.
    ///
    /// Throws:
    /// - `ThalovantAdmissionFailedError` when the operation failed or the
    ///   platform gave up on it (`errorCode`, the operation's own), or when the
    ///   API refused the wait itself (`apiError`, with what it answered);
    /// - `ThalovantAdmissionTimeoutError` when `timeout` passes first -- a
    ///   connection error and a timeout at once, since the connection may still
    ///   be admitted after that;
    /// - the `ThalovantApiError` as it came for a 401 or 403 (kind `.auth`:
    ///   sign in again) and for an API out of reach (kind `.unreachable`):
    ///   neither says anything about the connection.
    ///
    /// An operation whose `links.self` names another origin than the API's --
    /// scheme, host and port, the scheme's default port spelled out -- is never
    /// fetched, and throws: the token goes nowhere else.
    public func waitForAdmission(
        _ result: BootstrapIdentityResult,
        timeout: TimeInterval = defaultAdmissionTimeout,
        pollInterval: TimeInterval = defaultOperationPollInterval
    ) async throws {
        // Read from the answer as sent rather than through `operation`: an
        // operation whose status this SDK does not know yet still has to be
        // waited on, not taken for none.
        let raw = result.client["operation"]?.objectValue
        let id = raw?["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        try await waitForAdmission(
            operationId: id, selfLink: raw?["links"]?["self"]?.stringValue, timeout: timeout,
            pollInterval: pollInterval)
    }

    /// `waitForAdmission(_:timeout:pollInterval:)` for an operation in hand;
    /// nil has nothing to wait on.
    public func waitForAdmission(
        _ operation: OperationResource?,
        timeout: TimeInterval = defaultAdmissionTimeout,
        pollInterval: TimeInterval = defaultOperationPollInterval
    ) async throws {
        try await waitForAdmission(
            operationId: operation?.id, selfLink: operation?.links["self"] ?? nil, timeout: timeout,
            pollInterval: pollInterval)
    }

    private func waitForAdmission(
        operationId: String?,
        selfLink: String?,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async throws {
        guard timeout.isFinite, timeout >= 0, timeout <= Double(Int32.max) / 1000,
              pollInterval.isFinite, pollInterval > 0, pollInterval <= Double(Int32.max) / 1000 else {
            throw ThalovantApiError(message: "An admission wait needs a finite timeout and a positive poll interval.")
        }
        guard let operationId else { return }
        if let link = selfLink, link.contains("://"), originOf(link) != originOf(apiURL) {
            // The token goes to the API's own origin and nowhere else.
            throw ThalovantApiError(message: "The admission operation points outside the Thalovant API.")
        }
        let path = "/v1/operations/\(encodePathComponent(operationId))"
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let timedOut = ThalovantAdmissionTimeoutError(
            "The hub did not admit the connection within \(wholeSeconds(timeout))s; it may still admit it later.",
            timeout: timeout
        )
        while true {
            try Task.checkCancellation()
            var wait = pollInterval
            do {
                // Every read is bounded by what is left of the wait: a read the
                // API is slow to answer must not carry the wait past it. Read
                // as JSON rather than decoded, so a status this SDK does not
                // know yet keeps the wait going instead of failing it.
                let left = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                guard let current = try await firstWithin(left, { try await self.requestObject("GET", path) }) else {
                    throw timedOut
                }
                switch current["status"]?.stringValue {
                case OperationStatus.ready.rawValue:
                    return
                case OperationStatus.failed.rawValue, OperationStatus.timedOut.rawValue:
                    let status = current["status"]?.stringValue ?? ""
                    let code = current["error_code"]?.stringValue
                    let said = current["error_message"]?.stringValue ?? code ?? "no detail"
                    throw ThalovantAdmissionFailedError(
                        "The hub could not admit the connection: operation \(operationId) ended \(status): \(said)",
                        errorCode: code
                    )
                default:
                    break
                }
            } catch let error as ThalovantApiError {
                switch error.statusCode {
                case 404?:
                    return
                case 429?:
                    wait = max(pollInterval, error.retryAfterSeconds ?? 0)
                    // The API asks for longer than is left: waiting it out
                    // would only end in the same timeout, later.
                    if wait > deadline - ProcessInfo.processInfo.systemUptime { throw timedOut }
                case let status? where status >= 500:
                    break
                case 401?, 403?:
                    // The token, not the connection: signing in again fixes it.
                    throw error
                default:
                    // Out of reach is not a failed admission: the connection
                    // may be admitted already.
                    if error.kind == .unreachable { throw error }
                    throw ThalovantAdmissionFailedError(
                        "The hub could not admit the connection: \(error.message)", apiError: error)
                }
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { throw timedOut }
            try await sleepAtLeast(min(wait, remaining))
        }
    }
}

/// A URL's origin: its scheme, host and port, the scheme's default port
/// spelled out, so `https://h` and `https://h:443` are one origin and
/// `http://h` and `https://h` are two. Nil for a URL without a scheme and host.
func originOf(_ url: String) -> String? {
    guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(),
          let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
    let port = parts.port ?? ["http": 80, "https": 443, "ws": 80, "wss": 443][scheme]
    return "\(scheme)://\(host):\(port.map(String.init) ?? "")"
}

/// `operation`'s result, or nil when `seconds` pass first. The operation is
/// cancelled then; one that does not stop at once still cannot hold the
/// caller, whose wait ends at the deadline.
func firstWithin<T: Sendable>(
    _ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T? {
    let finished = AsyncGate()
    let outcome = RaceOutcome<T>()
    let work = Task {
        do { outcome.keep(.success(try await operation())) } catch { outcome.keep(.failure(error)) }
        finished.open()
    }
    do {
        try await finished.wait(timeout: seconds, timeoutError: RaceTimedOut())
    } catch is RaceTimedOut {
        work.cancel()
        return nil
    } catch {
        work.cancel()
        throw error
    }
    switch outcome.value {
    case .success(let value)?: return value
    case .failure(let error)?: throw error
    case nil: return nil
    }
}

struct RaceTimedOut: Error {}

final class RaceOutcome<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?
    var value: Result<T, Error>? { lock.locked { stored } }
    func keep(_ result: Result<T, Error>) { lock.locked { if stored == nil { stored = result } } }
}

/// Sleeps the whole of `seconds` on the monotonic clock, never less: a timer
/// can wake a little early, and a wait the API asked for must not end before
/// it is up.
func sleepAtLeast(_ seconds: TimeInterval) async throws {
    let end = ProcessInfo.processInfo.systemUptime + seconds
    while true {
        let left = end - ProcessInfo.processInfo.systemUptime
        if left <= 0 { return }
        try await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000) + 1)
    }
}

/// Seconds as a person reads them: `180`, not `180.0`.
func wholeSeconds(_ seconds: TimeInterval) -> String {
    seconds == seconds.rounded() && abs(seconds) < 1e15 ? String(Int64(seconds)) : String(seconds)
}
