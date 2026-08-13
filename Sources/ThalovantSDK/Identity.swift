import Foundation

/// Client-scoped MQTT broker credentials
/// (`mqtt.{endpoint,username,password,topic_prefix,tls}` per the API `clients` schema).
public struct MqttBrokerCredentials: Equatable, Sendable {
    public let endpoint: String
    public let username: String
    public let password: String
    public let topicPrefix: String?
    public let hubId: String?
    public let c2sTopic: String?
    public let s2cTopic: String?
    public let statusTopic: String?
    public let hashTopics: Bool
    public let qos: Int
    public let tls: Bool

    public init(json: JSONObject) throws {
        guard let endpoint = optionalString(first(json, "endpoint", "broker_url")) else {
            throw ThalovantIdentityError("Missing required identity field: mqtt.endpoint")
        }
        guard let username = optionalString(first(json, "username", "broker_username")) else {
            throw ThalovantIdentityError("Missing required identity field: mqtt.username")
        }
        guard let password = optionalString(first(json, "password", "broker_password")) else {
            throw ThalovantIdentityError("Missing required identity field: mqtt.password")
        }
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.topicPrefix = optionalString(json["topic_prefix"])
        self.hubId = optionalString(json["hub_id"])
        self.c2sTopic = optionalString(json["c2s_topic"])
        self.s2cTopic = optionalString(json["s2c_topic"])
        self.statusTopic = optionalString(json["status_topic"])
        self.hashTopics = enabledValue(json["hash_topics"], fallback: false)
        self.qos = json["qos"]?.intValue ?? 1
        self.tls = enabledValue(json["tls"], fallback: endpoint.hasPrefix("mqtts://"))
    }

    public static func from(_ value: JSONValue?) -> MqttBrokerCredentials? {
        guard let json = value?.objectValue else { return nil }
        return try? MqttBrokerCredentials(json: json)
    }

    public func asJSON(includeSecrets: Bool = false) -> JSONObject {
        var data: JSONObject = [
            "endpoint": .string(endpoint),
            "tls": .bool(tls),
        ]
        if includeSecrets {
            data["username"] = .string(username)
            data["password"] = .string(password)
            if let topicPrefix { data["topic_prefix"] = .string(topicPrefix) }
            if let hubId { data["hub_id"] = .string(hubId) }
            if let c2sTopic { data["c2s_topic"] = .string(c2sTopic) }
            if let s2cTopic { data["s2c_topic"] = .string(s2cTopic) }
            if let statusTopic { data["status_topic"] = .string(statusTopic) }
            if hashTopics { data["hash_topics"] = .bool(true) }
            if qos != 1 { data["qos"] = .integer(qos) }
        }
        return data
    }
}

/// A client identity provisioned by the control plane
/// (`access_key`, `password`, `crypto_key`, `site_id`, `default_port`,
/// `default_master`, and optional `mqtt` credentials per the API `clients` schema).
public struct ThalovantIdentity: Sendable {
    public let accessKey: String
    public let password: String
    public let defaultMaster: String
    public let defaultPort: Int
    public let defaultPath: String
    public let siteId: String
    public let cryptoKey: String?
    public let dataPlaneEndpoints: HubDataPlaneEndpoints
    public let protocols: HubProtocolSettings
    public let publicKey: String?
    public let metadata: JSONObject
    public let mqtt: MqttBrokerCredentials?

    public init(json: JSONObject) throws {
        guard let accessKey = optionalString(first(json, "access_key", "accessKey", "api_key", "key")) else {
            throw ThalovantIdentityError("Missing required identity field: access_key")
        }
        guard let password = optionalString(json["password"]) else {
            throw ThalovantIdentityError("Missing required identity field: password")
        }
        guard
            let master = optionalString(
                first(json, "default_master", "defaultMaster", "hub_http_host", "host", "master")
            )
        else {
            throw ThalovantIdentityError("Missing required identity field: default_master")
        }
        guard let siteId = optionalString(first(json, "site_id", "siteId", "site")) else {
            throw ThalovantIdentityError("Missing required identity field: site_id")
        }
        self.accessKey = accessKey
        self.password = password
        self.defaultMaster = trimTrailingSlashes(master)
        self.siteId = siteId
        self.defaultPort = positivePort(
            first(json, "default_port", "defaultPort", "hub_http_port", "port"),
            fallback: 5679
        )
        self.defaultPath = normalizeIdentityPath(
            optionalString(first(json, "default_path", "defaultPath", "hub_http_path", "path", "uri_path"))
        )
        self.cryptoKey = optionalString(first(json, "crypto_key", "cryptoKey"))
        self.dataPlaneEndpoints = HubDataPlaneEndpoints.from(json)
        self.protocols = HubProtocolSettings.from(json)
        self.publicKey = optionalString(first(json, "public_key", "publicKey"))
        self.metadata = json["metadata"]?.objectValue ?? [:]
        self.mqtt = MqttBrokerCredentials.from(json["mqtt"])
    }

    public init(jsonData: Data) throws {
        let object: JSONObject
        do {
            object = try ThalovantJSON.decodeObject(jsonData)
        } catch {
            throw ThalovantIdentityError("Identity document is not a valid JSON object.")
        }
        try self.init(json: object)
    }

    /// Loads an identity from a JSON file, refusing group/world-readable files
    /// on POSIX platforms (run `chmod 600 <path>` first).
    public static func fromFile(_ path: String) throws -> ThalovantIdentity {
        try assertSecureIdentityFile(path)
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ThalovantIdentityError("Unable to read identity file: \(path)")
        }
        do {
            return try ThalovantIdentity(jsonData: data)
        } catch let error as ThalovantIdentityError {
            if (try? ThalovantJSON.decodeObject(data)) == nil {
                throw ThalovantIdentityError("Identity file is not valid JSON: \(path)")
            }
            throw error
        }
    }

    /// Base URL used by the HTTP(S) data plane for this identity.
    public func endpointBase() -> String {
        dataPlaneEndpoints.httpBase(
            fallbackMaster: defaultMaster,
            fallbackPort: defaultPort,
            fallbackPath: defaultPath
        )
    }

    /// Endpoint for a protocol, or `nil` when the identity does not expose one.
    public func endpointFor(_ hubProtocol: HubProtocol) -> String? {
        if hubProtocol == .https {
            return endpointBase()
        }
        if let endpoint = dataPlaneEndpoints.endpointFor(hubProtocol) {
            return endpoint
        }
        if hubProtocol == .wss {
            let lowered = defaultMaster.lowercased()
            if lowered.hasPrefix("wss://") || lowered.hasPrefix("ws://") {
                return defaultMaster
            }
        }
        return nil
    }

    public func enabledProtocols() -> [HubProtocol] {
        protocols.enabledProtocols()
    }

    public func supportsProtocol(_ hubProtocol: HubProtocol) -> Bool {
        protocols.isEnabled(hubProtocol)
    }

    public func asJSON(includeSecrets: Bool = false) -> JSONObject {
        var data: JSONObject = [
            "site_id": .string(siteId),
            "default_master": .string(defaultMaster),
            "default_port": .integer(defaultPort),
            "default_path": .string(defaultPath),
        ]
        let endpoints = dataPlaneEndpoints.asJSON(redactCredentials: !includeSecrets)
        if !endpoints.isEmpty {
            data["data_plane_endpoints"] = .object(endpoints)
        }
        if !metadata.isEmpty {
            data["metadata"] = .object(metadata)
        }
        if includeSecrets {
            data["access_key"] = .string(accessKey)
            data["password"] = .string(password)
            if let cryptoKey { data["crypto_key"] = .string(cryptoKey) }
        }
        if let mqtt {
            data["mqtt"] = .object(mqtt.asJSON(includeSecrets: includeSecrets))
        }
        return data
    }
}

private func positivePort(_ value: JSONValue?, fallback: Int) -> Int {
    guard let value else { return fallback }
    let parsed: Int?
    switch value {
    case .integer(let number): parsed = number
    case .number(let number) where number == number.rounded(): parsed = Int(number)
    case .string(let text): parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    default: parsed = nil
    }
    guard let parsed, parsed > 0 else { return fallback }
    return parsed
}

private func normalizeIdentityPath(_ value: String?) -> String {
    guard let value else { return "" }
    let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return trimmed.isEmpty ? "" : "/" + trimmed
}

private func assertSecureIdentityFile(_ path: String) throws {
    let attributes: [FileAttributeKey: Any]
    do {
        attributes = try FileManager.default.attributesOfItem(atPath: path)
    } catch {
        throw ThalovantIdentityError("Unable to read identity file: \(path)")
    }
    #if !os(Windows)
    if let permissions = attributes[.posixPermissions] as? NSNumber {
        let mode = permissions.intValue
        if mode & 0o077 != 0 {
            throw ThalovantIdentityError(
                "Identity file is too permissive: \(path). Run `chmod 600 \(path)`."
            )
        }
    }
    #endif
}
