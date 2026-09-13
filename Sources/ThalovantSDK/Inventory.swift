import Foundation

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

public let inventoryCacheVersion = 1
public let inventoryCacheTTL: TimeInterval = 3600
public let hubSource = "hub"
public let liveSources: Set<String> = ["hub", "ovos-runtime"]

public struct Intent: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let skillId: String
  public let engine: String
  public let phrases: [String: [String]]
  public let languages: [String]
  enum CodingKeys: String, CodingKey {
    case id, name, engine, phrases, languages
    case skillId = "skill_id"
  }
  public init(
    id: String, name: String, skillId: String, engine: String, phrases: [String: [String]] = [:],
    languages: [String]? = nil
  ) {
    self.id = id
    self.name = name
    self.skillId = skillId
    self.engine = engine
    self.phrases = phrases
    self.languages = orderedUnique((languages ?? []) + phrases.keys.sorted()).filter {
      phrases[$0] != nil
    }
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try values.decode(String.self, forKey: .id),
      name: try values.decode(String.self, forKey: .name),
      skillId: try values.decode(String.self, forKey: .skillId),
      engine: try values.decode(String.self, forKey: .engine),
      phrases: try values.decode([String: [String]].self, forKey: .phrases),
      languages: try values.decodeIfPresent([String].self, forKey: .languages))
  }
  public func examples(language: String? = nil, limit: Int = 3) -> [String] {
    let tag: String? = language.flatMap {
      $0.isEmpty ? nil : closestLanguage($0, available: languages)
    }
    let pool =
      (language == nil || language == "")
      ? languages.first.flatMap { phrases[$0] } ?? [] : tag.flatMap { phrases[$0] } ?? []
    return limit <= 0 ? pool : Array(ListingRules.bundled.rank(pool, lang: language).prefix(limit))
  }
}
public struct Skill: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let locales: [String]
  public let intents: [Intent]
  public init(id: String, title: String, locales: [String] = [], intents: [Intent] = []) {
    self.id = id
    self.title = title
    self.locales = locales
    self.intents = intents
  }
  public var declaresLocales: Bool { !locales.isEmpty }
  public func speaks(_ language: String) -> Bool? {
    locales.isEmpty ? nil : closestLanguage(language, available: locales) != nil
  }
}
public struct Inventory: Codable, Equatable, Sendable {
  public let cacheVersion: Int
  public let hubId: String
  public let hubName: String
  public let source: String
  public let generatedAt: String
  public let skills: [Skill]
  public let notes: [String]
  enum CodingKeys: String, CodingKey {
    case source, skills, notes
    case cacheVersion = "cache_version"
    case hubId = "hub_id"
    case hubName = "hub_name"
    case generatedAt = "generated_at"
  }
  public init(
    hubId: String, hubName: String, source: String, generatedAt: String, skills: [Skill] = [],
    notes: [String] = []
  ) {
    cacheVersion = inventoryCacheVersion
    self.hubId = hubId
    self.hubName = hubName
    self.source = source
    self.generatedAt = generatedAt
    self.skills = skills
    self.notes = notes
  }
  public var live: Bool { liveSources.contains(source) }
  public var intents: [Intent] { skills.flatMap(\.intents) }
  public var hasPhrases: Bool { intents.contains { !$0.phrases.isEmpty } }
  public func asJSON() throws -> Data {
    guard cacheVersion == inventoryCacheVersion else {
      throw ThalovantRuntimeError("Not a current inventory cache")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }
  public static func fromJSON(_ data: Data) throws -> Inventory {
    let value = try JSONDecoder().decode(Inventory.self, from: data)
    guard value.cacheVersion == inventoryCacheVersion else {
      throw ThalovantRuntimeError("Not a current inventory cache")
    }
    return value
  }
}
public func languagesPresent(_ inventory: Inventory) -> [String] {
  Set(inventory.skills.flatMap { $0.locales + $0.intents.flatMap { Array($0.phrases.keys) } })
    .sorted()
}
public func friendlyTitle(_ skillId: String) -> String {
  var name = skillId
  for prefix in ["thalovant-skill-", "ovos-skill-", "skill-"] where name.hasPrefix(prefix) {
    name = String(name.dropFirst(prefix.count))
    break
  }
  if let dot = name.lastIndex(of: ".") { name = String(name[..<dot]) }
  name = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return name.isEmpty
    ? skillId : name.lowercased().capitalized(with: Locale(identifier: "en_US_POSIX"))
}
private func inventoryTokens(_ name: String) -> [String] {
  name.split(whereSeparator: { $0 == "." || $0 == "_" }).map(String.init)
}
public func humanize(_ name: String) -> String { inventoryTokens(name).joined(separator: " ") }
public func commonAffix(_ names: [String]) -> (kind: String?, token: String) {
  let parts = names.map(inventoryTokens)
  guard parts.count >= 2, parts.allSatisfy({ $0.count >= 2 }) else { return (nil, "") }
  if Set(parts.map { $0.last! }).count == 1 { return ("suffix", parts[0].last!) }
  if Set(parts.map { $0.first! }).count == 1 { return ("prefix", parts[0].first!) }
  return (nil, "")
}
public func stripAffix(_ name: String, kind: String?, token: String) -> String {
  guard let kind else { return name }
  var parts = inventoryTokens(name)
  if kind == "suffix", parts.last == token {
    parts.removeLast()
  } else if kind == "prefix", parts.first == token {
    parts.removeFirst()
  }
  return parts.isEmpty ? name : parts.joined(separator: " ")
}
public func compareNames(_ left: String, _ right: String) -> ComparisonResult {
  func chunks(_ value: String) -> [String] {
    var out = [String]()
    var numeric: Bool?
    for scalar in value.lowercased().unicodeScalars {
      let now = (48...57).contains(scalar.value)
      if numeric != now {
        out.append("")
        numeric = now
      }
      out[out.count - 1].unicodeScalars.append(scalar)
    }
    return out
  }
  let a = chunks(left)
  let b = chunks(right)
  for (x, y) in zip(a, b) {
    let nx = x.utf8.first.map { (48...57).contains($0) }!
    let ny = y.utf8.first.map { (48...57).contains($0) }!
    if nx != ny { return nx ? .orderedAscending : .orderedDescending }
    let xx = nx ? String(x.drop(while: { $0 == "0" })) : x
    let yy = ny ? String(y.drop(while: { $0 == "0" })) : y
    if nx && xx.count != yy.count {
      return xx.count < yy.count ? .orderedAscending : .orderedDescending
    }
    if xx != yy {
      return xx.unicodeScalars.lexicographicallyPrecedes(yy.unicodeScalars)
        ? .orderedAscending : .orderedDescending
    }
  }
  return a.count == b.count
    ? .orderedSame : a.count < b.count ? .orderedAscending : .orderedDescending
}
public func identityHost(_ identity: URL?) -> String? {
  guard let identity, let data = try? Data(contentsOf: identity),
    let object = try? JSONDecoder().decode(JSONObject.self, from: data),
    let master = object["default_master"]?.stringValue
  else { return nil }
  return URLComponents(string: master)?.host
}
public struct InventoryCache: Sendable {
  public let directory: URL
  public let ttl: TimeInterval
  public init(directory: URL? = nil, ttl: TimeInterval = inventoryCacheTTL) throws {
    guard ttl.isFinite && ttl >= 0 else {
      throw ThalovantRuntimeError("Cache TTL must be finite and nonnegative")
    }
    let root =
      ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap {
        $0.isEmpty ? nil : URL(fileURLWithPath: $0)
      } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
    self.directory = directory ?? root.appendingPathComponent("thalovant")
    self.ttl = ttl
  }
  public static func key(mode: String, identity: URL? = nil) -> String {
    let host = identityHost(identity) ?? "local"
    let readable = String(
      host.unicodeScalars.map { scalar -> Character in
        (scalar.isASCII
          && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar)))
          ? Character(scalar) : "-"
      }.prefix(40))
    return
      "\(mode)-\(readable)-\(noiseHex(noiseHash(Data("\(mode)|\(identity?.path ?? "")".utf8))).prefix(8))"
  }
  public func path(_ key: String) throws -> URL {
    guard !key.isEmpty, key.utf8.count <= 160,
      key.unicodeScalars.allSatisfy({
        $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
      })
    else { throw ThalovantRuntimeError("Invalid inventory cache key") }
    return directory.appendingPathComponent("intents-\(key).json")
  }
  public func load(_ key: String) -> Inventory? {
    guard let file = try? path(key),
      let info = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
      let modified = info.contentModificationDate, let size = info.fileSize,
      size <= 8 * 1024 * 1024, Date().timeIntervalSince(modified) <= ttl,
      let raw = try? Data(contentsOf: file)
    else { return nil }
    return try? Inventory.fromJSON(raw)
  }
  public func store(_ key: String, inventory: Inventory) {
    guard let target = try? path(key), let raw = try? inventory.asJSON() else { return }
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch { return }
    let scratch = directory.appendingPathComponent(".intents-\(UUID().uuidString).partial")
    let fd = open(scratch.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
    guard fd >= 0 else { return }
    defer {
      _ = close(fd)
      _ = unlink(scratch.path)
    }
    let complete = raw.withUnsafeBytes { buffer -> Bool in
      guard let base = buffer.baseAddress else { return false }
      var offset = 0
      while offset < buffer.count {
        let count = write(fd, base.advanced(by: offset), buffer.count - offset)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { return false }
        offset += count
      }
      return true
    }
    guard complete, fsync(fd) == 0 else { return }
    _ = rename(scratch.path, target.path)
  }
}
