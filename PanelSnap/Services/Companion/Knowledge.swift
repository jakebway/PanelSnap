import Foundation

/// One fact sheet gathered about the comic: the plot, a character, a place, a team. Saved per comic (and per issue of a
/// collection) so reopening is instant, and handed to the on-device model so it answers from facts instead of guessing.
struct KnowledgeNote: Codable, Hashable {
    var title: String
    var text: String
    var source: String
}

enum Knowledge {

    // MARK: Wiki access (Marvel / DC Database use the same API as Wikipedia)

    private static func fandomHost(_ publisher: String?) -> String? {
        return FandomProvider.host(for: publisher)?.host
    }

    /// The plain-text introduction of a wiki page.
    static func extract(host: String, title: String, limit: Int) async -> String? {
        guard let url = HTTP.url("https://\(host)/api.php", [
            ("action", "query"), ("prop", "extracts"), ("exintro", "1"), ("explaintext", "1"),
            ("redirects", "1"), ("titles", title), ("format", "json"), ("formatversion", "2")
        ]), let root = try? await HTTP.json(url) as? [String: Any],
              let q = root["query"] as? [String: Any], let pages = q["pages"] as? [[String: Any]],
              let ex = pages.first?["extract"] as? String else { return nil }
        let t = TextClean.tidy(ex)
        return t.count > 30 ? TextClean.shorten(t, limit: limit) : nil
    }

    /// Searches a wiki and returns the introduction of the best matching page.
    static func lookUp(host: String, query: String, limit: Int) async -> (title: String, text: String)? {
        guard let url = HTTP.url("https://\(host)/api.php", [
            ("action", "query"), ("list", "search"), ("srsearch", query), ("srlimit", "3"), ("format", "json")
        ]), let root = try? await HTTP.json(url) as? [String: Any],
              let q = root["query"] as? [String: Any], let hits = q["search"] as? [[String: Any]], !hits.isEmpty else { return nil }
        let titles = hits.compactMap { $0["title"] as? String }
        let want = query.lowercased()
        let best = titles.first(where: { $0.lowercased().hasPrefix(want) }) ?? titles.first
        guard let title = best else { return nil }
        if let text = await extract(host: host, title: title, limit: limit) { return (title, text) }
        if let h = hits.first(where: { ($0["title"] as? String) == title }), let snip = h["snippet"] as? String {
            let t = TextClean.html(snip)
            if t.count > 30 { return (title, t) }
        }
        return nil
    }

    // MARK: Gathering everything at once

    /// Fetches, in parallel, a profile for each character, place and team in the issue. Everything runs at the same time.
    static func gather(data: CompanionData, publisher: String?, series: String, collection: String?) async -> [KnowledgeNote] {
        var notes: [KnowledgeNote] = []
        if let c = collection, c.count > 40 { notes.append(KnowledgeNote(title: "What this book collects", text: TextClean.shorten(c, limit: 900), source: "Book description")) }
        if let s = data.issueSynopsis { notes.append(KnowledgeNote(title: "Plot of this issue", text: TextClean.shorten(s.text, limit: 3500), source: s.source)) }
        if let s = data.issueSummary { notes.append(KnowledgeNote(title: "Summary of this issue", text: TextClean.shorten(s.text, limit: 900), source: s.source)) }
        if let s = data.seriesSummary { notes.append(KnowledgeNote(title: "About the series \(series)", text: TextClean.shorten(s.text, limit: 900), source: s.source)) }

        let wikiHost = fandomHost(publisher)
        var jobs: [(String, String)] = []                      // (name shown, what to search)
        for c in data.characters.prefix(10) { jobs.append((c.name, c.name)) }
        for p in data.locations.prefix(6) { jobs.append((p, p)) }
        for t in data.teams.prefix(4) { jobs.append((t, t)) }
        let hasWiki = wikiHost != nil
        let host = wikiHost ?? "en.wikipedia.org"
        let have = Set(data.characters.compactMap { $0.blurb == nil ? nil : $0.name })
        await withTaskGroup(of: KnowledgeNote?.self) { group in
            for (name, q) in jobs {
                group.addTask {
                    let query = hasWiki ? q : q + " comics"
                    guard let r = await lookUp(host: host, query: query, limit: 650) else { return nil }
                    return KnowledgeNote(title: name, text: r.text, source: hasWiki ? "Comics wiki" : "Wikipedia")
                }
            }
            for await n in group { if let n = n { notes.append(n) } }
        }
        // The built-in guide knows many characters even when the wikis don't answer.
        for c in data.characters.prefix(10) where !notes.contains(where: { $0.title == c.name }) {
            if let e = CharacterGlossary.shared.find(name: c.name) {
                var l = e.n
                if let r = e.r, !r.isEmpty { l += ", real name " + r }
                if let rel = e.rel, !rel.isEmpty { l += ". Family: " + rel }
                if let occ = e.occ, !occ.isEmpty { l += ". " + occ }
                notes.append(KnowledgeNote(title: c.name, text: l, source: "Built-in guide"))
            } else if have.contains(c.name), let b = c.blurb {
                notes.append(KnowledgeNote(title: c.name, text: b, source: c.source ?? "Wikipedia"))
            }
        }
        return notes
    }

    // MARK: Using it

    private static let stop: Set<String> = ["what", "who", "whom", "where", "when", "which", "that", "this", "with", "they", "their", "there",
                                            "have", "does", "about", "from", "were", "into", "issue", "page", "comic", "going", "happening",
                                            "wanna", "want", "live", "lived", "living", "lives", "visit", "visiting", "visits", "characters", "character"]

    static func terms(_ q: String) -> [String] {
        return q.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 2 && !stop.contains($0) }
    }

    /// Notes that mention the question's key words come first (then the rest in the order gathered), within `budget` characters.
    static func relevant(_ notes: [KnowledgeNote], to question: String, budget: Int, each: Int = 650) -> [String] {
        let ts = terms(question).map { String($0.prefix(6)) }
        func score(_ n: KnowledgeNote) -> Int {
            let title = n.title.lowercased(), text = n.text.lowercased()
            return ts.reduce(0) { $0 + (title.contains($1) ? 3 : 0) + (text.contains($1) ? 1 : 0) }
        }
        let ranked = notes.enumerated().sorted { a, b in
            let sa = score(a.element), sb = score(b.element)
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map { $0.element }
        var out: [String] = []
        var used = 0
        for n in ranked {
            let piece = "[\(n.title)] " + TextClean.shorten(n.text, limit: n.title.hasPrefix("Plot") ? each * 3 : each)
            if used + piece.count > budget { continue }
            out.append(piece); used += piece.count
        }
        return out
    }

    /// What the model's search tool runs: the saved notes first, then the comics wiki and Wikipedia, live.
    static func search(_ query: String, publisher: String?, notes: [KnowledgeNote]) async -> String {
        var parts: [String] = relevant(notes.filter { !$0.title.hasPrefix("Plot") }, to: query, budget: 900, each: 450)
        let ts = terms(query)
        if !ts.isEmpty { parts = parts.filter { p in ts.contains(where: { p.lowercased().contains($0.prefix(6)) }) } }
        let host = fandomHost(publisher)
        async let fan: (title: String, text: String)? = {
            guard let h = host else { return nil }
            return await lookUp(host: h, query: query, limit: 800)
        }()
        async let wiki: (title: String, text: String)? = lookUp(host: "en.wikipedia.org", query: query + " comics", limit: 600)
        if let f = await fan { parts.append("[\(f.title) – comics wiki] " + f.text) }
        if let w = await wiki { parts.append("[\(w.title) – Wikipedia] " + w.text) }
        return parts.isEmpty ? "Nothing found for \(query)." : parts.joined(separator: "\n")
    }

    // MARK: Saving it

    static func file(_ id: UUID, variant: String) -> URL {
        let safe = String(variant.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(80))
        return Paths.companionCache.appendingPathComponent(id.uuidString + "-kb-" + safe + ".json")
    }

    static func read(_ id: UUID, variant: String, maxAgeDays: Int = 30) -> [KnowledgeNote]? {
        let url = file(id, variant: variant)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(date) < Double(maxAgeDays) * 86400,
              let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode([KnowledgeNote].self, from: data), !notes.isEmpty else { return nil }
        return notes
    }

    static func write(_ id: UUID, variant: String, _ notes: [KnowledgeNote]) {
        if let data = try? JSONEncoder().encode(notes) { try? data.write(to: file(id, variant: variant), options: .atomic) }
    }
}
