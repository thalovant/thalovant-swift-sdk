import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Options for the release-apply routes (`POST /v1/hubs/{id}/release` and
/// `POST /v1/runtime-groups/{id}/release`).
///
/// Every field is optional; a field left unset is omitted from the body and
/// the API falls back to the workspace release policy. Passing `images`
/// switches the target to `custom` mode unless `mode` is also set.
public struct ReleaseOptions: Sendable {
    /// Release channel to track (for example `stable`).
    public var channel: String?
    /// Release mode: `managed`, `pinned`, or `custom`. The API switches to
    /// `custom` when `images` is sent without a `mode`.
    public var mode: String?
    /// Pinned release version.
    public var version: String?
    /// Explicit container image overrides, keyed by component.
    public var images: [String: String]?
    /// Free-form audit reason recorded with the release.
    public var reason: String?

    public init(
        channel: String? = nil,
        mode: String? = nil,
        version: String? = nil,
        images: [String: String]? = nil,
        reason: String? = nil
    ) {
        self.channel = channel
        self.mode = mode
        self.version = version
        self.images = images
        self.reason = reason
    }

    /// Builds the release-apply body, omitting every option left unset.
    func asJSON() -> JSONObject {
        var body: JSONObject = [:]
        if let channel { body["channel"] = .string(channel) }
        if let mode { body["mode"] = .string(mode) }
        if let version { body["version"] = .string(version) }
        if let images {
            body["images"] = .object(images.mapValues { JSONValue.string($0) })
        }
        if let reason { body["reason"] = .string(reason) }
        return body
    }
}

/// Filters for `GET /v1/marketplace/skills`.
///
/// `ownerId` and `includeInactive` are honored for admin tokens only; the API
/// silently scopes a non-admin caller to their own tenant and to active
/// entries rather than failing.
public struct MarketplaceSkillListOptions: Sendable {
    /// Read another tenant's catalog (admin tokens only).
    public var ownerId: String?
    /// Include retired catalog entries (admin tokens only).
    public var includeInactive: Bool
    /// Re-sync the global catalog from its source before answering. Slower.
    public var forceRefresh: Bool

    public init(
        ownerId: String? = nil,
        includeInactive: Bool = false,
        forceRefresh: Bool = false
    ) {
        self.ownerId = ownerId
        self.includeInactive = includeInactive
        self.forceRefresh = forceRefresh
    }
}

/// Options for `POST /v1/runtime-groups/{id}/skills`.
public struct InstallRuntimeGroupSkillOptions: Sendable {
    /// Catalog entry id, when it differs from the skill id.
    public var marketplaceSkillId: String?
    /// `catalog` (the default) installs a marketplace skill and requires the
    /// skill to exist in the catalog; `git` installs need a `sourceRef`.
    public var sourceType: String
    /// Repository URL for `git` installs.
    public var sourceRef: String?
    /// Pin the skill to one version instead of tracking the catalog.
    public var versionPin: String?
    /// Whether the skill should be loaded by the runtime.
    public var active: Bool

    public init(
        marketplaceSkillId: String? = nil,
        sourceType: String = "catalog",
        sourceRef: String? = nil,
        versionPin: String? = nil,
        active: Bool = true
    ) {
        self.marketplaceSkillId = marketplaceSkillId
        self.sourceType = sourceType
        self.sourceRef = sourceRef
        self.versionPin = versionPin
        self.active = active
    }
}

extension ThalovantControlPlane {

    // MARK: Hub provisioning

    /// `POST /v1/hubs`.
    ///
    /// `payload` mirrors the API's hub create body: `name` and `spec` are
    /// required, and `slug`, `namespace`, `runtime_group_id`, `domain`,
    /// `active`, `visibility`, `capacity_profile`, and `owner_id` are
    /// optional. camelCase keys are accepted and sent as snake_case.
    ///
    /// The request is idempotent: a generated `Idempotency-Key` is sent unless
    /// you pass your own, so a retried create returns the first hub instead of
    /// making a second one.
    ///
    /// Requires a paid plan and a token with the `hubs:write` scope; a
    /// free-plan token fails with HTTP 402.
    public func createHub(_ payload: JSONObject, idempotencyKey: String? = nil) async throws -> JSONObject {
        try await requestObject(
            "POST",
            "/v1/hubs",
            body: hubPayload(payload),
            headers: ["Idempotency-Key": idempotencyKey ?? newIdempotencyKey()]
        )
    }

    /// `PATCH /v1/hubs/{hubId}`.
    ///
    /// The API enforces optimistic locking on this route, so `etag` is
    /// required: pass the `etag` from the hub resource you read, which is sent
    /// as `If-Match`. A stale or missing value fails the request with HTTP 412
    /// and no change is made; re-read the hub with `getHub` and retry with the
    /// new `etag`. camelCase keys in `payload` are sent as snake_case.
    ///
    /// Requires a paid plan and a token with the `hubs:write` scope.
    public func updateHub(_ hubId: String, _ payload: JSONObject, etag: String) async throws -> JSONObject {
        try await requestObject(
            "PATCH",
            "/v1/hubs/\(encodePathComponent(hubId))",
            body: hubPayload(payload),
            headers: ["If-Match": etag]
        )
    }

    /// `DELETE /v1/hubs/{hubId}`, which also deletes the hub's clients and ACLs.
    ///
    /// Like `updateHub` this route requires the hub's current `etag`, sent as
    /// `If-Match`; a stale or missing value fails with HTTP 412.
    ///
    /// Requires a paid plan and a token with the `hubs:write` scope.
    public func deleteHub(_ hubId: String, etag: String) async throws {
        _ = try await requestData(
            "DELETE",
            "/v1/hubs/\(encodePathComponent(hubId))",
            headers: ["If-Match": etag]
        )
    }

    /// `POST /v1/hubs/{hubId}/release`: applies a hub release policy and
    /// returns the updated hub.
    ///
    /// Requires a paid plan and a token with the `hubs:write` scope.
    public func releaseHub(_ hubId: String, _ options: ReleaseOptions = ReleaseOptions()) async throws -> JSONObject {
        try await requestObject(
            "POST",
            "/v1/hubs/\(encodePathComponent(hubId))/release",
            body: options.asJSON()
        )
    }

    /// `PUT /v1/hubs/{hubId}/rating`: rates a public hub from 1 to 5 and
    /// returns the updated hub.
    ///
    /// Only public hubs can be rated, and owners cannot rate their own hubs;
    /// both fail with HTTP 400. A rating outside 1...5 fails with HTTP 422.
    ///
    /// Requires a token with the `hubs:write` scope; unlike the provisioning
    /// routes this one is **not** paid-gated, so free-plan callers can rate.
    public func setHubRating(_ hubId: String, rating: Int) async throws -> JSONObject {
        try await requestObject(
            "PUT",
            "/v1/hubs/\(encodePathComponent(hubId))/rating",
            body: ["rating": .integer(rating)]
        )
    }

    /// `DELETE /v1/hubs/{hubId}/rating`: removes the caller's rating from a
    /// public hub and returns the hub.
    ///
    /// Requires a token with the `hubs:write` scope; not paid-gated.
    public func clearHubRating(_ hubId: String) async throws -> JSONObject {
        try await requestObject("DELETE", "/v1/hubs/\(encodePathComponent(hubId))/rating")
    }

    /// `GET /v1/hubs/{hubId}/runtime-capabilities`: the live skill and intent
    /// inventory a hub runtime exposes.
    ///
    /// Requires a token with the `hubs:inspect` scope; not paid-gated.
    ///
    /// With no connected client the API falls back to the hub's runtime-group
    /// snapshot and answers HTTP 200 with `source` `ovos-runtime-unavailable`;
    /// it answers HTTP 409 only when there is no snapshot to fall back on (no
    /// runtime group, or no desired and no observed skills). This is the one
    /// route in this surface that can 409 for a quiet runtime --
    /// `listRuntimeGroupInventory` returns an empty list with a pending
    /// `source` instead. Inspecting a public hub you do not own additionally
    /// requires the `acls:write` scope.
    public func getHubRuntimeCapabilities(_ hubId: String) async throws -> JSONObject {
        try await requestObject("GET", "/v1/hubs/\(encodePathComponent(hubId))/runtime-capabilities")
    }

    // MARK: Runtime groups

    /// `GET /v1/runtime-groups`. Requires the `hubs:read` scope.
    public func listRuntimeGroups(ownerId: String? = nil) async throws -> JSONObject {
        var params: [(String, String)] = []
        appendParam(&params, "owner_id", ownerId)
        return try await requestObject("GET", pathWithQuery("/v1/runtime-groups", params))
    }

    /// `GET /v1/runtime-groups/{runtimeGroupId}`. Requires the `hubs:read` scope.
    public func getRuntimeGroup(_ runtimeGroupId: String) async throws -> JSONObject {
        try await requestObject("GET", "/v1/runtime-groups/\(encodePathComponent(runtimeGroupId))")
    }

    /// `POST /v1/runtime-groups`.
    ///
    /// `payload` takes the API's create body: `name` is required, and
    /// `description`, `environment`, `owner_id`, and `clone_from_default` are
    /// optional. camelCase keys are accepted and sent as snake_case. This
    /// route reads no `Idempotency-Key`.
    ///
    /// Requires a paid plan and a token with the `hubs:write` scope.
    public func createRuntimeGroup(_ payload: JSONObject) async throws -> JSONObject {
        try await requestObject("POST", "/v1/runtime-groups", body: runtimeGroupPayload(payload))
    }

    /// `PATCH /v1/runtime-groups/{runtimeGroupId}`: updates `name`,
    /// `description`, or `spec` (which patches `replicas` and container
    /// `resources`). This route does **not** use `If-Match`.
    ///
    /// Requires a paid plan and a token with the `hubs:write` scope.
    public func updateRuntimeGroup(_ runtimeGroupId: String, _ payload: JSONObject) async throws -> JSONObject {
        try await requestObject(
            "PATCH",
            "/v1/runtime-groups/\(encodePathComponent(runtimeGroupId))",
            body: runtimeGroupPayload(payload)
        )
    }

    /// `GET /v1/runtime-groups/{runtimeGroupId}/config`: the group's runtime
    /// configuration and personas. Requires the `hubs:read` scope.
    public func getRuntimeGroupConfig(_ runtimeGroupId: String) async throws -> JSONObject {
        try await requestObject("GET", "/v1/runtime-groups/\(encodePathComponent(runtimeGroupId))/config")
    }

    /// `PATCH /v1/runtime-groups/{runtimeGroupId}/config`.
    ///
    /// The API merges `config` into the stored configuration rather than
    /// replacing it, and marks the group pending so the runtime operator
    /// reconciles the change. `personas` is sent, and replaced, only when
    /// provided.
    ///
    /// Requires a paid plan and a token with the `hubs:write` scope.
    public func updateRuntimeGroupConfig(
        _ runtimeGroupId: String,
        config: JSONObject,
        personas: JSONObject? = nil
    ) async throws -> JSONObject {
        var body: JSONObject = ["config": .object(config)]
        if let personas {
            body["personas"] = .object(personas)
        }
        return try await requestObject(
            "PATCH",
            "/v1/runtime-groups/\(encodePathComponent(runtimeGroupId))/config",
            body: body
        )
    }

    /// `POST /v1/runtime-groups/{runtimeGroupId}/release`: applies a runtime
    /// image policy and returns the updated runtime group. Options behave like
    /// `releaseHub`.
    ///
    /// Requires a paid plan and a token with the `hubs:write` scope.
    public func releaseRuntimeGroup(
        _ runtimeGroupId: String,
        _ options: ReleaseOptions = ReleaseOptions()
    ) async throws -> JSONObject {
        try await requestObject(
            "POST",
            "/v1/runtime-groups/\(encodePathComponent(runtimeGroupId))/release",
            body: options.asJSON()
        )
    }

    /// `DELETE /v1/runtime-groups/{runtimeGroupId}`.
    ///
    /// The API answers HTTP 409 for the workspace default group and for a
    /// group that still has hubs attached. This route reads no `If-Match`.
    ///
    /// Requires a paid plan and a token with the `hubs:write` scope.
    public func deleteRuntimeGroup(_ runtimeGroupId: String) async throws {
        _ = try await requestData("DELETE", "/v1/runtime-groups/\(encodePathComponent(runtimeGroupId))")
    }

    /// `POST /v1/runtime-groups/{runtimeGroupId}/skills`: installs (or
    /// re-installs) a skill in a runtime group.
    ///
    /// The default `sourceType` of `catalog` installs a marketplace skill and
    /// requires the skill to exist in the catalog; `git` installs need a
    /// `sourceRef` repository URL. Installing a skill that is already present
    /// updates the existing entry.
    ///
    /// Requires a paid plan and a token with the `hubs:write` scope. Paid
    /// marketplace skills also need marketplace access on the tenant plan, and
    /// answer HTTP 402 without it. The API answers HTTP 409 for a deactivated
    /// catalog entry and for a skill that conflicts with an installed one
    /// (error code `runtime_skill_dependency_conflict`).
    public func installRuntimeGroupSkill(
        _ runtimeGroupId: String,
        skillId: String,
        options: InstallRuntimeGroupSkillOptions = InstallRuntimeGroupSkillOptions()
    ) async throws -> JSONObject {
        var body: JSONObject = [
            "skill_id": .string(skillId),
            "source_type": .string(options.sourceType),
            "active": .bool(options.active),
        ]
        if let marketplaceSkillId = options.marketplaceSkillId {
            body["marketplace_skill_id"] = .string(marketplaceSkillId)
        }
        if let sourceRef = options.sourceRef {
            body["source_ref"] = .string(sourceRef)
        }
        if let versionPin = options.versionPin {
            body["version_pin"] = .string(versionPin)
        }
        return try await requestObject(
            "POST",
            "/v1/runtime-groups/\(encodePathComponent(runtimeGroupId))/skills",
            body: body
        )
    }

    /// `DELETE /v1/runtime-groups/{runtimeGroupId}/skills/{skillId}`.
    ///
    /// Requires a paid plan and a token with the `hubs:write` scope.
    public func uninstallRuntimeGroupSkill(_ runtimeGroupId: String, skillId: String) async throws {
        _ = try await requestData(
            "DELETE",
            "/v1/runtime-groups/\(encodePathComponent(runtimeGroupId))/skills/\(encodePathComponent(skillId))"
        )
    }

    // MARK: Skill discovery

    /// `GET /v1/marketplace/skills`: the marketplace skill catalog visible to
    /// the authenticated user.
    ///
    /// Returns `{"data": [...]}` where each entry carries the catalog fields an
    /// install needs -- `skill_id`, `source_type`, `source_ref`,
    /// `package_name`, `version` compatibility, `config_schema` and
    /// `secret_schema` -- alongside presentation and access fields such as
    /// `category`, `tags`, `verified`, `access_tier` and `billing_sku`.
    ///
    /// Requires a token with the `hubs:read` scope. Unlike the provisioning
    /// routes this catalog is **not** paid-gated, so free-tier callers can
    /// browse the marketplace before upgrading -- only the install itself
    /// needs a paid plan.
    public func listMarketplaceSkills(
        _ options: MarketplaceSkillListOptions = MarketplaceSkillListOptions()
    ) async throws -> JSONObject {
        var params: [(String, String)] = []
        appendParam(&params, "owner_id", options.ownerId)
        if options.includeInactive { params.append(("include_inactive", "true")) }
        if options.forceRefresh { params.append(("force_refresh", "true")) }
        return try await requestObject("GET", pathWithQuery("/v1/marketplace/skills", params))
    }

    /// `GET /v1/runtime-groups/{runtimeGroupId}/marketplace`: the marketplace
    /// catalog resolved against one runtime group -- the discovery view to use
    /// before installing.
    ///
    /// Every catalog entry is returned with the group's own state folded in:
    /// whether the skill is desired (`active`, `version_pin`, `source_type`),
    /// whether it was observed running (`observed_source`, `observed_at`,
    /// intent counts), operator status fields, and the access verdict for the
    /// tenant plan (`purchase_required`, `installable`, `access_message`). The
    /// envelope also carries `runtime_group_id`, `observed_at`, `source`,
    /// `operator_phase` and `operator_message`.
    ///
    /// `refreshInventory` forces a live read from the runtime operator instead
    /// of answering from the cached inventory snapshot.
    ///
    /// Requires a token with the `hubs:inspect` scope; no paid plan is needed
    /// to browse. The API answers HTTP 404 for an unknown group and HTTP 403
    /// when the caller does not own it.
    public func listRuntimeGroupMarketplace(
        _ runtimeGroupId: String,
        refreshInventory: Bool = false
    ) async throws -> JSONObject {
        var params: [(String, String)] = []
        if refreshInventory { params.append(("refresh_inventory", "true")) }
        return try await requestObject(
            "GET",
            pathWithQuery("/v1/runtime-groups/\(encodePathComponent(runtimeGroupId))/marketplace", params)
        )
    }

    /// `GET /v1/runtime-groups/{runtimeGroupId}/inventory`: the skills a
    /// runtime group is actually observed running.
    ///
    /// Where `listRuntimeGroupMarketplace` answers "what could be installed
    /// here", this answers "what is loaded right now": each entry carries
    /// `skill_id`, `version`, `source`, `active`, `adapt_intents`,
    /// `padatious_intents`, `total_intents` and `observed_at`. The envelope
    /// reports `source` -- the observation's provenance, one of
    /// `ovos-runtime-operator`, `runtime-group-cache` or
    /// `ovos-runtime-operator-pending` -- plus `operator_phase` and
    /// `operator_message`.
    ///
    /// `refresh` forces a live operator read; the API also refreshes on its own
    /// when it holds no cached snapshot. Unlike `getHubRuntimeCapabilities`
    /// this route does **not** answer HTTP 409 when nothing is reporting -- it
    /// returns an empty `data` list with a pending `source` instead.
    ///
    /// Requires a token with the `hubs:inspect` scope; no paid plan is needed.
    public func listRuntimeGroupInventory(
        _ runtimeGroupId: String,
        refresh: Bool = false
    ) async throws -> JSONObject {
        var params: [(String, String)] = []
        if refresh { params.append(("refresh", "true")) }
        return try await requestObject(
            "GET",
            pathWithQuery("/v1/runtime-groups/\(encodePathComponent(runtimeGroupId))/inventory", params)
        )
    }
}

// MARK: Payload helpers

/// Copies a request body, renaming the camelCase keys the API takes as
/// snake_case. A camelCase key wins over an already-snake_case one.
func snakeCasePayload(_ payload: JSONObject, _ renames: [(String, String)]) -> JSONObject {
    var data = payload
    for (source, target) in renames where data[source] != nil {
        data[target] = data.removeValue(forKey: source)
    }
    return data
}

func hubPayload(_ payload: JSONObject) -> JSONObject {
    snakeCasePayload(payload, [
        ("ownerId", "owner_id"),
        ("runtimeGroupId", "runtime_group_id"),
        ("capacityProfile", "capacity_profile"),
        ("isLocked", "is_locked"),
    ])
}

func runtimeGroupPayload(_ payload: JSONObject) -> JSONObject {
    snakeCasePayload(payload, [
        ("ownerId", "owner_id"),
        ("cloneFromDefault", "clone_from_default"),
    ])
}
