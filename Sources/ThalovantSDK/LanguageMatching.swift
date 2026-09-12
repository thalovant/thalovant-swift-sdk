import Foundation

// OVOS-compatible CLDR distances, adapted from langcodes 3.5.1 (MIT).
// Versioned tables and attribution ship in ListingData.
private enum LanguageMatching {
    static let data = try! ListingRules.loadResource("language-matching")
    static func field(_ section: String, _ key: String) -> String? { data[section]?.objectValue?[key]?.stringValue }
    struct Tag { var language: String; var script = ""; var region = "" }
    static func script(_ value: String) -> Bool { value.utf8.count == 4 && value.utf8.allSatisfy { (97...122).contains($0) } }
    static func region(_ value: String) -> Bool { (value.utf8.count == 2 && value.utf8.allSatisfy { (97...122).contains($0) }) || (value.utf8.count == 3 && value.utf8.allSatisfy { (48...57).contains($0) }) }
    static func parse(_ raw: String, aliases: Bool = true) -> Tag {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-").lowercased()
        if aliases { value = field("languages",value)?.lowercased() ?? value }
        let tokens = value.components(separatedBy: "-"); let primary = tokens[0].isEmpty ? "und" : tokens[0]
        var base = aliases ? field("languages",primary).map { parse($0,aliases:false) } ?? Tag(language:primary) : Tag(language:primary)
        var onlyScript = true
        for token in tokens.dropFirst() {
            if !script(token) { onlyScript = false }
            if token.count == 1 { break }
            if script(token) { base.script = field("scripts",token) ?? token.prefix(1).uppercased()+token.dropFirst() }
            else if region(token) { base.region = field("territories",token) ?? token.uppercased() }
        }
        if base.script == field("default_scripts",base.language) { base.script = "" }
        if base.language == "pt" && base.script.isEmpty && base.region.isEmpty && onlyScript { base.region = "PT" }
        return base
    }
    static func maximize(_ original: Tag) -> Tag {
        var value = original
        if value.language == "und" && value.script.isEmpty && value.region.isEmpty { return Tag(language:"und",script:"Zzzz",region:"ZZ") }
        value.language = field("macrolanguages",value.language) ?? value.language
        func join(_ parts: String...) -> String { parts.filter { !$0.isEmpty }.joined(separator:"-") }
        var probes = [join(value.language,value.script,value.region),join(value.language,value.region),join(value.language,value.script),value.language]
        if !value.script.isEmpty { probes.append("und-"+value.script) }; probes.append("und")
        let parts = probes.compactMap { field("likely",$0) }.first!.components(separatedBy:"-")
        if value.language == "und" { value.language = parts[0] }; if value.script.isEmpty { value.script = parts[1] }; if value.region.isEmpty { value.region = parts[2] }; return value
    }
    static func distance(_ target: String, _ candidate: String) -> Int {
        let a = maximize(parse(target)); let b = maximize(parse(candidate))
        func lookup(_ from: String, _ to: String, _ fallback: Int) -> Int { data["distances"]?.objectValue?[from]?.objectValue?[to]?.intValue ?? fallback }
        var result = a.language == b.language ? 0 : lookup(a.language,b.language,80)
        let pa = a.language+"_"+a.script; let pb = b.language+"_"+b.script
        if a.script != b.script { result += lookup(pa,pb,50) }; if a.region == b.region { return result }
        func inside(_ group: String, _ region: String) -> Bool { data["regions"]?.objectValue?[group]?.arrayValue?.contains { $0.stringValue == region } ?? false }
        var td = 4
        if pa == pb {
            if a.language == "ar" { if inside("MAGHREB",a.region) != inside("MAGHREB",b.region) { td = 5 } }
            else if a.language == "en" {
                if (a.region == "GB" && !inside("US",b.region)) || (!inside("US",a.region) && b.region == "GB") { td = 3 }
                else if inside("US",a.region) != inside("US",b.region) { td = 5 }
            } else if inside("LATIN_AMERICA",a.region) && b.region == "419" { td = 1 }
            else if a.language == "es" || a.language == "pt" { if inside("AMERICAS",a.region) != inside("AMERICAS",b.region) { td = 5 } }
            else if pa == "zh_Hant" && inside("CNSAR",a.region) != inside("CNSAR",b.region) { td = 5 }
        }
        return result+td
    }
}

/// Nearest OVOS-compatible locale at distance ten or less; ties retain input order.
public func closestLanguage(_ target: String, available: [String]) -> String? {
    var best: String?; var minimum = Int.max
    for candidate in available { let distance = LanguageMatching.distance(target,candidate); if distance < minimum { best = candidate; minimum = distance } }
    return minimum <= 10 ? best : nil
}
