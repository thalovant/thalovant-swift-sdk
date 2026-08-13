import Foundation

/// Lifecycle status of a durable asynchronous operation.
public enum OperationStatus: String, Codable, Equatable, Sendable {
    case requested
    case committed
    case applied
    case ready
    case failed
    case timedOut = "timed_out"
}

/// A durable asynchronous operation, exactly as returned by
/// `GET /v1/operations/{operation_id}`.
public struct OperationResource: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let aggregateType: String
    public let aggregateId: String?
    public let status: OperationStatus
    public let details: JSONObject
    public let gitCommitSha: String?
    public let errorCode: String?
    public let errorMessage: String?
    public let createdAt: String
    public let updatedAt: String
    public let committedAt: String?
    public let appliedAt: String?
    public let readyAt: String?
    public let terminalAt: String?
    public let links: [String: String?]

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case aggregateType = "aggregate_type"
        case aggregateId = "aggregate_id"
        case status
        case details
        case gitCommitSha = "git_commit_sha"
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case committedAt = "committed_at"
        case appliedAt = "applied_at"
        case readyAt = "ready_at"
        case terminalAt = "terminal_at"
        case links
    }

    public init(
        id: String,
        kind: String,
        aggregateType: String,
        aggregateId: String? = nil,
        status: OperationStatus,
        details: JSONObject = [:],
        gitCommitSha: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        createdAt: String,
        updatedAt: String,
        committedAt: String? = nil,
        appliedAt: String? = nil,
        readyAt: String? = nil,
        terminalAt: String? = nil,
        links: [String: String?] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.aggregateType = aggregateType
        self.aggregateId = aggregateId
        self.status = status
        self.details = details
        self.gitCommitSha = gitCommitSha
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.committedAt = committedAt
        self.appliedAt = appliedAt
        self.readyAt = readyAt
        self.terminalAt = terminalAt
        self.links = links
    }
}
