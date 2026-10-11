import Foundation

/// A rule needed more matching work than one listing rule is allowed. The bound
/// counts work, not time, so the same rule on the same text is cut on every
/// machine or on none.
public enum ListingRuleError: Error { case regexBudgetExceeded }

/// Value-owned language data and immutable Foundation regexes, safe for concurrent readers.
public final class ListingRules: @unchecked Sendable {
    public static let bundled = try! ListingRules(data: loadResource("listing"))
    public let available: Bool
    public let sentenceEnds: String
    /// The longest text, in UTF-16 units, the rules are run on at all. A longer
    /// one is cut before any rule runs: `asks` throws and `asSentence` leaves
    /// the line bare. Listing phrases are sentences; the longest reference case
    /// is 34 characters.
    public static let maxRuleText = 1_000
    /// The matching work one call may spend across all its rules, in progress
    /// reports.
    ///
    /// NSRegularExpression (ICU) reports progress once per start position a
    /// search advances over and once per fixed slice of backtracking work
    /// (ICU's 10,000-step tick), never on a clock. An ordinary phrase costs
    /// about one report per character per rule: at most 8,000 with the bundled
    /// data at ``maxRuleText``. 10,000 is about a hundred million matcher
    /// steps, so only a pathological rule is cut, and it is cut the same way
    /// on every machine. This used to be a 100 ms wall-clock deadline, which a
    /// slow machine overran on an ordinary phrase: macOS CI wrote "Como esta el
    /// tiempo" with no full stop.
    public static let defaultStepLimit = 10_000
    internal let stepLimit: Int
    private let languages: [String: JSONValue]
    private let patterns: [String: [NSRegularExpression]]
    private let written: [String: [(NSRegularExpression,String)]]
    internal static func loadResource(_ name: String) throws -> JSONObject {
        guard let url = Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"ListingData") else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode(JSONObject.self,from:Data(contentsOf:url))
    }
    private static func compile(_ expression: String, ignoreCase: Bool) throws -> NSRegularExpression {
        let boundary = #"(?:(?<![\p{L}\p{N}_])(?=[\p{L}\p{N}_])|(?<=[\p{L}\p{N}_])(?![\p{L}\p{N}_]))"#
        let nonBoundary = #"(?:(?=[\s\S])|(?<=[\s\S]))(?:(?<=[\p{L}\p{N}_])(?=[\p{L}\p{N}_])|(?<![\p{L}\p{N}_])(?![\p{L}\p{N}_]))"#
        let chars = Array(expression); var result = ""; var inClass = false; var i = 0
        while i < chars.count {
            let char = chars[i]; i += 1
            if char == "\\" && i < chars.count {
                let next = chars[i]; i += 1
                if next == "b" && !inClass { result += boundary } else if next == "B" && !inClass { result += nonBoundary } else { result.append(char); result.append(next) }
            } else { if char == "[" { inClass = true }; if char == "]" { inClass = false }; result.append(char) }
        }
        return try NSRegularExpression(pattern:result,options:ignoreCase ? [.caseInsensitive] : [])
    }
    /// Nil selects bare rendering. Invalid custom regexes fail construction.
    public convenience init(data: JSONObject?) throws { try self.init(data: data, stepLimit: Self.defaultStepLimit) }
    internal init(data: JSONObject?, stepLimit: Int) throws {
        self.stepLimit = stepLimit
        available = data != nil
        sentenceEnds = data?["sentence_ends"]?.stringValue ?? ""
        languages = data?["languages"]?.objectValue ?? [:]
        var questions: [String:[NSRegularExpression]] = [:]; var forms: [String:[(NSRegularExpression,String)]] = [:]
        for (tag,value) in languages {
            let rules = value.objectValue ?? [:]
            questions[tag] = try (rules["question_patterns"]?.arrayValue ?? []).compactMap(\.stringValue).map { try Self.compile($0,ignoreCase:true) }
            let replacements = rules["written_forms"]?.objectValue ?? [:]
            forms[tag] = try replacements.keys.sorted().map { (try Self.compile(#"\b"#+NSRegularExpression.escapedPattern(for:$0)+#"\b"#,ignoreCase:false),replacements[$0]?.stringValue ?? "") }
        }
        patterns = questions; written = forms
    }
    private func tag(_ lang: String?) -> String? { guard let lang, !lang.isEmpty else { return nil }; return closestLanguage(lang,available:languages.keys.sorted()) }
    public func languageData(_ lang: String?) -> JSONObject { tag(lang).flatMap { languages[$0]?.objectValue } ?? [:] }
    private func values(_ data: JSONObject, _ key: String) -> [String] { (data[key]?.arrayValue ?? []).compactMap(\.stringValue) }
    private func words(_ text: String) -> [String] { text.components(separatedBy:.whitespacesAndNewlines).filter { !$0.isEmpty } }
    private func wordSet(_ lang: String?, _ key: String) -> Set<String> {
        let sources = (lang?.isEmpty ?? true) ? languages.values.compactMap(\.objectValue) : [languageData(lang)]
        return Set(sources.flatMap { values($0,key) }.map { $0.lowercased() })
    }
    public func dangling(_ text: String, lang: String? = nil) -> Bool {
        guard let last = words(text.trimmingCharacters(in:CharacterSet(charactersIn:sentenceEnds+" "))).last else { return false }
        return wordSet(lang,"trailing_words").contains(last.lowercased())
    }
    /// Progress reports left for one call, shared by every rule it runs.
    private final class Budget { var remaining: Int; init(_ remaining: Int) { self.remaining = remaining } }
    private func matches(_ pattern: NSRegularExpression, _ text: String, firstOnly: Bool, budget: Budget) throws -> [NSTextCheckingResult] {
        guard text.utf16.count <= Self.maxRuleText else { throw ListingRuleError.regexBudgetExceeded }
        var found: [NSTextCheckingResult] = []; var exceeded = false
        pattern.enumerateMatches(in:text,options:[.reportProgress],range:NSRange(text.startIndex...,in:text)) { match, flags, stop in
            if flags.contains(.internalError) { exceeded = true; stop.pointee = true; return }
            if let match { found.append(match); if firstOnly { stop.pointee = true }; return }
            if flags.contains(.progress) { budget.remaining -= 1; if budget.remaining < 0 { exceeded = true; stop.pointee = true } }
        }
        if exceeded { throw ListingRuleError.regexBudgetExceeded }; return found
    }
    /// Throws when the text is longer than ``maxRuleText`` or the rules need
    /// more than ``defaultStepLimit`` progress reports on it.
    public func asks(_ text: String, lang: String? = nil) throws -> Bool { try asks(text, lang: lang, budget: Budget(stepLimit)) }
    private func asks(_ text: String, lang: String?, budget: Budget) throws -> Bool {
        if !available { return false }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = text.unicodeScalars.last, Set<UInt32>([0x3f, 0xbf, 0x37e, 0x55e, 0x61f, 0x1367, 0x1945, 0x2047, 0x2049, 0x2753, 0x2754, 0x2a7b, 0x2a7c, 0x2cfa, 0x2cfb, 0x2e2e, 0x2e54, 0xa60f, 0xa6f7, 0xfe16, 0xfe56, 0xff1f, 0x11143, 0x1e95f, 0x1fbc4, 0xe003f]).contains(last.value) { return true }
        let rules = (lang == nil || lang == "") ? patterns.values.flatMap { $0 } : patterns[tag(lang) ?? ""] ?? []
        for pattern in rules { if try !matches(pattern,text,firstOnly:true,budget:budget).isEmpty { return true } }
        let words = words(text).map { $0.trimmingCharacters(in:CharacterSet(charactersIn:",;:!?.’'\"()")).lowercased() }.filter { !$0.isEmpty }
        let openers = wordSet(lang,"question_openers"); let anywhere = wordSet(lang,"question_words_anywhere")
        return words.first.map { openers.contains($0) } == true || words.contains { anywhere.contains($0) }
    }
    /// Unknown, dangling or failed rules leave a bare line instead of guessing marks.
    public func asSentence(_ raw: String, lang: String? = nil) -> String {
        let budget = Budget(stepLimit)
        var text = raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let first = text.unicodeScalars.first else { return text }
        let index = text.unicodeScalars.index(after:text.unicodeScalars.startIndex)
        text = String(first).uppercased()+String(text.unicodeScalars[index...])
        if text.unicodeScalars.last.map({ sentenceEnds.unicodeScalars.contains($0) }) == true || dangling(text,lang:lang) { return text }
        guard let tag = tag(lang) else { return text }; let data = languageData(lang)
        guard ["question_openers","question_words_anywhere","question_patterns"].contains(where:{ !values(data,$0).isEmpty }) else { return text }
        do {
            for (pattern,replacement) in written[tag] ?? [] {
                var next = ""; var previous = text.startIndex
                for match in try matches(pattern,text,firstOnly:false,budget:budget) {
                    guard let range = Range(match.range,in:text) else { return text }
                    next += text[previous..<range.lowerBound]; next += replacement; previous = range.upperBound
                }
                next += text[previous...]; text = next
            }
            text += try asks(text,lang:lang,budget:budget) ? "?" : "."
        } catch { return text }
        return text
    }
    public func speakable(_ pattern: String, slots: [String:String] = [:], lang: String? = nil) -> String {
        var merged = (languageData(lang)["slot_examples"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        merged.merge(slots) { _,override in override }; return ThalovantSDK.speakable(pattern,slots:merged)
    }
    public func rank(_ phrases: [String], lang: String? = nil) -> [String] {
        let rows = phrases.enumerated().map { index,text in (text,[dangling(text,lang:lang) ? 1 : 0,text.contains("{") ? 1 : 0,-min(words(text).count,8),text.unicodeScalars.count,index]) }
        return rows.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map { $0.0 }
    }
}

public func asSentence(_ text: String, lang: String? = nil, listing: ListingRules = .bundled) -> String { listing.asSentence(text,lang:lang) }
public func speakableWithLanguage(_ pattern: String, slots: [String:String] = [:], lang: String? = nil, listing: ListingRules = .bundled) -> String { listing.speakable(pattern,slots:slots,lang:lang) }
