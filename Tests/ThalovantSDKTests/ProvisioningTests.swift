import Foundation
import XCTest

@testable import ThalovantSDK

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Covers the hub-provisioning and skill-discovery surface: paths, verbs,
/// body/param mapping, the `If-Match` and `Idempotency-Key` headers, which
/// optional fields are omitted rather than sent null, and the error statuses
/// the API uses for these routes (402 paid-plan, 403 scopes, 409 conflicts,
/// 412 optimistic locking).
final class ProvisioningTests: XCTestCase {
    private var api: ThalovantControlPlane!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        api = ThalovantControlPlane(
            apiURL: "https://api.example.com",
            accessToken: "token",
            session: StubURLProtocol.makeSession()
        )
    }

    private func lastRequest(file: StaticString = #filePath, line: UInt = #line) throws -> StubURLProtocol.RecordedRequest {
        try XCTUnwrap(StubURLProtocol.requests.last, file: file, line: line)
    }

    // MARK: Hubs

    func testCreateHubSendsIdempotencyKeyAndSnakeCasesPayload() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"id": "hub-1"}"#))
        let hub = try await api.createHub(
            [
                "name": "joke-garden",
                "runtimeGroupId": .string("group-1"),
                "capacityProfile": "small",
                "ownerId": "owner-1",
                "spec": .object(["protocols": .object(["wss": .object(["enabled": .bool(true)])])]),
            ],
            idempotencyKey: "fixed-key"
        )
        XCTAssertEqual(hub["id"]?.stringValue, "hub-1")

        let request = try lastRequest()
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/hubs")
        XCTAssertEqual(request.header("Idempotency-Key"), "fixed-key")
        XCTAssertEqual(request.header("Authorization"), "Bearer token")
        XCTAssertNil(request.header("If-Match"), "create takes no If-Match")

        let body = try XCTUnwrap(request.bodyObject())
        XCTAssertEqual(body["name"]?.stringValue, "joke-garden")
        XCTAssertEqual(body["runtime_group_id"]?.stringValue, "group-1")
        XCTAssertEqual(body["capacity_profile"]?.stringValue, "small")
        XCTAssertEqual(body["owner_id"]?.stringValue, "owner-1")
        XCTAssertNotNil(body["spec"]?.objectValue)
        // camelCase keys are renamed, never sent alongside the snake_case form.
        XCTAssertNil(body["runtimeGroupId"])
        XCTAssertNil(body["capacityProfile"])
        XCTAssertNil(body["ownerId"])
    }

    func testCreateHubGeneratesIdempotencyKeyWhenOmitted() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"id": "hub-1"}"#))
        _ = try await api.createHub(["name": "a"])
        let first = try XCTUnwrap(try lastRequest().header("Idempotency-Key"))
        XCTAssertFalse(first.isEmpty)

        StubURLProtocol.enqueue(.init(body: #"{"id": "hub-2"}"#))
        _ = try await api.createHub(["name": "b"])
        let second = try XCTUnwrap(try lastRequest().header("Idempotency-Key"))
        XCTAssertNotEqual(first, second, "each create gets its own generated key")
    }

    func testCreateHubOnFreePlanSurfaces402() async {
        StubURLProtocol.enqueue(.init(
            status: 402,
            body: #"{"detail": {"code": "paid_plan_required", "message": "API access requires a paid plan."}}"#
        ))
        do {
            _ = try await api.createHub(["name": "joke-garden"])
            XCTFail("expected ThalovantApiError")
        } catch let error as ThalovantApiError {
            XCTAssertEqual(error.statusCode, 402)
            XCTAssertEqual(error.errorCode, "paid_plan_required")
            XCTAssertTrue(try XCTUnwrap(error.body).contains("paid plan"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCreateHubWithoutScopeSurfaces403() async {
        StubURLProtocol.enqueue(.init(
            status: 403,
            body: #"{"detail": {"code": "insufficient_scope", "message": "Insufficient scopes"}}"#
        ))
        do {
            _ = try await api.createHub(["name": "joke-garden"])
            XCTFail("expected ThalovantApiError")
        } catch let error as ThalovantApiError {
            XCTAssertEqual(error.statusCode, 403)
            XCTAssertEqual(error.errorCode, "insufficient_scope")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUpdateHubSendsIfMatchAndPatches() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"id": "hub-1", "active": false}"#))
        _ = try await api.updateHub("hub-1", ["active": false, "isLocked": true], etag: "W/\"3\"")

        let request = try lastRequest()
        XCTAssertEqual(request.method, "PATCH")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/hubs/hub-1")
        XCTAssertEqual(request.header("If-Match"), "W/\"3\"")
        XCTAssertNil(request.header("Idempotency-Key"), "update is not idempotency-keyed")

        let body = try XCTUnwrap(request.bodyObject())
        XCTAssertEqual(body["active"]?.boolValue, false)
        XCTAssertEqual(body["is_locked"]?.boolValue, true)
        XCTAssertNil(body["isLocked"])
    }

    func testUpdateHubStaleEtagSurfaces412() async {
        StubURLProtocol.enqueue(.init(
            status: 412,
            body: #"{"detail": {"code": "precondition_failed", "message": "ETag mismatch"}}"#
        ))
        do {
            _ = try await api.updateHub("hub-1", ["active": false], etag: "W/\"stale\"")
            XCTFail("expected ThalovantApiError")
        } catch let error as ThalovantApiError {
            XCTAssertEqual(error.statusCode, 412)
            XCTAssertEqual(error.errorCode, "precondition_failed")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDeleteHubSendsIfMatchAndNoBody() async throws {
        StubURLProtocol.enqueue(.init(status: 204, body: ""))
        try await api.deleteHub("hub-1", etag: "W/\"7\"")

        let request = try lastRequest()
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/hubs/hub-1")
        XCTAssertEqual(request.header("If-Match"), "W/\"7\"")
        XCTAssertNil(request.header("Content-Type"))
        XCTAssertNil(request.body)
    }

    func testDeleteHubStaleEtagSurfaces412() async {
        StubURLProtocol.enqueue(.init(status: 412, body: #"{"detail": "ETag mismatch"}"#))
        do {
            try await api.deleteHub("hub-1", etag: "W/\"stale\"")
            XCTFail("expected ThalovantApiError")
        } catch let error as ThalovantApiError {
            XCTAssertEqual(error.statusCode, 412)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testReleaseHubOmitsUnsetOptions() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"id": "hub-1"}"#))
        _ = try await api.releaseHub("hub-1", ReleaseOptions(channel: "stable"))

        var request = try lastRequest()
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/hubs/hub-1/release")
        var body = try XCTUnwrap(request.bodyObject())
        XCTAssertEqual(body["channel"]?.stringValue, "stable")
        XCTAssertNil(body["mode"])
        XCTAssertNil(body["version"])
        XCTAssertNil(body["images"])
        XCTAssertNil(body["reason"])

        StubURLProtocol.enqueue(.init(body: #"{"id": "hub-1"}"#))
        _ = try await api.releaseHub("hub-1", ReleaseOptions(
            mode: "custom",
            version: "2026.8.1",
            images: ["core": "ghcr.io/thalovant/core:2026.8.1"],
            reason: "pin for audit"
        ))
        request = try lastRequest()
        body = try XCTUnwrap(request.bodyObject())
        XCTAssertNil(body["channel"])
        XCTAssertEqual(body["mode"]?.stringValue, "custom")
        XCTAssertEqual(body["version"]?.stringValue, "2026.8.1")
        XCTAssertEqual(body["images"]?["core"]?.stringValue, "ghcr.io/thalovant/core:2026.8.1")
        XCTAssertEqual(body["reason"]?.stringValue, "pin for audit")
    }

    func testReleaseHubWithNoOptionsSendsEmptyBody() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"id": "hub-1"}"#))
        _ = try await api.releaseHub("hub-1")
        let body = try XCTUnwrap(try lastRequest().bodyObject())
        XCTAssertTrue(body.isEmpty)
    }

    func testHubRatingSetAndClear() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"id": "hub-1", "rating": 4}"#))
        _ = try await api.setHubRating("hub-1", rating: 4)
        var request = try lastRequest()
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/hubs/hub-1/rating")
        XCTAssertEqual(try XCTUnwrap(request.bodyObject())["rating"]?.intValue, 4)

        StubURLProtocol.enqueue(.init(body: #"{"id": "hub-1"}"#))
        _ = try await api.clearHubRating("hub-1")
        request = try lastRequest()
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/hubs/hub-1/rating")
        XCTAssertNil(request.body)
    }

    func testGetHubRuntimeCapabilitiesAnd409WhenNothingConnected() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"counts": {"total_intents": 12}}"#))
        let capabilities = try await api.getHubRuntimeCapabilities("hub-1")
        XCTAssertEqual(capabilities["counts"]?["total_intents"]?.intValue, 12)
        XCTAssertEqual(
            try lastRequest().url.absoluteString,
            "https://api.example.com/v1/hubs/hub-1/runtime-capabilities"
        )

        StubURLProtocol.enqueue(.init(
            status: 409,
            body: #"{"detail": {"code": "no_connected_client", "message": "No connected client can report inventory."}}"#
        ))
        do {
            _ = try await api.getHubRuntimeCapabilities("hub-1")
            XCTFail("expected ThalovantApiError")
        } catch let error as ThalovantApiError {
            XCTAssertEqual(error.statusCode, 409)
            XCTAssertEqual(error.errorCode, "no_connected_client")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: Runtime groups

    func testListRuntimeGroupsOmitsOwnerIdByDefault() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"data": []}"#))
        _ = try await api.listRuntimeGroups()
        XCTAssertEqual(try lastRequest().url.absoluteString, "https://api.example.com/v1/runtime-groups")

        StubURLProtocol.enqueue(.init(body: #"{"data": []}"#))
        _ = try await api.listRuntimeGroups(ownerId: "owner-1")
        XCTAssertEqual(
            try lastRequest().url.absoluteString,
            "https://api.example.com/v1/runtime-groups?owner_id=owner-1"
        )
    }

    func testGetRuntimeGroupPath() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"id": "group-1"}"#))
        _ = try await api.getRuntimeGroup("group-1")
        let request = try lastRequest()
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/runtime-groups/group-1")
    }

    func testCreateRuntimeGroupSnakeCasesAndSendsNoIdempotencyKey() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"id": "group-1"}"#))
        _ = try await api.createRuntimeGroup([
            "name": "kiosks",
            "description": "Lobby kiosks",
            "cloneFromDefault": true,
            "ownerId": "owner-1",
        ])

        let request = try lastRequest()
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/runtime-groups")
        XCTAssertNil(request.header("Idempotency-Key"), "runtime-group routes read no idempotency header")
        XCTAssertNil(request.header("If-Match"), "runtime-group routes read no If-Match")

        let body = try XCTUnwrap(request.bodyObject())
        XCTAssertEqual(body["name"]?.stringValue, "kiosks")
        XCTAssertEqual(body["description"]?.stringValue, "Lobby kiosks")
        XCTAssertEqual(body["clone_from_default"]?.boolValue, true)
        XCTAssertEqual(body["owner_id"]?.stringValue, "owner-1")
        XCTAssertNil(body["cloneFromDefault"])
        XCTAssertNil(body["ownerId"])
    }

    func testUpdateRuntimeGroupSendsNoIfMatch() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"id": "group-1"}"#))
        _ = try await api.updateRuntimeGroup("group-1", [
            "name": "kiosks-v2",
            "spec": .object(["replicas": .integer(3)]),
        ])

        let request = try lastRequest()
        XCTAssertEqual(request.method, "PATCH")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/runtime-groups/group-1")
        XCTAssertNil(request.header("If-Match"))
        let body = try XCTUnwrap(request.bodyObject())
        XCTAssertEqual(body["name"]?.stringValue, "kiosks-v2")
        XCTAssertEqual(body["spec"]?["replicas"]?.intValue, 3)
    }

    func testRuntimeGroupConfigGetAndMergePatch() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"config": {"lang": "en-us"}}"#))
        let config = try await api.getRuntimeGroupConfig("group-1")
        XCTAssertEqual(config["config"]?["lang"]?.stringValue, "en-us")
        var request = try lastRequest()
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/runtime-groups/group-1/config")

        StubURLProtocol.enqueue(.init(body: #"{"config": {"lang": "fr-ca"}}"#))
        _ = try await api.updateRuntimeGroupConfig("group-1", config: ["lang": "fr-ca"])
        request = try lastRequest()
        XCTAssertEqual(request.method, "PATCH")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/runtime-groups/group-1/config")
        var body = try XCTUnwrap(request.bodyObject())
        XCTAssertEqual(body["config"]?["lang"]?.stringValue, "fr-ca")
        XCTAssertNil(body["personas"], "personas is omitted unless provided")

        StubURLProtocol.enqueue(.init(body: #"{"config": {}}"#))
        _ = try await api.updateRuntimeGroupConfig(
            "group-1",
            config: ["lang": "fr-ca"],
            personas: ["default": .object(["name": .string("Ada")])]
        )
        body = try XCTUnwrap(try lastRequest().bodyObject())
        XCTAssertEqual(body["personas"]?["default"]?["name"]?.stringValue, "Ada")
    }

    func testUpdateRuntimeGroupConfigSendsEmptyPersonasWhenGiven() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"config": {}}"#))
        _ = try await api.updateRuntimeGroupConfig("group-1", config: [:], personas: [:])
        let body = try XCTUnwrap(try lastRequest().bodyObject())
        XCTAssertEqual(body["personas"], .object([:]), "an explicit empty personas map clears them")
        XCTAssertEqual(body["config"], .object([:]))
    }

    func testReleaseRuntimeGroupPathAndBody() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"id": "group-1"}"#))
        _ = try await api.releaseRuntimeGroup("group-1", ReleaseOptions(channel: "stable", reason: "weekly roll"))
        let request = try lastRequest()
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/runtime-groups/group-1/release")
        let body = try XCTUnwrap(request.bodyObject())
        XCTAssertEqual(body["channel"]?.stringValue, "stable")
        XCTAssertEqual(body["reason"]?.stringValue, "weekly roll")
        XCTAssertNil(body["images"])
    }

    func testDeleteRuntimeGroupAnd409ForDefaultOrAttached() async throws {
        StubURLProtocol.enqueue(.init(status: 204, body: ""))
        try await api.deleteRuntimeGroup("group-1")
        let request = try lastRequest()
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/runtime-groups/group-1")
        XCTAssertNil(request.header("If-Match"))

        StubURLProtocol.enqueue(.init(
            status: 409,
            body: #"{"detail": {"code": "runtime_group_in_use", "message": "Runtime group still has hubs attached."}}"#
        ))
        do {
            try await api.deleteRuntimeGroup("group-1")
            XCTFail("expected ThalovantApiError")
        } catch let error as ThalovantApiError {
            XCTAssertEqual(error.statusCode, 409)
            XCTAssertEqual(error.errorCode, "runtime_group_in_use")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: Skills

    func testInstallRuntimeGroupSkillDefaults() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"skill_id": "skill-weather"}"#))
        _ = try await api.installRuntimeGroupSkill("group-1", skillId: "skill-weather")

        let request = try lastRequest()
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/runtime-groups/group-1/skills")
        let body = try XCTUnwrap(request.bodyObject())
        XCTAssertEqual(body["skill_id"]?.stringValue, "skill-weather")
        XCTAssertEqual(body["source_type"]?.stringValue, "catalog")
        XCTAssertEqual(body["active"]?.boolValue, true)
        XCTAssertNil(body["marketplace_skill_id"])
        XCTAssertNil(body["source_ref"])
        XCTAssertNil(body["version_pin"])
    }

    func testInstallRuntimeGroupSkillWithEveryOption() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"skill_id": "skill-custom"}"#))
        _ = try await api.installRuntimeGroupSkill(
            "group-1",
            skillId: "skill-custom",
            options: InstallRuntimeGroupSkillOptions(
                marketplaceSkillId: "catalog-42",
                sourceType: "git",
                sourceRef: "https://github.com/example/skill-custom",
                versionPin: "1.2.3",
                active: false
            )
        )
        let body = try XCTUnwrap(try lastRequest().bodyObject())
        XCTAssertEqual(body["skill_id"]?.stringValue, "skill-custom")
        XCTAssertEqual(body["marketplace_skill_id"]?.stringValue, "catalog-42")
        XCTAssertEqual(body["source_type"]?.stringValue, "git")
        XCTAssertEqual(body["source_ref"]?.stringValue, "https://github.com/example/skill-custom")
        XCTAssertEqual(body["version_pin"]?.stringValue, "1.2.3")
        XCTAssertEqual(body["active"]?.boolValue, false)
    }

    func testInstallRuntimeGroupSkillOnFreePlanSurfaces402() async {
        StubURLProtocol.enqueue(.init(
            status: 402,
            body: #"{"detail": {"code": "paid_plan_required", "message": "API access requires a paid plan."}}"#
        ))
        do {
            _ = try await api.installRuntimeGroupSkill("group-1", skillId: "skill-weather")
            XCTFail("expected ThalovantApiError")
        } catch let error as ThalovantApiError {
            XCTAssertEqual(error.statusCode, 402)
            XCTAssertEqual(error.errorCode, "paid_plan_required")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUninstallRuntimeGroupSkillEncodesBothPathComponents() async throws {
        StubURLProtocol.enqueue(.init(status: 204, body: ""))
        try await api.uninstallRuntimeGroupSkill("group-1", skillId: "skill/weather")
        let request = try lastRequest()
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(
            request.url.absoluteString,
            "https://api.example.com/v1/runtime-groups/group-1/skills/skill%2Fweather"
        )
        XCTAssertNil(request.body)
    }

    // MARK: Discovery

    func testListMarketplaceSkillsDefaultsHaveNoQuery() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"data": [{"skill_id": "skill-weather"}]}"#))
        let catalog = try await api.listMarketplaceSkills()
        XCTAssertEqual(catalog["data"]?[0]?["skill_id"]?.stringValue, "skill-weather")
        XCTAssertEqual(try lastRequest().url.absoluteString, "https://api.example.com/v1/marketplace/skills")
    }

    func testListMarketplaceSkillsSendsAdminOnlyFiltersWhenSet() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"data": []}"#))
        _ = try await api.listMarketplaceSkills(MarketplaceSkillListOptions(
            ownerId: "owner-1",
            includeInactive: true,
            forceRefresh: true
        ))
        XCTAssertEqual(
            try lastRequest().url.absoluteString,
            "https://api.example.com/v1/marketplace/skills?owner_id=owner-1&include_inactive=true&force_refresh=true"
        )
    }

    func testListMarketplaceSkillsOmitsFalseFlags() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"data": []}"#))
        _ = try await api.listMarketplaceSkills(MarketplaceSkillListOptions(forceRefresh: true))
        let url = try lastRequest().url.absoluteString
        XCTAssertEqual(url, "https://api.example.com/v1/marketplace/skills?force_refresh=true")
        XCTAssertFalse(url.contains("include_inactive"))
        XCTAssertFalse(url.contains("owner_id"))
    }

    func testListRuntimeGroupMarketplaceRefreshFlag() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"data": [], "source": "runtime-group-cache"}"#))
        _ = try await api.listRuntimeGroupMarketplace("group-1")
        XCTAssertEqual(
            try lastRequest().url.absoluteString,
            "https://api.example.com/v1/runtime-groups/group-1/marketplace"
        )

        StubURLProtocol.enqueue(.init(body: #"{"data": []}"#))
        _ = try await api.listRuntimeGroupMarketplace("group-1", refreshInventory: true)
        XCTAssertEqual(
            try lastRequest().url.absoluteString,
            "https://api.example.com/v1/runtime-groups/group-1/marketplace?refresh_inventory=true"
        )
    }

    func testListRuntimeGroupInventoryRefreshFlagAndPendingSource() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"data": [], "source": "ovos-runtime-operator-pending"}"#))
        let inventory = try await api.listRuntimeGroupInventory("group-1")
        // Nothing connected is not an error on this route: empty data, pending source.
        XCTAssertEqual(inventory["data"]?.arrayValue?.count, 0)
        XCTAssertEqual(inventory["source"]?.stringValue, "ovos-runtime-operator-pending")
        XCTAssertEqual(
            try lastRequest().url.absoluteString,
            "https://api.example.com/v1/runtime-groups/group-1/inventory"
        )

        StubURLProtocol.enqueue(.init(body: #"{"data": [], "source": "ovos-runtime-operator"}"#))
        _ = try await api.listRuntimeGroupInventory("group-1", refresh: true)
        XCTAssertEqual(
            try lastRequest().url.absoluteString,
            "https://api.example.com/v1/runtime-groups/group-1/inventory?refresh=true"
        )
    }

    func testRuntimeGroupMarketplace403WhenNotOwner() async {
        StubURLProtocol.enqueue(.init(
            status: 403,
            body: #"{"detail": {"code": "forbidden", "message": "Not your runtime group."}}"#
        ))
        do {
            _ = try await api.listRuntimeGroupMarketplace("group-other")
            XCTFail("expected ThalovantApiError")
        } catch let error as ThalovantApiError {
            XCTAssertEqual(error.statusCode, 403)
            XCTAssertEqual(error.errorCode, "forbidden")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: Auth plumbing

    func testProvisioningRoutesRequireAnAccessToken() async {
        let anonymous = ThalovantControlPlane(
            apiURL: "https://api.example.com",
            session: StubURLProtocol.makeSession()
        )
        do {
            _ = try await anonymous.listMarketplaceSkills()
            XCTFail("expected ThalovantApiError")
        } catch {
            XCTAssertTrue(error is ThalovantApiError)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "no request is sent without a token")
    }

    // MARK: Payload helper

    func testSnakeCasePayloadRenamesInPlaceAndCamelWins() {
        let renamed = hubPayload([
            "name": "hub",
            "ownerId": "camel",
            "owner_id": "snake",
        ])
        XCTAssertEqual(renamed["owner_id"]?.stringValue, "camel")
        XCTAssertNil(renamed["ownerId"])
        XCTAssertEqual(renamed["name"]?.stringValue, "hub")

        let untouched = runtimeGroupPayload(["name": "kiosks", "environment": "prod"])
        XCTAssertEqual(untouched.count, 2)
        XCTAssertEqual(untouched["environment"]?.stringValue, "prod")
    }
}
