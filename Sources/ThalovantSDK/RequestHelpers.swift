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

private let slotPattern = try! NSRegularExpression(pattern: #"\{([a-z_][a-z0-9_]*)\}"#)
private let spacesPattern = try! NSRegularExpression(pattern: #"\s{2,}"#)

/// Removes every balanced `opening ... closing` pair and what it holds, in one
/// pass: an opening never closed stays in the text, as does a closing that
/// closes nothing -- what taking the innermost pair out until none is left
/// does. Bytes, not characters: the brackets are ASCII, which never occurs
/// inside a multi-byte UTF-8 sequence, so every cut falls between code points.
func dropNested(_ text: String, opening: UInt8, closing: UInt8) -> String {
    let bytes = Array(text.utf8)
    guard bytes.contains(opening) else { return text }
    var frames: [[UInt8]] = [[]]
    for byte in bytes {
        if byte == opening {
            frames.append([])
        } else if byte == closing && frames.count > 1 {
            frames.removeLast()
        } else {
            frames[frames.count - 1].append(byte)
        }
    }
    // Openings never closed keep their character and what followed them.
    var result = frames[0]
    for frame in frames.dropFirst() {
        result.append(opening)
        result.append(contentsOf: frame)
    }
    return String(decoding: result, as: UTF8.self)
}

/// One alternative of a `( | )` group while it is read: runs of the pattern's
/// own text and the groups it holds that were kept, never copied.
private final class SpokenBranch {
    enum Part {
        case text(ArraySlice<Unicode.Scalar>)
        case kept(SpokenBranch)
    }
    var parts: [Part] = []
    /// Whether anything but white space is in it: a kept group always is.
    var real = false

    /// Trims white space from both ends, touching only the parts at the ends:
    /// a kept group was trimmed when it was kept.
    func trim() {
        let space = CharacterSet.whitespacesAndNewlines
        var first = 0
        while first < parts.count, case .text(let run) = parts[first] {
            let rest = run.drop { space.contains($0) }
            if !rest.isEmpty { parts[first] = .text(rest); break }
            first += 1
        }
        parts.removeFirst(first)
        var last = parts.count - 1
        while last >= 0, case .text(let run) = parts[last] {
            var end = run.endIndex
            while end > run.startIndex && space.contains(run[end - 1]) { end -= 1 }
            if end > run.startIndex { parts[last] = .text(run[run.startIndex..<end]); break }
            last -= 1
        }
        parts.removeLast(parts.count - 1 - last)
    }

    /// Writes this branch out, the groups it kept included, without recursing.
    func write(into out: inout String.UnicodeScalarView) {
        var stack: [(SpokenBranch, Int)] = [(self, 0)]
        while let (branch, index) = stack.popLast() {
            guard index < branch.parts.count else { continue }
            stack.append((branch, index + 1))
            switch branch.parts[index] {
            case .text(let run): out.append(contentsOf: run)
            case .kept(let child): stack.append((child, 0))
            }
        }
    }
}

/// Collapses every balanced `( | )` group to one alternative, innermost first,
/// in one linear pass: the first alternative with something in it, or nothing
/// when the group was optional -- an empty alternative beside at most one real
/// one, as in `(already |)ask`. An opening never closed stays, with its
/// alternatives, as does a closing that closes nothing.
///
/// A kept alternative is carried up as a reference, not copied into its
/// parent: copying it cost its length again at every level of nesting, so a
/// group sixteen thousand deep around sixteen thousand letters took a quarter
/// of a billion steps.
func chooseBranches(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    guard scalars.contains("(") else { return text }
    let space = CharacterSet.whitespacesAndNewlines
    var frames: [[SpokenBranch]] = [[SpokenBranch()]]
    var runStart = 0
    func flush(_ end: Int) {
        guard end > runStart, let branch = frames[frames.count - 1].last else { return }
        let run = scalars[runStart..<end]
        branch.parts.append(.text(run))
        if !branch.real && run.contains(where: { !space.contains($0) }) { branch.real = true }
    }
    for (index, scalar) in scalars.enumerated() {
        switch scalar {
        case "(":
            flush(index)
            frames.append([SpokenBranch()])
        case "|" where frames.count > 1:
            flush(index)
            frames[frames.count - 1].append(SpokenBranch())
        case ")" where frames.count > 1:
            flush(index)
            let options = frames.removeLast()
            let real = options.filter(\.real)
            if !(real.count < options.count && real.count <= 1), let kept = real.first,
               let parent = frames[frames.count - 1].last {
                kept.trim()
                parent.parts.append(.kept(kept))
                parent.real = true
            }
        default:
            continue
        }
        runStart = index + 1
    }
    flush(scalars.count)
    var out = String.UnicodeScalarView()
    frames[0][0].write(into: &out)
    // Openings never closed keep their character and their alternatives.
    for frame in frames.dropFirst() {
        out.append("(")
        for (position, branch) in frame.enumerated() {
            if position > 0 { out.append("|") }
            branch.write(into: &out)
        }
    }
    return String(out)
}

/// Render one illustrative sentence without inventing slot values.
///
/// `[please]` is optional and goes, `(repeat|say) that` collapses to its first
/// branch unless the group was optional, and `{slot}` becomes `slots[slot]`,
/// else the slot's name with its underscores as spaces. Nested parts resolve
/// innermost first, in one linear pass each: patterns come from hubs, and
/// taking the innermost pair out and starting again cost a pass per level of
/// nesting.
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
    var text = chooseBranches(dropNested(pattern, opening: UInt8(ascii: "["), closing: UInt8(ascii: "]")))
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
