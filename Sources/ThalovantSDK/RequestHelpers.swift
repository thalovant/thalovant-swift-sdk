import Foundation

/// Build the request location shape read by OVOS skills. City is required.
public func buildLocation(city: String = "", region: String = "", country: String = "",
                          latitude: Double? = nil, longitude: Double? = nil, timezone: String = "") -> JSONObject? {
    let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard !trim(city).isEmpty else { return nil }
    var result: JSONObject = ["city": .string(trim(city))]
    if !trim(region).isEmpty { result["region"] = .string(trim(region)) }
    if !trim(country).isEmpty { result["country_code"] = .string(trim(country).uppercased()) }
    if !trim(timezone).isEmpty { result["timezone"] = .object(["code": .string(trim(timezone))]) }
    if let lat = latitude, let lon = longitude, (lat != 0 || lon != 0), (-90...90).contains(lat), (-180...180).contains(lon) {
        result["coordinate"] = .object(["latitude": .number(lat), "longitude": .number(lon)])
    }
    return result
}
public func requestContext(_ context: JSONObject = [:], sttLang: String? = nil, pipeline: [String]? = nil, location: JSONObject? = nil) -> JSONObject? {
    var result = context
    let stages = (pipeline ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    if !stages.isEmpty {
        var session = result["session"]?.objectValue ?? [:]; session["pipeline"] = .array(stages.map(JSONValue.string)); result["session"] = .object(session)
    }
    if let lang = sttLang?.trimmingCharacters(in: .whitespacesAndNewlines), !lang.isEmpty { result["stt_lang"] = .string(lang) }
    if let location, !location.isEmpty { result["location"] = .object(location) }
    return result.isEmpty ? nil : result
}

extension ThalovantClient {
    public func askWithHints(_ text: String, sttLang: String? = nil, pipeline: [String]? = nil, location: JSONObject? = nil,
        timeout: TimeInterval = 12, lang: String = "en-us", context: JSONObject = [:], sessionId: String? = nil,
        requestId: String? = nil, replySettle: TimeInterval? = nil, emptyReplyWait: TimeInterval? = nil) async throws -> ThalovantReply {
        try await ask(text, timeout: timeout, lang: lang, context: requestContext(context, sttLang: sttLang, pipeline: pipeline, location: location) ?? [:],
            sessionId: sessionId, requestId: requestId, replySettle: replySettle, emptyReplyWait: emptyReplyWait)
    }
}

private let optionalPattern = try! NSRegularExpression(pattern: #"\[[^\[\]]*\]"#)
private let groupPattern = try! NSRegularExpression(pattern: #"\(([^()]*)\)"#)
private let slotPattern = try! NSRegularExpression(pattern: #"\{([a-z_][a-z0-9_]*)\}"#)
private let spacesPattern = try! NSRegularExpression(pattern: #"\s{2,}"#)
/// Render one illustrative sentence without inventing slot values.
public func speakable(_ pattern: String, slots: [String: String] = [:]) -> String {
    func replace(_ text: String, _ regex: NSRegularExpression, _ transform: (String) -> String) -> String {
        var result = text
        let source = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(source.substring(with: match.range)))
        }
        return result
    }
    var text = pattern
    while optionalPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { text = replace(text, optionalPattern) { _ in "" } }
    while groupPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
        text = replace(text, groupPattern) { group in
            let options = group.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let real = options.filter { !$0.isEmpty }
            return real.count < options.count && real.count <= 1 ? "" : real.first ?? ""
        }
    }
    text = replace(text, slotPattern) { slot in let key = String(slot.dropFirst().dropLast()); return slots[key] ?? key.replacingOccurrences(of: "_", with: " ") }
    return replace(text, spacesPattern) { _ in " " }.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
}

public let maxAudioClipBytes = 4 * 1024 * 1024
public let maxReplyMediaBytes = 16 * 1024 * 1024
struct ReplyMediaBudget {
    private var chars = 0
    private(set) var dropped = 0
    mutating func accept(_ event: ThalovantEvent) -> Bool {
        guard event.isAudio else { return true }
        guard let encoded = event.data["binary_data"]?.stringValue, encoded.utf8.count <= maxAudioClipBytes * 2,
            chars + encoded.utf8.count <= maxReplyMediaBytes * 2 else { dropped += 1; return false }
        chars += encoded.utf8.count; return true
    }
}
