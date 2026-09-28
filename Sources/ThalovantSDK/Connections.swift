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
    var refusesConnectionType: Bool {
        guard statusCode == 422 else { return false }
        let text = problem.flatMap { try? ThalovantJSON.encodeToString($0) } ?? body ?? message
        return text.contains("connection_type") || text.contains("connectionType")
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
    /// longer tracks (HTTP 404). A 5xx while polling is ridden out.
    ///
    /// Throws `ThalovantAdmissionFailedError`, with the operation's
    /// `errorCode`, when the operation failed or the platform gave up on it;
    /// and `ThalovantAdmissionTimeoutError` when `timeout` passes first -- a
    /// connection error and a timeout at once, since the connection may still
    /// be admitted after that. An operation whose `links.self` points at
    /// another origin than the API's is never fetched: the token goes nowhere
    /// else. That, and any other refusal (a revoked token is `.auth`), throws
    /// the `ThalovantApiError` as it came.
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
        guard timeout.isFinite, timeout >= 0, pollInterval.isFinite, pollInterval > 0,
              pollInterval <= Double(Int32.max) / 1000 else {
            throw ThalovantApiError(message: "An admission wait needs a finite timeout and a positive poll interval.")
        }
        guard let operationId else { return }
        if let link = selfLink, !linksToThisAPI(link) {
            throw ThalovantApiError(message: "The admission operation points outside the Thalovant API.")
        }
        let path = "/v1/operations/\(encodePathComponent(operationId))"
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            try Task.checkCancellation()
            do {
                // Read as JSON rather than decoded: a status this SDK does not
                // know yet keeps the wait going instead of failing it.
                let current = try await requestObject("GET", path)
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
                if error.statusCode == 404 { return }
                guard let status = error.statusCode, status >= 500 else { throw error }
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                throw ThalovantAdmissionTimeoutError(
                    "The hub did not admit the connection within \(wholeSeconds(timeout))s; it may still.",
                    timeout: timeout
                )
            }
            try await Task.sleep(nanoseconds: UInt64(min(pollInterval, remaining) * 1_000_000_000))
        }
    }

    /// Whether an operation link stays on this API's origin. A relative link
    /// does by definition; an absolute one must name the same scheme, host and
    /// port.
    private func linksToThisAPI(_ link: String) -> Bool {
        let lowered = link.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return true }
        guard let target = URLComponents(string: link), let api = URLComponents(string: apiURL) else { return false }
        return target.scheme?.lowercased() == api.scheme?.lowercased()
            && target.host?.lowercased() == api.host?.lowercased()
            && target.port == api.port
            && target.user == nil && target.password == nil
    }
}

/// Seconds as a person reads them: `180`, not `180.0`.
func wholeSeconds(_ seconds: TimeInterval) -> String {
    seconds == seconds.rounded() && abs(seconds) < 1e15 ? String(Int64(seconds)) : String(seconds)
}
