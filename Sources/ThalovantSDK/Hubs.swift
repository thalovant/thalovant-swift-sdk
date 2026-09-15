import Foundation

/// What to call a hub on a screen somebody is reading.
///
/// Every control-plane read in this SDK returns raw JSON, so each caller picks
/// its own fields -- and on 2026-09-15 a phone offered somebody a list of
/// rooms called "ops-copilot", "daily-desk", "news-stream". Those are slugs.
/// The app was not careless: it read `name` and preferred it over `slug`, and
/// on that deployment `name` *holds* the slug. The name a person was shown when
/// the hub was made lives in `spec.catalog.title`.
///
/// One place to get that wrong is better than one per app.
public func hubDisplayName(_ hub: JSONObject) -> String {
    func text(_ value: JSONValue?) -> String? {
        guard let raw = value?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    if let catalog = hub["spec"]?.objectValue?["catalog"]?.objectValue,
       let title = text(catalog["title"]) {
        return title
    }

    let name = text(hub["name"])
    let slug = text(hub["slug"])
    // A name that is exactly the slug is the slug.
    if let name, name != slug { return name }

    guard let identifier = name ?? slug else { return "A Thalovant hub" }
    let words = identifier
        .split(whereSeparator: { $0 == "-" || $0 == "_" })
        .map { word -> String in word.prefix(1).uppercased() + word.dropFirst() }
    let readable = words.joined(separator: " ")
    return readable.isEmpty ? "A Thalovant hub" : readable
}
