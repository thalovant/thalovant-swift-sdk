import Foundation

/// A HiveMind wire frame. Field names and null placeholders match the frames
/// produced by the Node SDK's WSS transport byte-for-byte in structure:
/// `msg_type`, `payload`, `metadata`, `route`, `node`, `target_site_id`,
/// `target_pubkey`, `source_peer` are always present.
public struct HiveMessage: Codable, Equatable, Sendable {
    public var msgType: String
    public var payload: JSONObject
    public var metadata: JSONObject
    public var route: [JSONValue]
    public var node: String?
    public var targetSiteId: String?
    public var targetPubkey: String?
    public var sourcePeer: String?

    enum CodingKeys: String, CodingKey {
        case msgType = "msg_type"
        case payload
        case metadata
        case route
        case node
        case targetSiteId = "target_site_id"
        case targetPubkey = "target_pubkey"
        case sourcePeer = "source_peer"
    }

    public init(
        msgType: String,
        payload: JSONObject,
        metadata: JSONObject = [:],
        route: [JSONValue] = [],
        node: String? = nil,
        targetSiteId: String? = nil,
        targetPubkey: String? = nil,
        sourcePeer: String? = nil
    ) {
        self.msgType = msgType
        self.payload = payload
        self.metadata = metadata
        self.route = route
        self.node = node
        self.targetSiteId = targetSiteId
        self.targetPubkey = targetPubkey
        self.sourcePeer = sourcePeer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.msgType = try container.decode(String.self, forKey: .msgType)
        self.payload = try container.decodeIfPresent(JSONObject.self, forKey: .payload) ?? [:]
        self.metadata = try container.decodeIfPresent(JSONObject.self, forKey: .metadata) ?? [:]
        self.route = try container.decodeIfPresent([JSONValue].self, forKey: .route) ?? []
        self.node = try container.decodeIfPresent(String.self, forKey: .node)
        self.targetSiteId = try container.decodeIfPresent(String.self, forKey: .targetSiteId)
        self.targetPubkey = try container.decodeIfPresent(String.self, forKey: .targetPubkey)
        self.sourcePeer = try container.decodeIfPresent(String.self, forKey: .sourcePeer)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(msgType, forKey: .msgType)
        try container.encode(payload, forKey: .payload)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(route, forKey: .route)
        // Explicit nulls: the runtime expects these keys on every frame.
        try container.encode(node, forKey: .node)
        try container.encode(targetSiteId, forKey: .targetSiteId)
        try container.encode(targetPubkey, forKey: .targetPubkey)
        try container.encode(sourcePeer, forKey: .sourcePeer)
    }
}

/// Pure encode/decode helpers for the HiveMind WSS wire protocol.
public enum HiveWire {
    /// The `authorization` credential sent on connect:
    /// `base64("<user agent>:<access key>")`.
    public static func authorization(userAgent: String, accessKey: String) -> String {
        Data("\(userAgent):\(accessKey)".utf8).base64EncodedString()
    }

    /// Appends the `authorization` query parameter to a `ws://`/`wss://` endpoint.
    public static func authorizedEndpoint(_ endpoint: String, authorization: String) throws -> URL {
        guard var components = URLComponents(string: endpoint),
            let scheme = components.scheme?.lowercased(),
            ["ws", "wss"].contains(scheme)
        else {
            throw ThalovantConnectionError("WSS endpoint must start with ws:// or wss://.")
        }
        var queryItems = (components.queryItems ?? []).filter { $0.name != "authorization" }
        queryItems.append(URLQueryItem(name: "authorization", value: authorization))
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ThalovantConnectionError("WSS endpoint is not a valid URL: \(endpoint)")
        }
        return url
    }

    /// The `hello` frame answering a preshared-key handshake.
    public static func helloMessage(siteId: String, publicKey: String?, sessionId: String) -> HiveMessage {
        HiveMessage(
            msgType: "hello",
            payload: [
                "pubkey": .string(publicKey ?? ""),
                "session": .object(["session_id": .string(sessionId)]),
                "site_id": .string(siteId),
            ]
        )
    }

    /// A `bus` frame carrying a `{type, data, context}` event payload.
    public static func busMessage(type: String, data: JSONObject, context: JSONObject) -> HiveMessage {
        HiveMessage(
            msgType: "bus",
            payload: [
                "type": .string(type),
                "data": .object(data),
                "context": .object(context),
            ]
        )
    }

    /// Serializes a frame for the socket. When `encrypt` is set and a crypto
    /// key is available the JSON is wrapped in the AES-128-GCM envelope.
    public static func encode(_ message: HiveMessage, cryptoKey: String? = nil, encrypt: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let serialized = String(decoding: try encoder.encode(message), as: UTF8.self)
        guard encrypt, let cryptoKey, ThalovantCrypto.runtimeKey(cryptoKey) != nil else {
            return serialized
        }
        return try ThalovantCrypto.encryptJSON(key: cryptoKey, plaintext: serialized)
    }

    /// Parses an incoming text frame, transparently decrypting `{"ciphertext": ...}`
    /// envelopes when a crypto key is available.
    public static func decode(text: String, cryptoKey: String? = nil) throws -> HiveMessage {
        let object: JSONObject
        do {
            object = try ThalovantJSON.decodeObject(text)
        } catch {
            throw ThalovantConnectionError("HiveMind frame is not valid JSON.")
        }
        if object["ciphertext"] != nil, let cryptoKey {
            let plaintext = try ThalovantCrypto.decryptJSON(key: cryptoKey, envelope: object)
            return try JSONDecoder().decode(HiveMessage.self, from: Data(plaintext.utf8))
        }
        return try JSONDecoder().decode(HiveMessage.self, from: Data(text.utf8))
    }

    /// Parses an incoming binary frame by treating it as UTF-8 JSON.
    public static func decode(data: Data, cryptoKey: String? = nil) throws -> HiveMessage {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ThalovantConnectionError("HiveMind binary frame is not UTF-8 JSON.")
        }
        return try decode(text: text, cryptoKey: cryptoKey)
    }

    /// True when a `handshake`/`shake` payload is a preshared-key challenge
    /// (the only handshake style the SDK supports).
    public static func isPresharedKeyHandshake(_ payload: JSONObject) -> Bool {
        isTruthy(payload["preshared_key"])
            && !isTruthy(payload["handshake"])
            && !isTruthy(payload["envelope"])
    }

    private static func isTruthy(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .some(.null):
            return false
        case .some(.bool(let flag)):
            return flag
        case .some(.integer(let number)):
            return number != 0
        case .some(.number(let number)):
            return number != 0
        case .some(.string(let text)):
            return !text.isEmpty
        case .some(.array), .some(.object):
            return true
        }
    }
}
