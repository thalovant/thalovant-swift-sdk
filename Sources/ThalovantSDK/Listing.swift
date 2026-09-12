import Foundation
import Dispatch

public enum ListingRuleError: Error { case regexBudgetExceeded }

/// Value-owned language data and immutable Foundation regexes, safe for concurrent readers.
public final class ListingRules: @unchecked Sendable {
    public static let bundled = try! ListingRules(data: loadResource("listing"))
    public let available: Bool
    public let sentenceEnds: String
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
    public init(data: JSONObject?) throws {
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
    private func matches(_ pattern: NSRegularExpression, _ text: String, firstOnly: Bool) throws -> [NSTextCheckingResult] {
        let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
        var found: [NSTextCheckingResult] = []; var interrupted = false
        pattern.enumerateMatches(in:text,options:[.reportProgress,.reportCompletion],range:NSRange(text.startIndex...,in:text)) { match, flags, stop in
            if DispatchTime.now().uptimeNanoseconds >= deadline || flags.contains(.internalError) { interrupted = true; stop.pointee = true; return }
            if let match { found.append(match); if firstOnly { stop.pointee = true } }
        }
        if interrupted { throw ListingRuleError.regexBudgetExceeded }; return found
    }
    /// Throws when a custom rule exceeds its bounded evaluation window.
    public func asks(_ text: String, lang: String? = nil) throws -> Bool {
        if let tag = tag(lang) { for pattern in patterns[tag] ?? [] { if try !matches(pattern,text,firstOnly:true).isEmpty { return true } } }
        let words = words(text).map { $0.trimmingCharacters(in:CharacterSet(charactersIn:",;:!?.’'\"()")).lowercased() }.filter { !$0.isEmpty }
        let openers = wordSet(lang,"question_openers"); let anywhere = wordSet(lang,"question_words_anywhere")
        return words.first.map { openers.contains($0) } == true || words.contains { anywhere.contains($0) }
    }
    /// Unknown, dangling or failed rules leave a bare line instead of guessing marks.
    public func asSentence(_ raw: String, lang: String? = nil) -> String {
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
                for match in try matches(pattern,text,firstOnly:false) {
                    guard let range = Range(match.range,in:text) else { return text }
                    next += text[previous..<range.lowerBound]; next += replacement; previous = range.upperBound
                }
                next += text[previous...]; text = next
            }
            text += try asks(text,lang:lang) ? "?" : "."
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
