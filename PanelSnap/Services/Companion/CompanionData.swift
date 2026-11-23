import Foundation

struct TextBlock: Codable, Hashable {
    var text: String
    var source: String
    var url: String?
}

struct Fact: Codable, Hashable {
    var label: String
    var value: String
}

struct CharacterCard: Codable, Hashable, Identifiable {
    var name: String
    var role: String?
    var blurb: String?
    var imageURL: String?
    var url: String?
    var source: String?
    var facts: [Fact]? = nil

    var id: String { return name }
}

struct Credit: Codable, Hashable, Identifiable {
    var role: String
    var name: String

    var id: String { return role + "|" + name }
}

struct LinkItem: Codable, Hashable, Identifiable {
    var title: String
    var url: String

    var id: String { return url }
}

/// Everything the Companion panel can show about the comic being read.
struct CompanionData: Codable, Hashable {
    var series: String?
    var issue: String?
    var volume: String?
    var year: Int?
    var publisher: String?
    var title: String?
    var coverURL: String?
    var seriesSummary: TextBlock?
    var issueSummary: TextBlock?
    var issueSynopsis: TextBlock?        // may contain spoilers
    var issueYear: Int?                  // the year this issue was published (from the comics wiki)
    var characters: [CharacterCard] = []
    var teams: [String] = []
    var locations: [String] = []
    var creators: [Credit] = []
    var arcs: [String] = []
    var genres: [String] = []
    var links: [LinkItem] = []
    var sources: [String] = []
    var fetchedAt: Date?

    /// Fills in anything we don't know yet from `other`. Existing values always win.
    mutating func fill(from other: CompanionData) {
        if series == nil { series = other.series }
        if issue == nil { issue = other.issue }
        if volume == nil { volume = other.volume }
        if year == nil { year = other.year }
        if publisher == nil { publisher = other.publisher }
        if title == nil { title = other.title }
        if coverURL == nil { coverURL = other.coverURL }
        if seriesSummary == nil { seriesSummary = other.seriesSummary }
        if issueSummary == nil { issueSummary = other.issueSummary }
        if issueSynopsis == nil { issueSynopsis = other.issueSynopsis }
        if issueYear == nil { issueYear = other.issueYear }

        for c in other.characters {
            if let i = characters.firstIndex(where: { CompanionData.same($0.name, c.name) }) {
                if characters[i].blurb == nil { characters[i].blurb = c.blurb }
                if characters[i].imageURL == nil { characters[i].imageURL = c.imageURL }
                if characters[i].url == nil { characters[i].url = c.url }
                if characters[i].role == nil { characters[i].role = c.role }
                if characters[i].facts == nil { characters[i].facts = c.facts }
            } else {
                characters.append(c)
            }
        }
        teams = CompanionData.union(teams, other.teams)
        locations = CompanionData.union(locations, other.locations)
        arcs = CompanionData.union(arcs, other.arcs)
        genres = CompanionData.union(genres, other.genres)
        for c in other.creators {
            if !creators.contains(where: { CompanionData.same($0.name, c.name) && $0.role == c.role }) {
                creators.append(c)
            }
        }
        for l in other.links where !links.contains(where: { $0.url == l.url }) {
            links.append(l)
        }
        for s in other.sources where !sources.contains(s) {
            sources.append(s)
        }
    }

    static func same(_ a: String, _ b: String) -> Bool {
        return a.trimmingCharacters(in: .whitespaces).lowercased() == b.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func union(_ a: [String], _ b: [String]) -> [String] {
        var out = a
        for item in b where !out.contains(where: { same($0, item) }) {
            out.append(item)
        }
        return out
    }
}

enum CompanionCache {
    /// `variant` is empty for the whole file, or names one issue inside a collected edition.
    static func fileURL(for id: UUID, variant: String = "") -> URL {
        let safe = variant.isEmpty ? "" : "-" + variant.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "_", options: .regularExpression)
        return Paths.companionCache.appendingPathComponent(id.uuidString + safe + "-v2.json")
    }

    static func read(_ id: UUID, variant: String = "", maxAgeDays: Double) -> CompanionData? {
        guard let data = try? Data(contentsOf: fileURL(for: id, variant: variant)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(CompanionData.self, from: data) else { return nil }
        if let when = value.fetchedAt, Date().timeIntervalSince(when) > maxAgeDays * 86_400 { return nil }
        return value
    }

    static func write(_ id: UUID, variant: String = "", _ value: CompanionData) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) {
            try? data.write(to: fileURL(for: id, variant: variant), options: .atomic)
        }
    }
}
