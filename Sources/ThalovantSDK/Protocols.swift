import Foundation

/// Data-plane protocols a Thalovant hub can expose.
public enum HubProtocol: String, Codable, CaseIterable, Sendable {
    case wss
    case https
    case mqtt
}

/// Default protocol preference order used when bootstrapping a client.
public let defaultProtocolPreference: [HubProtocol] = [.wss, .https, .mqtt]

/// A protocol together with the concrete endpoint chosen for it.
public struct SelectedHubEndpoint: Equatable, Sendable {
    public let hubProtocol: HubProtocol
    public let endpoint: String

    public init(hubProtocol: HubProtocol, endpoint: String) {
        self.hubProtocol = hubProtocol
        self.endpoint = endpoint
    }
}

/// Which data-plane protocols a hub has enabled
/// (`spec.protocols.{wss,http,mqtt}.enabled`; WSS defaults to enabled).
public struct HubProtocolSettings: Equatable, Sendable {
    public let wss: Bool
    public let http: Bool
    public let mqtt: Bool

    public init(wss: Bool = true, http: Bool = false, mqtt: Bool = false) {
        self.wss = wss
        self.http = http
        self.mqtt = mqtt
    }

    /// Reads protocol settings from a hub resource, an identity document, or a
    /// bare `protocols` mapping. Missing values keep their defaults.
    public static func from(_ input: JSONValue?) -> HubProtocolSettings {
        guard let root = input?.objectValue else { return HubProtocolSettings() }
        let spec = root["spec"]?.objectValue ?? root
        let protocols = spec["protocols"]?.objectValue ?? [:]
        let network = spec["network"]?.objectValue ?? [:]
        return HubProtocolSettings(
            wss: enabledValue(first(protocols, "wss", "websocket") ?? first(network, "wss", "websocket"), fallback: true),
            http: enabledValue(first(protocols, "http", "https") ?? first(network, "http", "https"), fallback: false),
            mqtt: enabledValue(first(protocols, "mqtt") ?? first(network, "mqtt"), fallback: false)
        )
    }

    public static func from(_ input: JSONObject) -> HubProtocolSettings {
        from(JSONValue.object(input))
    }

    public var https: Bool { http }

    public func enabledProtocols() -> [HubProtocol] {
        var enabled: [HubProtocol] = []
        if wss { enabled.append(.wss) }
        if http { enabled.append(.https) }
        if mqtt { enabled.append(.mqtt) }
        return enabled
    }

    public func isEnabled(_ hubProtocol: HubProtocol) -> Bool {
        switch hubProtocol {
        case .wss: return wss
        case .https: return http
        case .mqtt: return mqtt
        }
    }

    public func asJSON() -> JSONObject {
        [
            "wss": .object(["enabled": .bool(wss)]),
            "http": .object(["enabled": .bool(http)]),
            "mqtt": .object(["enabled": .bool(mqtt)]),
        ]
    }
}

/// The concrete `data_plane_endpoints` (`https`, `wss`, `mqtt`) a hub exposes.
public struct HubDataPlaneEndpoints: Equatable, Sendable {
    public let https: String?
    public let wss: String?
    public let mqtt: String?

    public init(https: String? = nil, wss: String? = nil, mqtt: String? = nil) {
        self.https = normalizeEndpoint(https)
        self.wss = normalizeEndpoint(wss)
        self.mqtt = normalizeEndpoint(mqtt)
    }

    /// Reads endpoints from a resource carrying `data_plane_endpoints`,
    /// `endpoints`, or a bare endpoint mapping.
    public static func from(_ input: JSONValue?) -> HubDataPlaneEndpoints {
        guard let root = input?.objectValue else { return HubDataPlaneEndpoints() }
        let source = root["data_plane_endpoints"]?.objectValue
            ?? root["endpoints"]?.objectValue
            ?? root
        return HubDataPlaneEndpoints(
            https: optionalString(first(source, "https", "http")),
            wss: optionalString(first(source, "wss", "ws")),
            mqtt: optionalString(first(source, "mqtt", "mqtts"))
        )
    }

    public static func from(_ input: JSONObject) -> HubDataPlaneEndpoints {
        from(JSONValue.object(input))
    }

    /// Reads endpoints from a hub resource, deriving missing WSS/HTTPS
    /// endpoints from the hub `domain` for enabled protocols.
    public static func fromHub(_ hub: JSONObject) -> HubDataPlaneEndpoints {
        let endpoints = from(hub)
        let protocols = HubProtocolSettings.from(hub)
        guard let domain = optionalString(hub["domain"]) else { return endpoints }
        return HubDataPlaneEndpoints(
            https: endpoints.https ?? (protocols.http ? endpointFromDomain(domain, hubProtocol: .https) : nil),
            wss: endpoints.wss ?? (protocols.wss ? endpointFromDomain(domain, hubProtocol: .wss) : nil),
            mqtt: endpoints.mqtt
        )
    }

    public func endpointFor(_ hubProtocol: HubProtocol) -> String? {
        switch hubProtocol {
        case .https: return https
        case .wss: return wss
        case .mqtt: return mqtt
        }
    }

    /// Base URL used by the HTTP(S) data plane, falling back to the identity
    /// `default_master`/`default_port`/`default_path` when no HTTPS endpoint exists.
    public func httpBase(fallbackMaster: String, fallbackPort: Int, fallbackPath: String) -> String {
        if let https {
            return endpointBase(https, defaultPort: fallbackPort, defaultPath: "")
        }
        var master = fallbackMaster
        if master.hasPrefix("wss://") {
            master = "https://" + master.dropFirst("wss://".count)
        } else if master.hasPrefix("ws://") {
            master = "http://" + master.dropFirst("ws://".count)
        }
        return endpointBase(master, defaultPort: fallbackPort, defaultPath: fallbackPath)
    }

    public func asJSON(redactCredentials: Bool = false) -> JSONObject {
        var data: JSONObject = [:]
        for (key, value) in [("https", https), ("wss", wss), ("mqtt", mqtt)] {
            if let value {
                data[key] = .string(redactCredentials ? redactedCredentials(value) : value)
            }
        }
        return data
    }
}

/// Picks the first preferred protocol that is both enabled and has an endpoint.
public func selectDataPlaneEndpoint(
    endpoints: HubDataPlaneEndpoints,
    protocols: HubProtocolSettings,
    preferredProtocols: [HubProtocol] = defaultProtocolPreference
) -> SelectedHubEndpoint? {
    for hubProtocol in preferredProtocols {
        guard protocols.isEnabled(hubProtocol) else { continue }
        if let endpoint = endpoints.endpointFor(hubProtocol) {
            return SelectedHubEndpoint(hubProtocol: hubProtocol, endpoint: endpoint)
        }
    }
    return nil
}

/// Derives a protocol endpoint from a bare hub domain or an existing URL.
public func endpointFromDomain(_ domain: String, hubProtocol: HubProtocol) -> String {
    let normalized = trimTrailingSlashes(domain.trimmingCharacters(in: .whitespacesAndNewlines))
    let lowered = normalized.lowercased()
    switch hubProtocol {
    case .wss:
        if lowered.hasPrefix("wss://") || lowered.hasPrefix("ws://") {
            return normalizeEndpoint(normalized) ?? ""
        }
        if lowered.hasPrefix("https://") {
            return normalizeEndpoint("wss://" + normalized.dropFirst("https://".count)) ?? ""
        }
        if lowered.hasPrefix("http://") {
            return normalizeEndpoint("wss://" + normalized.dropFirst("http://".count)) ?? ""
        }
        return normalizeEndpoint("wss://" + normalized) ?? ""
    case .https:
        if lowered.hasPrefix("https://") {
            return normalizeEndpoint(normalized) ?? ""
        }
        if lowered.hasPrefix("http://") {
            return normalizeEndpoint("https://" + normalized.dropFirst("http://".count)) ?? ""
        }
        if lowered.hasPrefix("wss://") {
            return normalizeEndpoint("https://" + normalized.dropFirst("wss://".count)) ?? ""
        }
        if lowered.hasPrefix("ws://") {
            return normalizeEndpoint("https://" + normalized.dropFirst("ws://".count)) ?? ""
        }
        return normalizeEndpoint("https://" + normalized) ?? ""
    case .mqtt:
        return ""
    }
}

/// Normalizes a master URL to `scheme://host[:port][/path]`, applying the
/// default port and path when the URL does not carry its own.
func endpointBase(_ master: String, defaultPort: Int, defaultPath: String) -> String {
    guard var components = URLComponents(string: master), let scheme = components.scheme else {
        return trimTrailingSlashes(master) + ":\(defaultPort)" + defaultPath
    }
    if components.port == nil && !isDefaultPort(defaultPort, forScheme: scheme) {
        components.port = defaultPort
    }
    let joinedPath = [components.path, defaultPath]
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        .filter { !$0.isEmpty }
        .joined(separator: "/")
    components.path = joinedPath.isEmpty ? "" : "/" + joinedPath
    components.query = nil
    components.fragment = nil
    return trimTrailingSlashes(components.string ?? master)
}

private func isDefaultPort(_ port: Int, forScheme scheme: String) -> Bool {
    switch scheme.lowercased() {
    case "https", "wss": return port == 443
    case "http", "ws": return port == 80
    default: return false
    }
}

func first(_ values: JSONObject, _ keys: String...) -> JSONValue? {
    for key in keys {
        if let value = values[key] {
            return value
        }
    }
    return nil
}

func enabledValue(_ value: JSONValue?, fallback: Bool) -> Bool {
    switch value {
    case .bool(let flag):
        return flag
    case .string(let text):
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["1", "true", "yes", "on"].contains(normalized) { return true }
        if ["0", "false", "no", "off"].contains(normalized) { return false }
        return fallback
    case .object(let nested):
        return enabledValue(nested["enabled"], fallback: fallback)
    default:
        return fallback
    }
}

func optionalString(_ value: JSONValue?) -> String? {
    let normalized: String?
    switch value {
    case .string(let text):
        normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    case .integer(let number):
        normalized = String(number)
    case .number(let number):
        normalized = String(number)
    case .bool(let flag):
        normalized = flag ? "true" : "false"
    default:
        normalized = nil
    }
    guard let normalized, !normalized.isEmpty else { return nil }
    return normalized
}

func normalizeEndpoint(_ value: String?) -> String? {
    guard let raw = optionalString(value.map { JSONValue.string($0) }) else { return nil }
    guard let components = URLComponents(string: raw),
        let scheme = components.scheme?.lowercased(),
        ["http", "https", "ws", "wss", "mqtt", "mqtts"].contains(scheme),
        components.host != nil
    else {
        return nil
    }
    return trimTrailingSlashes(components.string ?? raw)
}

func trimTrailingSlashes(_ value: String) -> String {
    var result = value
    while result.hasSuffix("/") {
        result.removeLast()
    }
    return result
}

func redactedCredentials(_ value: String) -> String {
    guard var components = URLComponents(string: value) else { return value }
    components.user = nil
    components.password = nil
    return trimTrailingSlashes(components.string ?? value)
}
