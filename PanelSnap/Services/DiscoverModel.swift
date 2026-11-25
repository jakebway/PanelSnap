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
    var released: String? = nil        // the Wednesday it comes out, YYYY-MM-DD (release lists only)

    var listingURL: URL? { return URL(string: id) }

    /// The series without the issue number, in plain lowercase: "Batman #105" -> "batman".
    var seriesKey: String { return TitleTools.key(TitleTools.split(title).name) }

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
    case earlier, previous, current, next, week2, week3, week4
    var id: String { return rawValue }
    var label: String {
        switch self {
        case .earlier: return "Two Weeks Ago"
        case .previous: return "Last Week"
        case .current: return "This Week"
        case .next: return "Next Week"
        case .week2: return "In 2 Weeks"
        case .week3: return "In 3 Weeks"
        case .week4: return "In 4 Weeks"
        }
    }
    var dayOffset: Int {
        switch self {
        case .earlier: return -14
        case .previous: return -7
        case .current: return 0
        case .next: return 7
        case .week2: return 14
        case .week3: return 21
        case .week4: return 28
        }
    }
    /// Comics come out on Wednesdays. A week is "out" once its Wednesday is today or earlier.
    var isOut: Bool { return DiscoverModel.releaseDate(self) <= Calendar(identifier: .gregorian).startOfDay(for: Date()) }

    /// The two most recent weeks whose comics are already in shops: the newest, then the one before it.
    static var recent: [ReleaseWeek] { return [ReleaseWeek.current, .previous, .earlier].filter { $0.isOut }.prefix(2).map { $0 } }

    /// The weeks whose Wednesday is still ahead (this week's too, early in the week).
    static var upcoming: [ReleaseWeek] { return [ReleaseWeek.current, .next, .week2, .week3, .week4].filter { !$0.isOut }.prefix(4).map { $0 } }
}

/// What the detail page shows beyond the release list.
struct ComicDetail {
    var about: String?
    var creators: [String] = []
    var seriesAbout: String?
    var seriesSource: String?
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
    private var loadedDay: [ReleaseWeek: String] = [:]        // which Wednesday each list is for
    @Published private(set) var today = DiscoverModel.dayString(Date())      // changes at midnight, so headings and "Out"/"Coming" update
    private var keeping = false
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
        var seeds: [String: SeedSaved]? = nil
    }
    struct SeedSaved: Codable { var date: Date; var list: [DiscoverComic] }
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
                loadedDay[w] = saved.days[w.rawValue]
            }
        }
        forYouSections = saved.sections
        recommendedFor = saved.profile
        seedCache = saved.seeds ?? [:]
        DiscoverCovers.shared.prefetch(visibleCovers())
    }

    /// Covers in the order they are wanted: your suggestions first, then what is popular this week and next, then the rest.
    private func visibleCovers() -> [URL] {
        var urls: [URL] = []
        for sec in forYouSections { urls += sec.comics.compactMap { $0.cover } }
        for w in [ReleaseWeek.current, .next] { urls += (weeks[w] ?? []).sorted { $0.pulls > $1.pulls }.prefix(20).compactMap { $0.cover } }
        for w in ReleaseWeek.allCases { urls += (weeks[w] ?? []).sorted { $0.pulls > $1.pulls }.prefix(30).compactMap { $0.cover } }
        return urls
    }

    private func save() {
        var saved = Saved(weeks: [:], days: [:], times: [:], sections: forYouSections, profile: recommendedFor, seeds: seedCache)
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

    nonisolated static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Looks at the date again. When a new day (or a new Wednesday) has arrived, "This Week" becomes "Last Week" and so on:
    /// the lists already loaded move to the weeks they belong to, and anything that no longer fits is dropped.
    func refreshClock() {
        let now = Self.dayString(Date())
        if now != today { today = now }
        var byDay: [String: (list: [DiscoverComic], time: Date?)] = [:]
        for (w, list) in weeks { if let d = loadedDay[w] { byDay[d] = (list, loadedAt[w]) } }
        var changed = false
        for w in ReleaseWeek.allCases {
            let want = Self.releaseDay(w)
            if loadedDay[w] == want { continue }
            changed = true
            if let hit = byDay[want] {
                weeks[w] = hit.list
                loadedAt[w] = hit.time
                loadedDay[w] = want
            } else {
                weeks[w] = nil
                loadedAt[w] = nil
                loadedDay[w] = nil
            }
        }
        if changed { save() }
    }

    /// Keeps Discover current without being asked: checks the date, then loads this week, next week, your suggestions and
    /// the weeks after. Cheap to call often: anything recent enough is skipped.
    func keepFresh(libraryTitles: [String]) async {
        refreshClock()
        guard !keeping else { return }
        keeping = true
        await prefetch(libraryTitles: libraryTitles)
        await loadUpcoming()
        keeping = false
    }

    func load(_ week: ReleaseWeek, force: Bool = false) async {
        refreshClock()
        if !force, weeks[week] != nil, loadedDay[week] == Self.releaseDay(week),
           let t = loadedAt[week], Date().timeIntervalSince(t) < 3600 { return }
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
        if var list = list, !list.isEmpty {
            let day = Self.releaseDay(week)
            for i in list.indices { list[i].released = day }
            weeks[week] = list
            loadedAt[week] = Date()
            loadedDay[week] = day
            save()
            DiscoverCovers.shared.prefetch(visibleCovers())
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

    /// The next four Wednesdays, one request each, one after another so the site isn't hit all at once.
    func loadUpcoming() async {
        for w in ReleaseWeek.upcoming { await load(w) }
    }

    /// The date of a release week's Wednesday, for headings.
    nonisolated static func releaseDate(_ week: ReleaseWeek) -> Date {
        let cal = Calendar(identifier: .gregorian)
        let day = cal.date(byAdding: .day, value: week.dayOffset, to: Date()) ?? Date()
        let weekday = cal.component(.weekday, from: day)
        // Midnight, so that on the Wednesday itself the week counts as out (it used to carry the time of day and read as "later today").
        return cal.startOfDay(for: cal.date(byAdding: .day, value: 4 - weekday, to: day) ?? day)
    }

    /// Searches the whole catalogue, old and new.
    func search(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { searchResults = []; return }
        searching = true
        let list = await fetch(Self.url(["list": "search", "title": q, "list_option": "series"]))
        if q == query.trimmingCharacters(in: .whitespaces) {
            let tidy = Self.withoutDuplicates(list ?? [])
            searchResults = tidy
            DiscoverCovers.shared.prefetch(tidy.prefix(20).compactMap { $0.cover })
        }
        searching = false
    }

    /// The same title listed twice (one entry often has no cover): keep the better one, in the original order.
    static func withoutDuplicates(_ list: [DiscoverComic]) -> [DiscoverComic] {
        func hasCover(_ c: DiscoverComic) -> Bool {
            guard let u = c.cover?.absoluteString.lowercased() else { return false }
            return !u.contains("nocover") && !u.contains("no-cover") && !u.contains("placeholder")
        }
        var best: [String: Int] = [:]
        for (i, c) in list.enumerated() {
            let k = TitleTools.key(c.title) + "|" + c.publisher.lowercased()
            if let j = best[k] {
                let a = list[j], b = c
                let better = (hasCover(b) && !hasCover(a)) || (hasCover(b) == hasCover(a) && b.pulls > a.pulls)
                if better { best[k] = i }
            } else { best[k] = i }
        }
        let keep = Set(best.values)
        return list.enumerated().filter { keep.contains($0.offset) }.map { $0.element }
    }

    // MARK: Suggestions

    /// Builds the For You shelves from what is in the library. A series appears on one shelf only, so nothing is repeated:
    ///  1. Continue Your Series: new and upcoming issues of series you already read,
    ///  2. Because You Read X: other series that share the name of one you read (up to three shelves),
    ///  3. More from the publisher you read most,
    ///  4. Trending: what readers are pulling this week, from anywhere.
    /// Each series related-title search, kept for days so most visits need no searching at all.
    private var seedCache: [String: SeedSaved] = [:]

    func recommend(libraryTitles: [String], force: Bool = false) async {
        let profile = TitleTools.profile(from: libraryTitles)
        guard !profile.isEmpty else { return }
        // One shelf for each of your ten most recent series (newest first), so the shelves stay the same from one visit to the next.
        let top = TitleTools.recentSeries(from: libraryTitles, limit: 10)
        let key = "v3|" + top.map { $0.name }.joined(separator: "|") + "@" + Self.releaseDay(.current)
        guard force || key != recommendedFor || forYouSections.isEmpty else { return }
        recommendedFor = key

        // This week's lists first (they fill the Trending row), then the shelves, which fill in one by one.
        async let cur: Void = load(.current)
        async let nxt: Void = load(.next)
        async let prv: Void = load(.previous)
        _ = await (cur, nxt, prv)
        var found: [String: [DiscoverComic]] = [:]
        for item in top { if let c = seedCache[item.name] { found[item.name] = c.list } }

        func assemble() {
        let ownedSeries = Set(profile.map { TitleTools.key($0.name) })
        let ownedIssues = Set(libraryTitles.map { t -> String in
            let p = TitleTools.split(t)
            return TitleTools.key(p.name) + "#" + (p.issue ?? "")
        })
        func isOwned(_ c: DiscoverComic) -> Bool {
            let p = TitleTools.split(c.title)
            return ownedIssues.contains(TitleTools.key(p.name) + "#" + (p.issue ?? ""))
        }
        var fresh: [DiscoverComic] = []
        var seenIDs = Set<String>()
        for w in [ReleaseWeek.current, .next, .previous] {
            for c in weeks[w] ?? [] where seenIDs.insert(c.id).inserted { fresh.append(c) }
        }
        var used = Set<String>()
        var sections: [ForYouSection] = []
        /// One comic per series, skipping anything already shown on another shelf.
        func pick(_ list: [DiscoverComic], limit: Int, ownedOK: Bool) -> [DiscoverComic] {
            var out: [DiscoverComic] = []
            for c in list {
                let k = c.seriesKey
                if k.isEmpty || used.contains(k) || isOwned(c) { continue }
                if !ownedOK && ownedSeries.contains(k) { continue }
                out.append(c); used.insert(k)
                if out.count >= limit { break }
            }
            return out
        }

        // 1. Continue your series.
        let mine = pick(fresh.filter { ownedSeries.contains($0.seriesKey) }.sorted { $0.pulls > $1.pulls }, limit: 12, ownedOK: true)
        if !mine.isEmpty {
            sections.append(ForYouSection(title: "Continue Your Series", subtitle: "New and upcoming issues of comics you read", comics: mine))
        }

        // 2. Because you read X.
        var publisherWeight: [String: Int] = [:]
        for item in top {
            if let own = found[item.name]?.first(where: { TitleTools.key($0.title) == TitleTools.key(item.name) || $0.seriesKey == TitleTools.key(item.name) }), !own.publisher.isEmpty {
                publisherWeight[own.publisher, default: 0] += item.count
            }
            let words = Set(TitleTools.significantWords(item.name))
            guard !words.isEmpty else { continue }
            let need = max(1, Int((Double(words.count) * 0.5).rounded(.up)))
            let candidates = (found[item.name] ?? [])
                .map { c -> (DiscoverComic, Int) in (c, Set(TitleTools.significantWords(c.title)).intersection(words).count) }
                .filter { $0.1 >= need }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.pulls > $1.0.pulls }
                .map { $0.0 }
            let picks = pick(candidates, limit: 10, ownedOK: false)
            if picks.count >= 2 {
                sections.append(ForYouSection(title: "Because You Read \(item.name)", subtitle: "Series with a similar name or world", comics: picks))
            } else {
                for c in picks { used.remove(c.seriesKey) }       // too few to be a shelf: let another shelf use them
            }
        }

        // 3. More from the publisher you read most.
        if let pub = publisherWeight.max(by: { $0.value < $1.value })?.key {
            let list = fresh.filter { $0.publisher == pub }.sorted { $0.pulls > $1.pulls }
            let picks = pick(list, limit: 10, ownedOK: false)
            if picks.count >= 3 {
                sections.append(ForYouSection(title: "More from \(pub)", subtitle: "Popular recent releases from your most-read publisher", comics: picks))
            } else {
                for c in picks { used.remove(c.seriesKey) }
            }
        }

        // 4. Trending: shown first, but it only takes what the shelves above didn't use.
        let trending = pick((weeks[.current] ?? []).sorted { $0.pulls > $1.pulls }, limit: 12, ownedOK: false)
        if trending.count >= 3 {
            sections.insert(ForYouSection(title: "Trending This Week", subtitle: "What readers are pulling most", comics: trending), at: 0)
        }

        forYouSections = sections
        save()
        DiscoverCovers.shared.prefetch(visibleCovers())
        }

        // Show what is already known straight away (saved searches, even slightly old ones), then refresh what is stale.
        assemble()
        for item in top {
            let age = seedCache[item.name].map { Date().timeIntervalSince($0.date) } ?? .infinity
            guard force || age > 3 * 24 * 3600 else { continue }
            let req = Self.url(["list": "search", "title": item.name, "list_option": "series"])
            var list = await fetch(req) ?? []
            if list.isEmpty { list = await fetch(req) ?? [] }
            if list.isEmpty { continue }
            seedCache[item.name] = SeedSaved(date: Date(), list: list)
            found[item.name] = list
            assemble()
        }
    }

    // MARK: Detail page

    private var details: [String: ComicDetail] = [:]

    /// A fuller description for the detail page: the comic's own listing (its blurb and creators) plus a short note on the
    /// series from the comics wiki or Wikipedia. Whatever can't be found is simply left out.
    func detail(for comic: DiscoverComic) async -> ComicDetail {
        if let d = details[comic.id] { return d }
        let name = TitleTools.split(comic.title).name
        let publisher = comic.publisher
        async let page = Self.listingPage(comic.listingURL)
        async let series = Self.seriesNote(name: name, publisher: publisher)
        let (p, s) = await (page, series)
        var d = ComicDetail()
        let listed = comic.summary
        if let about = p.about, about.count > listed.count { d.about = about } else if !listed.isEmpty { d.about = listed } else { d.about = p.about }
        d.creators = p.creators
        d.seriesAbout = s?.text
        d.seriesSource = s?.source
        details[comic.id] = d
        return d
    }

    private static func listingPage(_ url: URL?) async -> (about: String?, creators: [String]) {
        guard let url = url, url.scheme?.hasPrefix("http") == true else { return (nil, []) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let html = String(data: data, encoding: .utf8) else { return (nil, []) }
        var about: String?
        for pattern in [#"<meta[^>]+property="og:description"[^>]+content="([^"]*)""#, #"<meta[^>]+content="([^"]*)"[^>]+property="og:description""#,
                        #"<meta[^>]+name="description"[^>]+content="([^"]*)""#, #"<meta[^>]+content="([^"]*)"[^>]+name="description""#] {
            if let m = html.firstMatch(pattern) { let t = clean(m); if t.count > 40 { about = t; break } }
        }
        var creators: [String] = []
        if let re = try? NSRegularExpression(pattern: #"href="/people/[^"]+"[^>]*>\s*([^<]{2,60}?)\s*</a>"#) {
            let ns = html as NSString
            for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let name = clean(ns.substring(with: m.range(at: 1)))
                if !name.isEmpty, !creators.contains(name) { creators.append(name) }
                if creators.count >= 6 { break }
            }
        }
        return (about, creators)
    }

    private static func seriesNote(name: String, publisher: String) async -> (text: String, source: String)? {
        guard name.count >= 3 else { return nil }
        // Only accept a page that is about this series, not one that merely mentions the name ("Absolute Batman" for "Batman").
        let base = name.split(separator: " ")
            .filter { w in !(w.count == 4 && w.allSatisfy { $0.isNumber }) && !["annual", "special", "vol", "volume"].contains(w.lowercased()) }
            .joined(separator: " ").lowercased()
        func fits(_ title: String) -> Bool { return base.isEmpty || title.lowercased().hasPrefix(base) }
        if let site = FandomProvider.host(for: publisher),
           let r = await Knowledge.lookUp(host: site.host, query: name, limit: 700), r.text.count > 80, fits(r.title) {
            return (r.text, site.name)
        }
        if let r = await Knowledge.lookUp(host: "en.wikipedia.org", query: name + " comics", limit: 700), r.text.count > 80, fits(r.title) {
            return (r.text, "Wikipedia")
        }
        return nil
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
        for (a, b) in [("&amp;", "&"), ("&#039;", "'"), ("&#183;", "·"), ("&middot;", "·"), ("&#8211;", "–"), ("&#8217;", "’"), ("&#39;", "'"), ("&quot;", "\""), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&rsquo;", "’"), ("&ndash;", "–")] {
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

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// One page at a time: a second request would cancel the first.
    func fetch(_ url: URL) async -> String? {
        if busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        let out = await load(url)
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        return out
    }

    private func load(_ url: URL) async -> String? {
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
    var subtitle: String? = nil
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

    /// The series name without a subtitle or collection wording: "Avengers: Absolute Vision - Book One" -> "Avengers".
    static func short(_ name: String) -> String {
        var s = name
        for sep in [":", " - ", " – ", " — "] { if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) } }
        s = s.replacingOccurrences(of: "\\b(epic collection|omnibus|complete collection|ultimate collection|book\\s+\\w+|volume\\s+\\w+|vol\\.?\\s*\\d+)\\b.*$",
                                   with: "", options: [.regularExpression, .caseInsensitive])
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—"))
    }

    /// A comparison key for a series: lowercase, no punctuation, no leading "the".
    static func key(_ name: String) -> String {
        var k = normal(short(name))
        if k.hasPrefix("the ") { k = String(k.dropFirst(4)) }
        return k
    }

    /// The series of the most recently used comics (titles are given newest first), one entry per series.
    static func recentSeries(from titles: [String], limit: Int) -> [(name: String, count: Int)] {
        var seen = Set<String>()
        var out: [(name: String, count: Int)] = []
        let counts = Dictionary(uniqueKeysWithValues: profile(from: titles).map { (key($0.name), $0.count) })
        for t in titles {
            let name = short(split(t).name)
            let k = key(name)
            if name.count < 3 || k.isEmpty || !seen.insert(k).inserted { continue }
            out.append((name: name, count: counts[k] ?? 1))
            if out.count >= limit { break }
        }
        return out
    }

    /// Comic titles, most recently opened or added first.
    static func byRecency(_ comics: [ComicEntry]) -> [String] {
        return comics.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }.map { $0.title }
    }

    /// The series in the library, the ones with the most issues first.
    static func profile(from titles: [String]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for t in titles {
            let s = short(split(t).name)
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
