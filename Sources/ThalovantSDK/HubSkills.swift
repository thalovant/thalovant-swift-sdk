import Foundation

/// Optional waiting after a shared-runtime skill mutation. Durations are seconds.
public struct HubSkillWaitOptions: Sendable {
    public var wait: Bool
    public var timeout: TimeInterval
    public var pollInterval: TimeInterval
    public init(wait: Bool = false, timeout: TimeInterval = 120, pollInterval: TimeInterval = 2) {
        self.wait = wait; self.timeout = timeout; self.pollInterval = pollInterval
    }
    func validate() throws {
        guard timeout.isFinite, timeout > 0, pollInterval.isFinite, pollInterval > 0,
              pollInterval < Double(UInt64.max) / 1_000_000_000 else {
            throw ThalovantApiError(message: "Hub skill wait durations must be positive and finite; poll interval is too large.")
        }
    }
}
extension ThalovantControlPlane {
    private func hubSkillsPath(_ hubId: String) -> String { "/v1/hubs/\(encodePathComponent(hubId))/skills" }

    /// Read skills of the shared runtime behind this hub; requires hubs:inspect.
    public func listHubSkills(_ hubId: String) async throws -> JSONObject {
        try await requestObject("GET", hubSkillsPath(hubId))
    }
    /// Newest-first shared-runtime events and operations; limit is 1–200.
    public func listHubSkillHistory(_ hubId: String, limit: Int = 50) async throws -> JSONObject {
        guard (1...200).contains(limit) else { throw ThalovantApiError(message: "limit must be from 1 to 200") }
        return try await requestObject("GET", "\(hubSkillsPath(hubId))/history?limit=\(limit)")
    }
    /// Install on the shared runtime, affecting all its hubs. Requires hubs:write and a paid plan.
    public func installHubSkill(_ hubId: String, skill: String, version: String = "latest", options: HubSkillWaitOptions = HubSkillWaitOptions()) async throws -> JSONObject {
        try await changeHubSkill("POST", hubSkillsPath(hubId), body: ["skill": .string(skill), "version": .string(version)], options: options)
    }
    /// Move a shared-runtime skill to an exact version or latest.
    public func updateHubSkill(_ hubId: String, skill: String, version: String, options: HubSkillWaitOptions = HubSkillWaitOptions()) async throws -> JSONObject {
        try await changeHubSkill("PATCH", "\(hubSkillsPath(hubId))/\(encodePathComponent(skill))", body: ["version": .string(version)], options: options)
    }
    /// Remove the shared-runtime attachment, affecting all served hubs.
    public func removeHubSkill(_ hubId: String, skill: String, options: HubSkillWaitOptions = HubSkillWaitOptions()) async throws -> JSONObject {
        try await changeHubSkill("DELETE", "\(hubSkillsPath(hubId))/\(encodePathComponent(skill))", body: nil, options: options)
    }
    private func changeHubSkill(_ method: String, _ path: String, body: JSONObject?, options: HubSkillWaitOptions) async throws -> JSONObject {
        try options.validate()
        let accepted = try await requestObject(method, path, body: body)
        return options.wait ? try await waitForHubSkillOperation(accepted, options: options) : accepted
    }
    /// Resume without repeating a write. Retain the complete accepted response, including state, before waiting when cancellation is possible.
    public func waitForHubSkillOperation(_ accepted: JSONObject, options: HubSkillWaitOptions = HubSkillWaitOptions()) async throws -> JSONObject {
        try options.validate()
        guard let id = accepted["operation_id"]?.stringValue, !id.isEmpty else { throw ThalovantApiError(message: "Missing accepted operation_id.") }
        let state = accepted["state"]?.stringValue
        let converged = state == "removing" || state == "removed" ? "removed" : "installed"
        let started = ProcessInfo.processInfo.systemUptime
        while true {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - started < options.timeout else { throw ThalovantTimeoutError("Timed out waiting for accepted operation \(id)") }
            let operation: JSONObject
            do { operation = try await requestObject("GET", "/v1/operations/\(encodePathComponent(id))") }
            catch is CancellationError { throw CancellationError() }
            catch { if Task.isCancelled { throw CancellationError() }; throw ThalovantApiError(message: "Could not read accepted operation \(id); inspect the operation by ID, or resume with the complete accepted response.") }
            let status = operation["status"]?.stringValue
            if status == "ready" { var result = accepted; result["state"] = .string(converged); result["operation"] = .object(operation); return result }
            if status == "failed" || status == "timed_out" { throw ThalovantApiError(message: "Accepted operation \(id) failed; inspect getOperation for details.") }
            let remaining = options.timeout - (ProcessInfo.processInfo.systemUptime - started)
            guard remaining > 0 else { throw ThalovantTimeoutError("Timed out waiting for accepted operation \(id)") }
            try await Task.sleep(nanoseconds: UInt64(min(options.pollInterval, remaining) * 1_000_000_000))
        }
    }
}
