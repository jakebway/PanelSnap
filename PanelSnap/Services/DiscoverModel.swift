import Foundation

/// One comic on the weekly release list.
struct DiscoverComic: Identifiable, Hashable {
    let id: String             // the Grand Comics Database issue number
    var series: String         // "Absolute Batman"
    var year: String           // "2024"
    var issue: String          // "6"
    var variant: String        // "Nick Dragotta Cover", when the descriptor names one
    var price: String
    var pages: String

    var title: String { return issue.isEmpty ? series : series + " #" + issue }

    /// The comic's page on the Grand Comics Database website.
    var listingURL: URL? { return URL(string: "https://www.comics.org/issue/" + id + "/") }

    /// What to type into a download site's search box: the series name and issue number.
    var searchTerm: String { return issue.isEmpty ? series : series + " " + issue }
}

enum ReleaseWeek: String, CaseIterable, Identifiable {
    case previous, current, next
    var id: String { return rawValue }
    var label: String {
        switch self {
        case .previous: return "Last Week"
        case .current: return "This Week"
        case .next: return "Next Week"
        }
    }
    var dayOffset: Int {
        switch self {
        case .previous: return -7
        case .current: return 0
        case .next: return 7
        }
    }
}

/// Weekly new-comic lists from the Grand Comics Database (comics.org), a volunteer-run catalogue whose data is
/// licensed CC BY-SA. Its "on sale this week" list is open to read, with no account or key. Only US-priced
/// issues are shown, and variant covers are folded into the main issue.
@MainActor
final class DiscoverModel: ObservableObject {
    @Published var week: ReleaseWeek = .current
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
            if week == wanted { comics = list; failed = list.isEmpty }
        } catch {
            Console.log("Discover failed: \(error)")
            if week == wanted { comics = cache[wanted] ?? []; failed = comics.isEmpty }
        }
        loading = false
    }

    private static func fetch(_ week: ReleaseWeek) async throws -> [DiscoverComic] {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone.current
        let day = cal.date(byAdding: .day, value: week.dayOffset, to: Date()) ?? Date()
        let year = cal.component(.yearForWeekOfYear, from: day)
        let number = cal.component(.weekOfYear, from: day)
        var next: URL? = URL(string: "https://www.comics.org/api/issue/on_sale_weekly/\(year)/week/\(number)/?format=json")
        var all: [DiscoverComic] = []
        var pages = 0
        while let url = next, pages < 12 {
            var req = URLRequest(url: url)
            req.timeoutInterval = 25
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
            let (items, link) = parse(data)
            all += items
            next = link
            pages += 1
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
            .sorted { $0.series.localizedStandardCompare($1.series) == .orderedAscending
                      || ($0.series == $1.series && $0.issue.localizedStandardCompare($1.issue) == .orderedAscending) }
    }

    /// One page of the list: its comics, and the address of the next page (if any).
    static func parse(_ data: Data) -> ([DiscoverComic], URL?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], nil) }
        let link = (root["next"] as? String).flatMap { URL(string: $0.contains("format=") ? $0 : $0 + ($0.contains("?") ? "&" : "?") + "format=json") }
        var out: [DiscoverComic] = []
        for d in (root["results"] as? [[String: Any]]) ?? [] {
            if !(d["variant_of"] is NSNull) && d["variant_of"] != nil { continue }      // a variant cover of another issue
            let price = (d["price"] as? String) ?? ""
            if !price.uppercased().contains("USD") { continue }                          // keep the US market
            guard let api = d["api_url"] as? String,
                  let id = api.split(separator: "/").last.map(String.init), !id.isEmpty else { continue }
            var series = (d["series_name"] as? String) ?? ""
            var year = ""
            if let r = series.range(of: " \\(\\d{4}\\??\\s+series\\)$", options: .regularExpression) {
                year = String(series[r]).filter { $0.isNumber }
                series = String(series[..<r.lowerBound])
            }
            let descriptor = ((d["descriptor"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            var issue = descriptor
            var variant = ""
            if let b = descriptor.firstIndex(of: "[") {
                issue = String(descriptor[..<b]).trimmingCharacters(in: .whitespaces)
                variant = String(descriptor[b...]).trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            }
            if series.isEmpty { continue }
            var pages = (d["page_count"] as? String) ?? ""
            if let dot = pages.firstIndex(of: ".") { pages = String(pages[..<dot]) }
            out.append(DiscoverComic(id: id, series: series, year: year, issue: issue, variant: variant,
                                     price: price.replacingOccurrences(of: " USD", with: "").isEmpty ? "" : "$" + price.replacingOccurrences(of: " USD", with: ""),
                                     pages: pages == "0" ? "" : pages))
        }
        return (out, link)
    }
}
