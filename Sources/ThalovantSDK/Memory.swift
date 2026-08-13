import Foundation

public enum MemoryScope: String, Codable, Equatable, Sendable {
    case personal
    case workspace
    case hub
}

public enum MemoryKind: String, Codable, Equatable, Sendable {
    case note
    case preference
    case fact
}

/// Filters for `GET /v1/memory`.
public struct MemoryListOptions: Sendable {
    public var scope: MemoryScope?
    public var kind: MemoryKind?
    public var ownerId: String?
    public var hubId: String?
    public var query: String?
    public var includeDeleted: Bool
    public var includeExpired: Bool
    public var limit: Int?
    public var offset: Int?

    public init(
        scope: MemoryScope? = nil,
        kind: MemoryKind? = nil,
        ownerId: String? = nil,
        hubId: String? = nil,
        query: String? = nil,
        includeDeleted: Bool = false,
        includeExpired: Bool = false,
        limit: Int? = nil,
        offset: Int? = nil
    ) {
        self.scope = scope
        self.kind = kind
        self.ownerId = ownerId
        self.hubId = hubId
        self.query = query
        self.includeDeleted = includeDeleted
        self.includeExpired = includeExpired
        self.limit = limit
        self.offset = offset
    }
}

/// Body for `POST /v1/memory`. Optional fields are sent only when set.
public struct MemoryCreatePayload: Sendable {
    public var scope: MemoryScope?
    public var kind: MemoryKind?
    public var title: String?
    public var content: String
    public var tags: [String]?
    public var ownerId: String?
    public var hubId: String?
    public var source: String?
    public var metadata: JSONObject?
    public var consentScope: String?
    public var consentVersion: String?
    public var retentionPolicy: String?
    public var expiresAt: String?

    public init(
        content: String,
        scope: MemoryScope? = nil,
        kind: MemoryKind? = nil,
        title: String? = nil,
        tags: [String]? = nil,
        ownerId: String? = nil,
        hubId: String? = nil,
        source: String? = nil,
        metadata: JSONObject? = nil,
        consentScope: String? = nil,
        consentVersion: String? = nil,
        retentionPolicy: String? = nil,
        expiresAt: String? = nil
    ) {
        self.content = content
        self.scope = scope
        self.kind = kind
        self.title = title
        self.tags = tags
        self.ownerId = ownerId
        self.hubId = hubId
        self.source = source
        self.metadata = metadata
        self.consentScope = consentScope
        self.consentVersion = consentVersion
        self.retentionPolicy = retentionPolicy
        self.expiresAt = expiresAt
    }

    public func asJSON() -> JSONObject {
        var body: JSONObject = ["content": .string(content)]
        if let scope { body["scope"] = .string(scope.rawValue) }
        if let kind { body["kind"] = .string(kind.rawValue) }
        if let title { body["title"] = .string(title) }
        if let tags { body["tags"] = .array(tags.map { .string($0) }) }
        if let ownerId { body["owner_id"] = .string(ownerId) }
        if let hubId { body["hub_id"] = .string(hubId) }
        if let source { body["source"] = .string(source) }
        if let metadata { body["metadata"] = .object(metadata) }
        if let consentScope { body["consent_scope"] = .string(consentScope) }
        if let consentVersion { body["consent_version"] = .string(consentVersion) }
        if let retentionPolicy { body["retention_policy"] = .string(retentionPolicy) }
        if let expiresAt { body["expires_at"] = .string(expiresAt) }
        return body
    }
}

/// Body for `PATCH /v1/memory/{memory_id}`. Optional fields are sent only when set.
public struct MemoryUpdatePayload: Sendable {
    public var kind: MemoryKind?
    public var title: String?
    public var content: String?
    public var tags: [String]?
    public var metadata: JSONObject?
    public var consentScope: String?
    public var consentVersion: String?
    public var retentionPolicy: String?
    public var expiresAt: String?
    public var clearExpiresAt: Bool

    public init(
        kind: MemoryKind? = nil,
        title: String? = nil,
        content: String? = nil,
        tags: [String]? = nil,
        metadata: JSONObject? = nil,
        consentScope: String? = nil,
        consentVersion: String? = nil,
        retentionPolicy: String? = nil,
        expiresAt: String? = nil,
        clearExpiresAt: Bool = false
    ) {
        self.kind = kind
        self.title = title
        self.content = content
        self.tags = tags
        self.metadata = metadata
        self.consentScope = consentScope
        self.consentVersion = consentVersion
        self.retentionPolicy = retentionPolicy
        self.expiresAt = expiresAt
        self.clearExpiresAt = clearExpiresAt
    }

    public func asJSON() -> JSONObject {
        var body: JSONObject = [:]
        if let kind { body["kind"] = .string(kind.rawValue) }
        if let title { body["title"] = .string(title) }
        if let content { body["content"] = .string(content) }
        if let tags { body["tags"] = .array(tags.map { .string($0) }) }
        if let metadata { body["metadata"] = .object(metadata) }
        if let consentScope { body["consent_scope"] = .string(consentScope) }
        if let consentVersion { body["consent_version"] = .string(consentVersion) }
        if let retentionPolicy { body["retention_policy"] = .string(retentionPolicy) }
        if let expiresAt { body["expires_at"] = .string(expiresAt) }
        if clearExpiresAt { body["clear_expires_at"] = .bool(true) }
        return body
    }
}

/// A memory item, exactly as returned by the `/v1/memory` endpoints.
public struct MemoryItemResource: Codable, Equatable, Sendable {
    public let id: String
    public let ownerId: String
    public let createdById: String
    public let hubId: String?
    public let scope: MemoryScope
    public let kind: MemoryKind
    public let title: String?
    public let content: String
    public let tags: [String]
    public let source: String
    public let metadata: JSONObject
    public let consentScope: String
    public let consentVersion: String?
    public let retentionPolicy: String
    public let expiresAt: String?
    public let deletedAt: String?
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case ownerId = "owner_id"
        case createdById = "created_by_id"
        case hubId = "hub_id"
        case scope
        case kind
        case title
        case content
        case tags
        case source
        case metadata
        case consentScope = "consent_scope"
        case consentVersion = "consent_version"
        case retentionPolicy = "retention_policy"
        case expiresAt = "expires_at"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Pagination envelope metadata shared by list endpoints.
public struct PaginationMeta: Codable, Equatable, Sendable {
    public let count: Int
    public let next: String?
    public let prev: String?
    public let extra: JSONObject?
}

/// Response of `GET /v1/memory`.
public struct MemoryListResponse: Codable, Equatable, Sendable {
    public let data: [MemoryItemResource]
    public let meta: PaginationMeta
    public let links: [String: String?]
}

/// Response of `GET /v1/memory/summary`.
public struct MemorySummaryResponse: Codable, Equatable, Sendable {
    public let total: Int
    public let byScope: [String: Int]
    public let byKind: [String: Int]
    public let expired: Int
    public let deleted: Int

    enum CodingKeys: String, CodingKey {
        case total
        case byScope = "by_scope"
        case byKind = "by_kind"
        case expired
        case deleted
    }
}
