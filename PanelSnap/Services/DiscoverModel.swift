import Foundation

/// One comic on the weekly release list.
struct DiscoverComic: Identifiable, Hashable {
    let id: String
    var title: String
    var publisher: String
    var price: String
    var creators: String
    var date: String
    var summary: String
    var diamondID: String

    /// The official catalogue page (Diamond / PreviewsWorld) for this item, when it has an ID.
    var listingURL: URL? {
        guard !diamondID.isEmpty else { return nil }
        return URL(string: "https://www.previewsworld.com/Catalog/" + diamondID)
    }

    var coverURL: URL? {
        guard !diamondID.isEmpty else { return nil }
        return URL(string: "https://www.previewsworld.com/SiteImage/CatalogImage/" + diamondID + "?type=1")
    }

    /// What to type into a download site's search box: the series name and issue number, without variant text.
    var searchTerm: String {
        var t = title
        t = t.replacingOccurrences(of: "\\(.*?\\)", with: " ", options: .regularExpression)
        for marker in [" CVR", " VAR", " 1:", " 2ND PTG", " 3RD PTG", " FOIL", " DIRECT MARKET", " POLYBAG"] {
            if let r = t.range(of: marker, options: .caseInsensitive) { t = String(t[..<r.lowerBound]) }
        }
        t = t.replacingOccurrences(of: "#", with: " ")
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces).capitalized
    }
}

enum ReleaseWeek: String, CaseIterable, Identifiable {
    case previous, new, future
    var id: String { return rawValue }
    var label: String {
        switch self {
        case .previous: return "Last Week"
        case .new: return "This Week"
        case .future: return "Next Week"
        }
    }
}

/// Weekly comic-shop release lists from the free ShortBoxed service (no account or key), which mirrors the
/// publishers' Diamond new-release lists.
@MainActor
final class DiscoverModel: ObservableObject {
    @Published var week: ReleaseWeek = .new
    @Published var comics: [DiscoverComic] = []
    @Published var loading = false
    @Published var failed = false

    private var cache: [ReleaseWeek: [DiscoverComic]] = [:]
    private var loadedAt: [ReleaseWeek: Date] = [:]

    func load(force: Bool = false) async {
        if !force, let c = cache[week], let t = loadedAt[week], Date().timeIntervalSince(t) < 3600 {
            comics = c
            failed = false
            return
        }
        loading = true
        failed = false
        let wanted = week
        do {
            let list = try await Self.fetch(wanted)
            cache[wanted] = list
            loadedAt[wanted] = Date()
            if week == wanted { comics = list }
            if list.isEmpty && week == wanted { failed = true }
        } catch {
            Console.log("Discover failed: \(error)")
            if week == wanted { comics = cache[wanted] ?? []; failed = comics.isEmpty }
        }
        loading = false
    }

    private static func fetch(_ week: ReleaseWeek) async throws -> [DiscoverComic] {
        guard let url = URL(string: "https://api.shortboxed.com/comics/v1/" + week.rawValue) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return parse(data)
    }

    /// Reads the list whichever way it is wrapped, and whichever way the fields are spelled.
    static func parse(_ data: Data) -> [DiscoverComic] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var items: [[String: Any]] = []
        if let a = json as? [[String: Any]] { items = a }
        else if let o = json as? [String: Any] {
            for key in ["comics", "results", "data", "items"] {
                if let a = o[key] as? [[String: Any]] { items = a; break }
            }
        }
        func text(_ d: [String: Any], _ keys: [String]) -> String {
            for k in keys {
                if let s = d[k] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let n = d[k] as? NSNumber { return n.stringValue }
            }
            return ""
        }
        var seen = Set<String>()
        var out: [DiscoverComic] = []
        for d in items {
            let title = text(d, ["title", "name"])
            if title.isEmpty { continue }
            let diamond = text(d, ["diamond_id", "diamondId", "diamondID"])
            let id = diamond.isEmpty ? title : diamond
            if !seen.insert(id).inserted { continue }
            out.append(DiscoverComic(id: id, title: title.capitalized,
                                     publisher: text(d, ["publisher"]).capitalized,
                                     price: text(d, ["price"]),
                                     creators: text(d, ["creators", "creator"]),
                                     date: text(d, ["release_date", "releaseDate", "date"]),
                                     summary: text(d, ["description", "desc", "summary"]),
                                     diamondID: diamond))
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
