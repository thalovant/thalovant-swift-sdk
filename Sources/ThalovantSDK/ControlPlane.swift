import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public let defaultControlAPIURL = "https://api.thalovant.com"
public let defaultThalovantUserAgent = "ThalovantSwiftSDK/0.1.3"

/// Filters for `GET /v1/analytics/overview` (and, with `admin`,
/// `GET /v1/admin/analytics/overview`). `ownerId` is admin-only.
public struct AnalyticsOverviewOptions: Sendable {
    public var admin: Bool
    public var range: String?
    public var bucket: String?
    public var ownerId: String?
    public var hubId: String?
    public var clientId: String?
    public var country: String?
    public var message: String?
    public var utterance: String?
    public var intent: String?
    public var timeStart: String?
    public var timeEnd: String?
    public var weekday: Int?
    public var hour: Int?

    public init(
        admin: Bool = false,
        range: String? = nil,
        bucket: String? = nil,
        ownerId: String? = nil,
        hubId: String? = nil,
        clientId: String? = nil,
        country: String? = nil,
        message: String? = nil,
        utterance: String? = nil,
        intent: String? = nil,
        timeStart: String? = nil,
        timeEnd: String? = nil,
        weekday: Int? = nil,
        hour: Int? = nil
    ) {
        self.admin = admin
        self.range = range
        self.bucket = bucket
        self.ownerId = ownerId
        self.hubId = hubId
        self.clientId = clientId
        self.country = country
        self.message = message
        self.utterance = utterance
        self.intent = intent
        self.timeStart = timeStart
        self.timeEnd = timeEnd
        self.weekday = weekday
        self.hour = hour
    }
}

/// Options for provisioning a client identity on a hub.
public struct CreateClientIdentityOptions: Sendable {
    public var name: String
    public var siteId: String?
    public var spec: JSONObject?
    public var ownerId: String?
    public var active: Bool
    public var preferredProtocols: [HubProtocol]?
    public var idempotencyKey: String?

    public init(
        name: String,
        siteId: String? = nil,
        spec: JSONObject? = nil,
        ownerId: String? = nil,
        active: Bool = true,
        preferredProtocols: [HubProtocol]? = nil,
        idempotencyKey: String? = nil
    ) {
        self.name = name
        self.siteId = siteId
        self.spec = spec
        self.ownerId = ownerId
        self.active = active
        self.preferredProtocols = preferredProtocols
        self.idempotencyKey = idempotencyKey
    }
}

/// Result of `createClientIdentity`: the provisioned identity plus the hub and
/// client resources it was derived from.
public struct BootstrapIdentityResult {
    public let identity: ThalovantIdentity
    public let hub: JSONObject
    public let client: JSONObject
    public let endpoint: SelectedHubEndpoint?

    public var selectedProtocol: HubProtocol? { endpoint?.hubProtocol }

    public func asJSON(includeSecrets: Bool = false) -> JSONObject {
        var data: JSONObject = [
            "identity": .object(identity.asJSON(includeSecrets: includeSecrets)),
            "hub": .object(hub),
            "client": .object(client),
        ]
        if let endpoint {
            data["selectedProtocol"] = .string(endpoint.hubProtocol.rawValue)
            data["selectedEndpoint"] = .string(endpoint.endpoint)
        }
        return data
    }
}

/// Client for the Thalovant control API (`https://api.thalovant.com`).
public final class ThalovantControlPlane {
    public let apiURL: String
    public var accessToken: String?
    public let userAgent: String
    let session: URLSession

    public init(
        apiURL: String = defaultControlAPIURL,
        accessToken: String? = nil,
        userAgent: String = defaultThalovantUserAgent,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.apiURL = ThalovantControlPlane.normalizeControlAPIURL(apiURL)
        self.accessToken = accessToken
        self.userAgent = userAgent
        self.session = session
    }

    /// Normalizes the control API base URL: trims trailing slashes and a
    /// trailing `/v1` path segment, and appends exactly one trailing `/`.
    static func normalizeControlAPIURL(_ apiURL: String) -> String {
        let raw = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = trimTrailingSlashes(raw.isEmpty ? defaultControlAPIURL : raw)
        if normalized.hasSuffix("/v1") {
            normalized = String(normalized.dropLast(3))
        }
        return trimTrailingSlashes(normalized) + "/"
    }

    // MARK: Auth

    /// `POST /v1/auth/token`. `otpCode`/`recoveryCode` are sent as
    /// `otp_code`/`recovery_code` only when provided; MFA-enabled accounts
    /// receive HTTP 401 with code `mfa_required` without one.
    @discardableResult
    public func login(
        email: String,
        password: String,
        scope: String? = nil,
        otpCode: String? = nil,
        recoveryCode: String? = nil
    ) async throws -> JSONObject {
        var body: JSONObject = [
            "email": .string(email),
            "password": .string(password),
        ]
        if let scope, !scope.isEmpty { body["scope"] = .string(scope) }
        if let otpCode { body["otp_code"] = .string(otpCode) }
        if let recoveryCode { body["recovery_code"] = .string(recoveryCode) }
        let token = try await requestObject("POST", "/v1/auth/token", body: body, auth: false)
        guard let accessToken = token["access_token"]?.stringValue, !accessToken.isEmpty else {
            throw ThalovantApiError(message: "Thalovant API token response did not include access_token.")
        }
        self.accessToken = accessToken
        return token
    }

    // MARK: Hubs

    public func listHubs(limit: Int = 100, cursor: String? = nil, ownerId: String? = nil) async throws -> JSONObject {
        var params: [(String, String)] = [("limit", String(limit))]
        if let cursor, !cursor.isEmpty { params.append(("cursor", cursor)) }
        if let ownerId, !ownerId.isEmpty { params.append(("owner_id", ownerId)) }
        return try await requestObject("GET", pathWithQuery("/v1/hubs", params))
    }

    public func getHub(_ hubId: String) async throws -> JSONObject {
        try await requestObject("GET", "/v1/hubs/\(encodePathComponent(hubId))")
    }

    public func listPublicHubs(limit: Int = 24, cursor: String? = nil) async throws -> JSONObject {
        var params: [(String, String)] = [("limit", String(limit))]
        if let cursor, !cursor.isEmpty { params.append(("cursor", cursor)) }
        return try await requestObject("GET", pathWithQuery("/v1/public/hubs", params), auth: false)
    }

    public func getPublicHub(_ hubRef: String) async throws -> JSONObject {
        try await requestObject("GET", "/v1/public/hubs/\(encodePathComponent(hubRef))", auth: false)
    }

    // MARK: Operations

    public func getOperation(id operationId: String) async throws -> OperationResource {
        let data = try await requestData("GET", "/v1/operations/\(encodePathComponent(operationId))")
        return try decodeResource(OperationResource.self, from: data)
    }

    // MARK: Memory

    public func listMemoryItems(_ options: MemoryListOptions = MemoryListOptions()) async throws -> MemoryListResponse {
        var params: [(String, String)] = []
        if let scope = options.scope { params.append(("scope", scope.rawValue)) }
        if let kind = options.kind { params.append(("kind", kind.rawValue)) }
        appendParam(&params, "owner_id", options.ownerId)
        appendParam(&params, "hub_id", options.hubId)
        appendParam(&params, "q", options.query)
        if options.includeDeleted { params.append(("include_deleted", "true")) }
        if options.includeExpired { params.append(("include_expired", "true")) }
        if let limit = options.limit { params.append(("limit", String(limit))) }
        if let offset = options.offset { params.append(("offset", String(offset))) }
        let data = try await requestData("GET", pathWithQuery("/v1/memory", params))
        return try decodeResource(MemoryListResponse.self, from: data)
    }

    public func getMemorySummary(ownerId: String? = nil) async throws -> MemorySummaryResponse {
        var params: [(String, String)] = []
        appendParam(&params, "owner_id", ownerId)
        let data = try await requestData("GET", pathWithQuery("/v1/memory/summary", params))
        return try decodeResource(MemorySummaryResponse.self, from: data)
    }

    public func createMemoryItem(_ payload: MemoryCreatePayload) async throws -> MemoryItemResource {
        let data = try await requestData("POST", "/v1/memory", body: payload.asJSON())
        return try decodeResource(MemoryItemResource.self, from: data)
    }

    public func getMemoryItem(_ memoryId: String) async throws -> MemoryItemResource {
        let data = try await requestData("GET", "/v1/memory/\(encodePathComponent(memoryId))")
        return try decodeResource(MemoryItemResource.self, from: data)
    }

    public func updateMemoryItem(_ memoryId: String, _ payload: MemoryUpdatePayload) async throws -> MemoryItemResource {
        let data = try await requestData("PATCH", "/v1/memory/\(encodePathComponent(memoryId))", body: payload.asJSON())
        return try decodeResource(MemoryItemResource.self, from: data)
    }

    public func deleteMemoryItem(_ memoryId: String) async throws {
        _ = try await requestData("DELETE", "/v1/memory/\(encodePathComponent(memoryId))")
    }

    // MARK: Analytics

    public func analyticsOverview(_ options: AnalyticsOverviewOptions = AnalyticsOverviewOptions()) async throws -> JSONObject {
        let endpoint = options.admin ? "/v1/admin/analytics/overview" : "/v1/analytics/overview"
        var params: [(String, String)] = []
        appendParam(&params, "range", options.range)
        appendParam(&params, "bucket", options.bucket)
        if options.admin {
            appendParam(&params, "owner_id", options.ownerId)
        }
        appendParam(&params, "hub_id", options.hubId)
        appendParam(&params, "client_id", options.clientId)
        appendParam(&params, "country", options.country)
        appendParam(&params, "message", options.message)
        appendParam(&params, "utterance", options.utterance)
        appendParam(&params, "intent", options.intent)
        appendParam(&params, "time_start", options.timeStart)
        appendParam(&params, "time_end", options.timeEnd)
        if let weekday = options.weekday { params.append(("weekday", String(weekday))) }
        if let hour = options.hour { params.append(("hour", String(hour))) }
        return try await requestObject("GET", pathWithQuery(endpoint, params))
    }

    // MARK: Clients

    public func createClient(_ payload: JSONObject, idempotencyKey: String? = nil) async throws -> JSONObject {
        try await requestObject(
            "POST",
            "/v1/clients",
            body: payload,
            headers: ["Idempotency-Key": idempotencyKey ?? newIdempotencyKey()]
        )
    }

    /// Provisions a client identity: `GET /v1/hubs/{id}` followed by
    /// `POST /v1/clients` with an `Idempotency-Key` header, parsing the
    /// returned `initial_identify` credentials.
    public func createClientIdentity(hubId: String, options: CreateClientIdentityOptions) async throws -> BootstrapIdentityResult {
        let hub = try await getHub(hubId)
        return try await createClientIdentity(hub: hub, options: options)
    }

    public func createClientIdentity(hub: JSONObject, options: CreateClientIdentityOptions) async throws -> BootstrapIdentityResult {
        guard let hubId = hub["id"]?.stringValue, !hubId.isEmpty else {
            throw ThalovantApiError(message: "Hub resource is missing id.")
        }
        let siteId = cleanSiteId(options.siteId ?? options.name)
        let apiKey = newSecret()
        let password = newSecret()
        let cryptoKey = newSecret()
        var spec = options.spec ?? [:]
        spec["version"] = .string(optionalString(spec["version"]) ?? "1")
        spec["apiKey"] = .string(apiKey)
        spec["password"] = .string(password)
        spec["cryptoKey"] = .string(cryptoKey)
        spec["siteId"] = .string(siteId)
        var payload: JSONObject = [
            "hub_id": .string(hubId),
            "name": .string(options.name),
            "spec": .object(spec),
            "active": .bool(options.active),
        ]
        if let ownerId = options.ownerId {
            payload["owner_id"] = .string(ownerId)
        }

        let client = try await createClient(payload, idempotencyKey: options.idempotencyKey)
        let protocols = HubProtocolSettings.from(hub)
        let endpoints = HubDataPlaneEndpoints.fromHub(hub)
        let endpoint = selectDataPlaneEndpoint(
            endpoints: endpoints,
            protocols: protocols,
            preferredProtocols: options.preferredProtocols ?? defaultProtocolPreference
        )
        var identityJSON: JSONObject
        if let initialIdentify = client["initial_identify"]?.objectValue {
            identityJSON = initialIdentify
        } else {
            identityJSON = [
                "access_key": .string(apiKey),
                "password": .string(password),
                "crypto_key": .string(cryptoKey),
                "site_id": .string(siteId),
                "default_master": .string(try defaultMaster(hub: hub, endpoints: endpoints, selected: endpoint)),
                "default_port": .integer(443),
            ]
        }
        identityJSON["data_plane_endpoints"] = .object(endpoints.asJSON())
        identityJSON["protocols"] = .object(protocols.asJSON())
        let identity = try ThalovantIdentity(json: identityJSON)
        return BootstrapIdentityResult(identity: identity, hub: hub, client: client, endpoint: endpoint)
    }

    /// Resolves the endpoint the runtime should use, or throws when the hub
    /// does not expose the requested protocol.
    public func requireRuntimeProtocol(
        _ result: BootstrapIdentityResult,
        hubProtocol: HubProtocol? = nil
    ) throws -> SelectedHubEndpoint {
        let selected = hubProtocol ?? result.selectedProtocol ?? defaultProtocolPreference[0]
        if selected == .mqtt && result.identity.mqtt == nil {
            throw ThalovantUnsupportedProtocolError(
                "MQTT is enabled, but the API did not return client-scoped MQTT broker credentials."
            )
        }
        guard let endpoint = result.identity.endpointFor(selected) else {
            throw ThalovantUnsupportedProtocolError(
                "This hub does not expose a \(selected.rawValue.uppercased()) endpoint for the SDK runtime."
            )
        }
        return SelectedHubEndpoint(hubProtocol: selected, endpoint: endpoint)
    }

    // MARK: Request plumbing

    func buildRequest(
        _ method: String,
        _ path: String,
        body: JSONObject? = nil,
        headers: [String: String] = [:],
        auth: Bool = true
    ) throws -> URLRequest {
        var trimmedPath = path
        while trimmedPath.hasPrefix("/") {
            trimmedPath.removeFirst()
        }
        guard let url = URL(string: apiURL + trimmedPath) else {
            throw ThalovantApiError(message: "Invalid Thalovant API URL: \(apiURL + trimmedPath)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try ThalovantJSON.encode(body)
        }
        if auth {
            guard let accessToken, !accessToken.isEmpty else {
                throw ThalovantApiError(message: "Missing Thalovant API access token.")
            }
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    func requestData(
        _ method: String,
        _ path: String,
        body: JSONObject? = nil,
        headers: [String: String] = [:],
        auth: Bool = true
    ) async throws -> Data {
        let request = try buildRequest(method, path, body: body, headers: headers, auth: auth)
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            let text = String(decoding: data, as: UTF8.self)
            throw ThalovantApiError(
                message: "Thalovant API request failed with HTTP \(response.statusCode): \(text)",
                statusCode: response.statusCode,
                body: text
            )
        }
        return data
    }

    func requestObject(
        _ method: String,
        _ path: String,
        body: JSONObject? = nil,
        headers: [String: String] = [:],
        auth: Bool = true
    ) async throws -> JSONObject {
        let data = try await requestData(method, path, body: body, headers: headers, auth: auth)
        if data.isEmpty || String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [:]
        }
        guard let object = try? ThalovantJSON.decodeObject(data) else {
            throw ThalovantApiError(message: "Thalovant API returned an unexpected response shape.")
        }
        return object
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: ThalovantApiError(message: "Thalovant API request failed: \(error.localizedDescription)"))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: ThalovantApiError(message: "Thalovant API returned a non-HTTP response."))
                    return
                }
                continuation.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
    }

    private func decodeResource<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ThalovantApiError(
                message: "Thalovant API returned an unexpected response shape: \(error)",
                body: String(decoding: data, as: UTF8.self)
            )
        }
    }
}

// MARK: Helpers

func pathWithQuery(_ path: String, _ params: [(String, String)]) -> String {
    guard !params.isEmpty else { return path }
    var components = URLComponents()
    components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
    let query = components.percentEncodedQuery ?? ""
    return query.isEmpty ? path : "\(path)?\(query)"
}

func appendParam(_ params: inout [(String, String)], _ name: String, _ value: String?) {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    params.append((name, value))
}

func encodePathComponent(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

func newIdempotencyKey() -> String {
    UUID().uuidString.lowercased()
}

func newSecret() -> String {
    var bytes = [UInt8]()
    bytes.reserveCapacity(32)
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<32 {
        bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
    }
    return base64URLEncode(bytes)
}

func base64URLEncode(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func cleanSiteId(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let dashed = replaceRuns(in: trimmed, where: { $0 == "_" })
    let cleaned = replaceRuns(in: dashed, where: { $0.isWhitespace })
    if cleaned.isEmpty {
        var suffix = ""
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<8 {
            suffix.append("0123456789abcdef".randomElement(using: &generator) ?? "0")
        }
        return "thalovant-client-" + suffix
    }
    return cleaned
}

/// Replaces each run of matching characters with a single `-`.
private func replaceRuns(in value: String, where matches: (Character) -> Bool) -> String {
    var result = ""
    var inRun = false
    for character in value {
        if matches(character) {
            if !inRun {
                result.append("-")
                inRun = true
            }
        } else {
            result.append(character)
            inRun = false
        }
    }
    return result
}

func defaultMaster(hub: JSONObject, endpoints: HubDataPlaneEndpoints, selected: SelectedHubEndpoint?) throws -> String {
    if let https = endpoints.https {
        return stripEndpointPath(https)
    }
    if let domain = optionalString(hub["domain"]) {
        return endpointFromDomain(domain, hubProtocol: .https)
    }
    if let selected {
        return stripEndpointPath(selected.endpoint)
    }
    throw ThalovantApiError(message: "Hub resource does not expose a usable data-plane endpoint.")
}

func stripEndpointPath(_ endpoint: String) -> String {
    guard var components = URLComponents(string: endpoint) else {
        return trimTrailingSlashes(endpoint)
    }
    components.path = ""
    components.query = nil
    components.fragment = nil
    return trimTrailingSlashes(components.string ?? endpoint)
}
