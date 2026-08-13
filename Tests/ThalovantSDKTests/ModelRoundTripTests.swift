import Foundation
import XCTest

@testable import ThalovantSDK

/// JSON round-trips for every typed model against fixture JSON copied from
/// the API pydantic schemas: decode -> encode -> decode must be lossless.
final class ModelRoundTripTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ json: String) throws -> T {
        let decoded = try JSONDecoder().decode(type, from: Data(json.utf8))
        let encoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(type, from: encoded)
        XCTAssertEqual(decoded, redecoded)
        return decoded
    }

    func testOperationResourceRoundTrip() throws {
        let operation = try roundTrip(OperationResource.self, Fixtures.operation)
        XCTAssertEqual(operation.id, "0b849a6c-3d3f-49a5-9f10-8f4dbb2f3d10")
        XCTAssertEqual(operation.kind, "hub.release")
        XCTAssertEqual(operation.aggregateType, "hub")
        XCTAssertEqual(operation.aggregateId, "b3b1f5a0-91b8-4a71-a2e5-53422dd0f841")
        XCTAssertEqual(operation.status, .timedOut)
        XCTAssertEqual(operation.details["attempt"]?.intValue, 3)
        XCTAssertEqual(operation.details["region"]?.stringValue, "ca-central-1")
        XCTAssertEqual(operation.details["dry_run"]?.boolValue, false)
        XCTAssertEqual(operation.gitCommitSha, "0f4f9c8f2a1b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")
        XCTAssertEqual(operation.errorCode, "reconcile_timeout")
        XCTAssertEqual(operation.errorMessage, "The hub did not reach Ready within the deadline.")
        XCTAssertEqual(operation.createdAt, "2026-08-12T15:04:05Z")
        XCTAssertEqual(operation.updatedAt, "2026-08-12T15:24:05Z")
        XCTAssertEqual(operation.committedAt, "2026-08-12T15:05:00Z")
        XCTAssertEqual(operation.appliedAt, "2026-08-12T15:06:00Z")
        XCTAssertNil(operation.readyAt)
        XCTAssertEqual(operation.terminalAt, "2026-08-12T15:24:05Z")
        XCTAssertEqual(operation.links["self"], "/v1/operations/operation-1")
        XCTAssertEqual(operation.links["aggregate"], .some(nil))
    }

    func testOperationResourceEncodesSnakeCaseFields() throws {
        let operation = try JSONDecoder().decode(OperationResource.self, from: Data(Fixtures.operation.utf8))
        let encoded = String(decoding: try JSONEncoder().encode(operation), as: UTF8.self)
        for field in [
            "aggregate_type", "aggregate_id", "git_commit_sha", "error_code", "error_message",
            "created_at", "updated_at", "committed_at", "applied_at", "terminal_at",
        ] {
            XCTAssertTrue(encoded.contains("\"\(field)\""), "expected \(field) in \(encoded)")
        }
    }

    func testPendingOperationNullFields() throws {
        let operation = try roundTrip(OperationResource.self, Fixtures.operationPending)
        XCTAssertEqual(operation.status, .requested)
        XCTAssertNil(operation.aggregateId)
        XCTAssertNil(operation.gitCommitSha)
        XCTAssertNil(operation.errorCode)
        XCTAssertNil(operation.committedAt)
        XCTAssertNil(operation.terminalAt)
        XCTAssertTrue(operation.details.isEmpty)
        XCTAssertEqual(operation.links["self"], "/v1/operations/operation-1")
    }

    func testOperationStatusRawValues() {
        XCTAssertEqual(OperationStatus.requested.rawValue, "requested")
        XCTAssertEqual(OperationStatus.committed.rawValue, "committed")
        XCTAssertEqual(OperationStatus.applied.rawValue, "applied")
        XCTAssertEqual(OperationStatus.ready.rawValue, "ready")
        XCTAssertEqual(OperationStatus.failed.rawValue, "failed")
        XCTAssertEqual(OperationStatus.timedOut.rawValue, "timed_out")
    }

    func testMemoryItemRoundTrip() throws {
        let item = try roundTrip(MemoryItemResource.self, Fixtures.memoryItem)
        XCTAssertEqual(item.scope, .workspace)
        XCTAssertEqual(item.kind, .preference)
        XCTAssertEqual(item.title, "Timezone")
        XCTAssertEqual(item.content, "Prefer America/Toronto for scheduling.")
        XCTAssertEqual(item.tags, ["timezone", "scheduling"])
        XCTAssertEqual(item.metadata["pinned"]?.boolValue, true)
        XCTAssertEqual(item.consentScope, "daily_desk_memory")
        XCTAssertNil(item.consentVersion)
        XCTAssertEqual(item.retentionPolicy, "user_controlled")
        XCTAssertNil(item.hubId)
        XCTAssertNil(item.expiresAt)
        XCTAssertNil(item.deletedAt)
    }

    func testMemoryListRoundTrip() throws {
        let list = try roundTrip(MemoryListResponse.self, Fixtures.memoryList)
        XCTAssertEqual(list.data.count, 1)
        XCTAssertEqual(list.meta.count, 1)
        XCTAssertNil(list.meta.next)
        XCTAssertEqual(list.meta.extra?["total"]?.intValue, 1)
        XCTAssertEqual(list.links["self"], "/v1/memory?limit=50")
        XCTAssertEqual(list.links["next"], .some(nil))
    }

    func testMemorySummaryRoundTrip() throws {
        let summary = try roundTrip(MemorySummaryResponse.self, Fixtures.memorySummary)
        XCTAssertEqual(summary.total, 12)
        XCTAssertEqual(summary.byScope["workspace"], 8)
        XCTAssertEqual(summary.byKind["preference"], 5)
        XCTAssertEqual(summary.expired, 1)
        XCTAssertEqual(summary.deleted, 2)
    }

    func testJSONValueRoundTrip() throws {
        let json = """
        {"a": null, "b": true, "c": 42, "d": 4.5, "e": "text", "f": [1, "two", null], "g": {"nested": false}}
        """
        let decoded = try ThalovantJSON.decodeObject(json)
        let encoded = try ThalovantJSON.encodeToString(decoded)
        let redecoded = try ThalovantJSON.decodeObject(encoded)
        XCTAssertEqual(decoded, redecoded)
        XCTAssertEqual(decoded["a"], .null)
        XCTAssertEqual(decoded["b"]?.boolValue, true)
        XCTAssertEqual(decoded["c"]?.intValue, 42)
        XCTAssertEqual(decoded["d"]?.doubleValue, 4.5)
        XCTAssertEqual(decoded["e"]?.stringValue, "text")
        XCTAssertEqual(decoded["f"]?[1]?.stringValue, "two")
        XCTAssertEqual(decoded["g"]?["nested"]?.boolValue, false)
    }

    func testIdentityFromInitialIdentify() throws {
        let identity = try ThalovantIdentity(json: try ThalovantJSON.decodeObject(Fixtures.clientIdentify))
        XCTAssertEqual(identity.accessKey, "identity-access-key")
        XCTAssertEqual(identity.password, "identity-password")
        XCTAssertEqual(identity.cryptoKey, "0123456789abcdefextra")
        XCTAssertEqual(identity.siteId, "swift-demo-client")
        XCTAssertEqual(identity.defaultPort, 443)
        XCTAssertEqual(identity.defaultMaster, "https://hub-1.hubs.thalovant.com")
        let mqtt = try XCTUnwrap(identity.mqtt)
        XCTAssertEqual(mqtt.endpoint, "mqtts://mqtt.hub-1.hubs.thalovant.com:8883")
        XCTAssertEqual(mqtt.username, "mqtt-user")
        XCTAssertEqual(mqtt.password, "mqtt-pass")
        XCTAssertEqual(mqtt.topicPrefix, "hivemind/hub-1")
        XCTAssertTrue(mqtt.tls)
    }

    func testIdentityDefaultsAndAliases() throws {
        let identity = try ThalovantIdentity(json: [
            "api_key": "aliased-key",
            "password": "pw",
            "host": "wss://hub.example.com",
            "site": "site-1",
        ])
        XCTAssertEqual(identity.accessKey, "aliased-key")
        XCTAssertEqual(identity.defaultMaster, "wss://hub.example.com")
        XCTAssertEqual(identity.siteId, "site-1")
        XCTAssertEqual(identity.defaultPort, 5679)
        XCTAssertEqual(identity.defaultPath, "")
        // WSS default master is usable as the WSS endpoint.
        XCTAssertEqual(identity.endpointFor(.wss), "wss://hub.example.com")
        // Protocol defaults: wss enabled, http/mqtt disabled.
        XCTAssertEqual(identity.enabledProtocols(), [.wss])
    }

    func testIdentityMissingFieldThrows() {
        XCTAssertThrowsError(try ThalovantIdentity(json: ["password": "pw"])) { error in
            XCTAssertTrue(error is ThalovantIdentityError)
        }
    }

    func testIdentityAsJSONRedactsSecretsByDefault() throws {
        let identity = try ThalovantIdentity(json: try ThalovantJSON.decodeObject(Fixtures.clientIdentify))
        let redacted = identity.asJSON()
        XCTAssertNil(redacted["access_key"])
        XCTAssertNil(redacted["password"])
        XCTAssertNil(redacted["crypto_key"])
        XCTAssertNil(redacted["mqtt"]?["username"])
        let full = identity.asJSON(includeSecrets: true)
        XCTAssertEqual(full["access_key"]?.stringValue, "identity-access-key")
        XCTAssertEqual(full["mqtt"]?["password"]?.stringValue, "mqtt-pass")
    }

    func testIdentityFileLoadingEnforcesPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("thalovant-sdk-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("identity.json").path
        XCTAssertTrue(FileManager.default.createFile(
            atPath: path,
            contents: Data(Fixtures.clientIdentify.utf8),
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ))
        let identity = try ThalovantIdentity.fromFile(path)
        XCTAssertEqual(identity.siteId, "swift-demo-client")

        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: path)
        XCTAssertThrowsError(try ThalovantIdentity.fromFile(path)) { error in
            let message = (error as? ThalovantIdentityError)?.message ?? ""
            XCTAssertTrue(message.contains("too permissive"), message)
        }
    }

    func testApiErrorDecodesErrorCode() {
        let mfa = ThalovantApiError(
            message: "HTTP 401",
            statusCode: 401,
            body: #"{"detail": {"code": "mfa_required", "recovery_available": false}}"#
        )
        XCTAssertEqual(mfa.errorCode, "mfa_required")
        let topLevel = ThalovantApiError(message: "HTTP 409", statusCode: 409, body: #"{"code": "conflict"}"#)
        XCTAssertEqual(topLevel.errorCode, "conflict")
        let plain = ThalovantApiError(message: "HTTP 500", statusCode: 500, body: "boom")
        XCTAssertNil(plain.errorCode)
    }
}
