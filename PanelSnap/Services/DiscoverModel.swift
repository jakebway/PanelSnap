import Foundation
import WebKit

/// One comic on the weekly release list.
struct DiscoverComic: Identifiable, Hashable, Codable {
    let id: String             // the League of Comic Geeks page address
    var title: String          // "Batman #105"
    var publisher: String
    var price: String
    var summary: String
    var cover: URL?
    var pulls: Int             // how many readers have it on their pull list: a popularity measure
    var rating: Int?

    var listingURL: URL? { return URL(string: id) }

    /// The series without the issue number, in plain lowercase: "Batman #105" -> "batman".
    var seriesKey: String { return TitleTools.normal(TitleTools.split(title).name) }

    /// What to type into a download site's search box: the series name and issue number, without variant wording.
    var searchTerm: String {
        var t = title.replacingOccurrences(of: "\\(.*?\\)", with: " ", options: .regularExpression)
        for marker in [" Cover ", " Variant", " Virgin", " Foil", " 1:", " Facsimile", " Direct Market"] {
            if let r = t.range(of: marker, options: .caseInsensitive) { t = String(t[..<r.lowerBound]) }
        }
        t = t.replacingOccurrences(of: "#", with: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }
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

enum DiscoverSort: String, CaseIterable, Identifiable {
    case popular, title
    var id: String { return rawValue }
    var label: String { return self == .popular ? "Popular" : "A–Z" }
}

/// Weekly comic-shop release lists from League of Comic Geeks, which lists every week's new comics with covers
/// and how many readers pull each one. It has no official public API, so this reads the same list its own website
/// shows (the way the open-source comicgeeks module does), and asks politely: one request per week, kept for an hour.
@MainActor
final class DiscoverModel: ObservableObject {
    /// One shared copy, so the lists are already loaded by the time Discover is opened.
    static let shared = DiscoverModel()
    @Published var weeks: [ReleaseWeek: [DiscoverComic]] = [:]
    @Published var loadingWeeks = Set<ReleaseWeek>()
    @Published var failedWeeks = Set<ReleaseWeek>()
    @Published var forYouSections: [ForYouSection] = []
    @Published var searchResults: [DiscoverComic] = []
    @Published var searching = false

    private var loadedAt: [ReleaseWeek: Date] = [:]
    private var inflight: [ReleaseWeek: Task<Void, Never>] = [:]
    private let browser = WebJSONFetcher()
    private var recommendedFor = ""

    // MARK: Remembered between launches, so Discover opens already filled in and refreshes quietly behind it

    private struct Saved: Codable {
        var weeks: [String: [DiscoverComic]]
        var days: [String: String]
        var times: [String: Date]
        var sections: [ForYouSection]
        var profile: String
    }
    private static let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DiscoverCache.json")

    init() {
        guard let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        for w in ReleaseWeek.allCases {
            // A list saved for another week would show the wrong releases, so only this week's lists are kept.
            if let list = saved.weeks[w.rawValue], saved.days[w.rawValue] == Self.releaseDay(w) {
                weeks[w] = list
                loadedAt[w] = saved.times[w.rawValue]
            }
        }
        forYouSections = saved.sections
        recommendedFor = saved.profile
        DiscoverCovers.shared.prefetch(visibleCovers())
    }

    private func visibleCovers() -> [URL] {
        var urls: [URL] = []
        for sec in forYouSections { urls += sec.comics.prefix(8).compactMap { $0.cover } }
        for w in [ReleaseWeek.current, .next] { urls += (weeks[w] ?? []).sorted { $0.pulls > $1.pulls }.prefix(12).compactMap { $0.cover } }
        return urls
    }

    private func save() {
        var saved = Saved(weeks: [:], days: [:], times: [:], sections: forYouSections, profile: recommendedFor)
        for (w, list) in weeks {
            saved.weeks[w.rawValue] = list
            saved.days[w.rawValue] = Self.releaseDay(w)
            saved.times[w.rawValue] = loadedAt[w]
        }
        let file = Self.file
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
        }
    }

    func load(_ week: ReleaseWeek, force: Bool = false) async {
        if !force, weeks[week] != nil, let t = loadedAt[week], Date().timeIntervalSince(t) < 3600 { return }
        if let running = inflight[week] { await running.value; return }
        let task = Task { await self.fetchWeek(week) }
        inflight[week] = task
        await task.value
        inflight[week] = nil
    }

    private func fetchWeek(_ week: ReleaseWeek) async {
        if weeks[week] == nil { loadingWeeks.insert(week) }
        failedWeeks.remove(week)
        let list = await fetch(Self.url(["list": "releases", "list_option": "thumbs", "view": "list",
                                         "date": Self.releaseDay(week), "date_type": "week"]))
        if let list = list, !list.isEmpty {
            weeks[week] = list
            loadedAt[week] = Date()
            save()
            DiscoverCovers.shared.prefetch(list.sorted { $0.pulls > $1.pulls }.prefix(30).compactMap { $0.cover })
        } else if weeks[week] == nil {
            failedWeeks.insert(week)
        }
        loadingWeeks.remove(week)
    }

    /// Everything the For You page needs, fetched side by side. Called when the app opens.
    func prefetch(libraryTitles: [String]) async {
        async let a: Void = load(.current)
        async let b: Void = load(.next)
        async let c: Void = recommend(libraryTitles: libraryTitles)
        _ = await (a, b, c)
    }

    /// Searches the whole catalogue, old and new.
    func search(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { searchResults = []; return }
        searching = true
        let list = await fetch(Self.url(["list": "search", "title": q, "list_option": "series"]))
        if q == query.trimmingCharacters(in: .whitespaces) {
            searchResults = list ?? []
            DiscoverCovers.shared.prefetch((list ?? []).prefix(20).compactMap { $0.cover })
        }
        searching = false
    }

    // MARK: Suggestions

    /// Builds the For You shelves from what is in the library:
    ///  1. new issues of series you already read,
    ///  2. "Because you read X": other series that share the name of one you read (one entry per series, most popular
    ///     first, never something you already have),
    ///  3. popular new releases from the publisher you read most.
    func recommend(libraryTitles: [String], force: Bool = false) async {
        let profile = TitleTools.profile(from: libraryTitles)
        guard !profile.isEmpty else { return }
        let top = Array(profile.prefix(6))
        let key = top.map { $0.name }.joined(separator: "|") + "@" + Self.releaseDay(.current)
        guard force || key != recommendedFor || forYouSections.isEmpty else { return }
        recommendedFor = key

        async let cur: Void = load(.current)
        async let nxt: Void = load(.next)
        var found: [String: [DiscoverComic]] = [:]
        await withTaskGroup(of: (String, [DiscoverComic]).self) { group in
            for item in top {
                group.addTask { @MainActor in
                    (item.name, await self.fetch(Self.url(["list": "search", "title": item.name, "list_option": "series"])) ?? [])
                }
            }
            for await (name, list) in group { found[name] = list }
        }
        _ = await (cur, nxt)

        let ownedSeries = Set(profile.map { TitleTools.normal($0.name) })
        let ownedIssues = Set(libraryTitles.map { t -> String in
            let p = TitleTools.split(t)
            return TitleTools.normal(p.name) + "#" + (p.issue ?? "")
        })
        func isOwned(_ c: DiscoverComic) -> Bool {
            let p = TitleTools.split(c.title)
            return ownedIssues.contains(TitleTools.normal(p.name) + "#" + (p.issue ?? ""))
        }
        let fresh = (weeks[.current] ?? []) + (weeks[.next] ?? [])
        var used = Set<String>()
        var sections: [ForYouSection] = []

        // 1. New issues of series you read.
        var newIssues: [DiscoverComic] = []
        for c in fresh.sorted(by: { $0.pulls > $1.pulls }) where ownedSeries.contains(c.seriesKey) && !isOwned(c) {
            if newIssues.contains(where: { $0.seriesKey == c.seriesKey }) { continue }
            newIssues.append(c)
        }
        if !newIssues.isEmpty {
            sections.append(ForYouSection(title: "New Issues for You", comics: Array(newIssues.prefix(12))))
            for c in newIssues { used.insert(c.seriesKey) }
        }

        // 2. Because you read X.
        var publisherWeight: [String: Int] = [:]
        for item in top {
            let words = Set(TitleTools.significantWords(item.name))
            if let own = found[item.name]?.first(where: { $0.seriesKey == TitleTools.normal(item.name) }), !own.publisher.isEmpty {
                publisherWeight[own.publisher, default: 0] += item.count
            }
            guard !words.isEmpty, sections.count < 4 else { continue }
            let need = max(1, Int((Double(words.count) * 0.5).rounded(.up)))
            var best: [String: (DiscoverComic, Int)] = [:]
            for c in found[item.name] ?? [] {
                let key = c.seriesKey
                if key.isEmpty || ownedSeries.contains(key) || used.contains(key) || isOwned(c) { continue }
                let overlap = Set(TitleTools.significantWords(c.title)).intersection(words).count
                if overlap < need { continue }
                if let old = best[key], old.0.pulls >= c.pulls { continue }
                best[key] = (c, overlap)
            }
            let picks = best.values.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.pulls > $1.0.pulls }.prefix(10).map { $0.0 }
            if picks.count >= 2 {
                sections.append(ForYouSection(title: "Because You Read \(item.name)", comics: Array(picks)))
                for c in picks { used.insert(c.seriesKey) }
            }
        }

        // 3. Popular from the publisher you read most.
        if let pub = publisherWeight.max(by: { $0.value < $1.value })?.key {
            var seen = Set<String>()
            let popular = fresh.filter { $0.publisher == pub && !ownedSeries.contains($0.seriesKey) && !used.contains($0.seriesKey) }
                .sorted { $0.pulls > $1.pulls }
                .filter { seen.insert($0.seriesKey).inserted }
                .prefix(10)
            if popular.count >= 3 { sections.append(ForYouSection(title: "Popular from \(pub)", comics: Array(popular))) }
        }

        forYouSections = sections
        save()
        DiscoverCovers.shared.prefetch(visibleCovers())
    }

    // MARK: Requests

    private static func url(_ params: [String: String]) -> URL? {
        var c = URLComponents(string: "https://leagueofcomicgeeks.com/comic/get_comics")
        c?.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c?.url
    }

    /// The Wednesday (new-comic day) of the chosen week, as YYYY-MM-DD.
    private static func releaseDay(_ week: ReleaseWeek) -> String {
        let cal = Calendar(identifier: .gregorian)
        let day = cal.date(byAdding: .day, value: week.dayOffset, to: Date()) ?? Date()
        let weekday = cal.component(.weekday, from: day)            // Sunday = 1 ... Wednesday = 4
        let wednesday = cal.date(byAdding: .day, value: 4 - weekday, to: day) ?? day
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: wednesday)
    }

    private func fetch(_ url: URL?) async -> [DiscoverComic]? {
        guard let url = url else { return nil }
        // First a plain request; if the site wants a real browser, use one (a hidden web page) instead.
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        if let (data, response) = try? await URLSession.shared.data(for: req),
           (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false {
            let list = Self.parse(data)
            if !list.isEmpty { return list }
        }
        if let text = await browser.fetch(url), let data = text.data(using: .utf8) {
            let list = Self.parse(data)
            if !list.isEmpty { return list }
        }
        return nil
    }

    // MARK: Reading the list

    /// The answer is JSON holding one block of HTML, a list item per comic.
    static func parse(_ data: Data) -> [DiscoverComic] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let html = root["list"] as? String else { return [] }
        var out: [DiscoverComic] = []
        var seen = Set<String>()
        for chunk in html.components(separatedBy: "<li").dropFirst() {
            let item = chunk
            let head = String(item.prefix(upTo: item.firstIndex(of: ">") ?? item.endIndex))
            guard let title = text(of: ["title", "color-primary"], in: item) ?? text(of: ["title"], in: item) ?? item.firstMatch(#"<a[^>]*href="/comics?/[^"]*"[^>]*>([^<]{2,})</a>"#).map(clean), !title.isEmpty else { continue }
            let description = element(["comic-description", "col-feed-max"], in: item)
            var link = ""
            if let d = description, let m = d.firstMatch(#"href="([^"]+)""#) { link = m }
            if link.isEmpty, let m = item.firstMatch(#"href="(/comics?/[^"]+)""#) { link = m }
            let id = link.hasPrefix("http") ? link : (link.isEmpty ? title : "https://leagueofcomicgeeks.com" + link)
            if !seen.insert(id).inserted { continue }
            var summary = ""
            if let d = description {
                summary = d.replacingOccurrences(of: "<a\\b[^>]*>.*?</a>", with: " ", options: [.regularExpression, .caseInsensitive])
                summary = clean(summary)
            }
            var cover: URL?
            let artZone = item.range(of: "comic-cover-art").map { String(item[$0.upperBound...]) } ?? item
            if let src = artZone.firstMatch(#"data-src="([^"]+)""#) ?? artZone.firstMatch(#"<img[^>]+src="([^"]+)""#) {
                var s = src.replacingOccurrences(of: "medium", with: "large")
                if s.hasPrefix("/") { s = "https://leagueofcomicgeeks.com" + s.replacingOccurrences(of: "-med", with: "-lg") }
                cover = URL(string: s)
            }
            let details = text(of: ["comic-details"], in: item) ?? ""
            let publisher = details.components(separatedBy: "·").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let price = text(of: ["price"], in: item) ?? ""
            let pulls = Int(head.firstMatch(#"data-pulls="([^"]*)""#) ?? "") ?? 0
            let rating = Int(head.firstMatch(#"data-community="([^"]*)""#) ?? "")
            out.append(DiscoverComic(id: id, title: title, publisher: publisher, price: price, summary: summary,
                                     cover: cover, pulls: pulls, rating: rating))
        }
        return out
    }

    /// The inside of the first tag whose class list has all of these classes.
    private static func element(_ classes: [String], in html: String) -> String? {
        guard let tags = try? NSRegularExpression(pattern: #"<(\w+)\b[^>]*class="([^"]*)"[^>]*>"#, options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        for m in tags.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let have = Set(ns.substring(with: m.range(at: 2)).split(separator: " ").map(String.init))
            guard classes.allSatisfy({ have.contains($0) }) else { continue }
            let name = ns.substring(with: m.range(at: 1))
            let start = m.range.location + m.range.length
            let rest = ns.substring(from: start)
            let end = rest.range(of: "</" + name + ">", options: .caseInsensitive)?.lowerBound ?? rest.endIndex
            return String(rest[..<end])
        }
        return nil
    }

    private static func text(of classes: [String], in html: String) -> String? {
        guard let inner = element(classes, in: html) else { return nil }
        return clean(inner)
    }

    private static func clean(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&#039;", "'"), ("&#39;", "'"), ("&quot;", "\""), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&rsquo;", "’"), ("&ndash;", "–")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    /// The first capture group of the first match.
    func firstMatch(_ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(location: 0, length: (self as NSString).length)),
              m.numberOfRanges > 1 else { return nil }
        return (self as NSString).substring(with: m.range(at: 1))
    }
}

/// Reads a JSON address through a hidden web page, for sites that only talk to a real browser.
@MainActor
final class WebJSONFetcher: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String?, Never>?

    func fetch(_ url: URL) async -> String? {
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            finish(nil)
            continuation = c
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            wv.navigationDelegate = self
            webView = wv
            wv.load(URLRequest(url: url))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self?.finish(nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A "checking your browser" page may come first; only the JSON answer is accepted.
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
            let text = (result as? String) ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { self?.finish(text) }
        }
    }

    private func finish(_ text: String?) {
        guard let c = continuation else { return }
        continuation = nil
        webView?.stopLoading()
        webView = nil
        c.resume(returning: text)
    }
}

/// A row of suggestions on the For You page.
struct ForYouSection: Identifiable, Codable, Hashable {
    var title: String
    var comics: [DiscoverComic]
    var id: String { return title }
}

/// Reading comic titles: "Avengers Disassembled #3 (2006) (digital)" is the series "Avengers Disassembled", issue 3.
enum TitleTools {
    static func split(_ title: String) -> (name: String, issue: String?) {
        var s = title.replacingOccurrences(of: "\\(.*?\\)|\\[.*?\\]", with: " ", options: .regularExpression)
        var issue: String?
        if let r = s.range(of: "#\\s*(\\d+(\\.\\d+)?)", options: .regularExpression) {
            issue = String(s[r]).replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
            s = String(s[..<r.lowerBound])
        }
        s = s.replacingOccurrences(of: "\\b(vol(ume)?\\.?|v)\\s*\\d+.*$", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "[_\\.]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " -–"))
        return (s, issue)
    }

    /// The series in the library, the ones with the most issues first.
    static func profile(from titles: [String]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for t in titles {
            let s = split(t).name
            if s.count < 3 { continue }
            if counts[s] == nil { order.append(s) }
            counts[s, default: 0] += 1
        }
        return order.map { (name: $0, count: counts[$0] ?? 0) }.sorted { $0.count > $1.count }
    }

    static func normal(_ title: String) -> String {
        return title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static let filler: Set<String> = ["the", "and", "of", "a", "an", "to", "in", "vol", "tp", "hc", "comic", "comics", "issue", "all", "one", "new", "marvel", "dc", "image"]
    static func significantWords(_ title: String) -> [String] {
        return normal(title).split(separator: " ").map(String.init).filter { $0.count > 2 && !filler.contains($0) && Int($0) == nil }
    }
}
