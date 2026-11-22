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

    /// Wikipedia keeps its API under /w/; Fandom wikis keep it at the root.
    static func apiPath(_ host: String) -> String { host.hasSuffix("wikipedia.org") ? "/w/api.php" : "/api.php" }

    /// The plain-text introduction of a wiki page.
    static func extract(host: String, title: String, limit: Int, full: Bool = false) async -> String? {
        guard let url = HTTP.url("https://\(host)\(apiPath(host))", [
            ("action", "query"), ("prop", "extracts"), ("explaintext", "1"),
            ("redirects", "1"), ("titles", title), ("format", "json"), ("formatversion", "2")
        ] + (full ? [] : [("exintro", "1")])), let root = try? await HTTP.json(url) as? [String: Any],
              let q = root["query"] as? [String: Any], let pages = q["pages"] as? [[String: Any]],
              let ex = pages.first?["extract"] as? String else { return nil }
        let t = TextClean.tidy(ex)
        return t.count > 30 ? TextClean.shorten(t, limit: limit) : nil
    }

    /// Searches a wiki and returns the introduction of the best matching page.
    /// The top few pages for a topic (a place like Attilan is covered by its own page and by its people's pages).
    static func lookUpMany(host: String, query: String, count: Int, limit: Int, full: Bool = false) async -> [(title: String, text: String)] {
        guard let url = HTTP.url("https://\(host)\(apiPath(host))", [
            ("action", "query"), ("list", "search"), ("srsearch", query), ("srlimit", String(count)), ("format", "json")
        ]), let root = try? await HTTP.json(url) as? [String: Any],
              let q = root["query"] as? [String: Any], let hits = q["search"] as? [[String: Any]] else { return [] }
        let titles = hits.compactMap { $0["title"] as? String }.prefix(count)
        return await withTaskGroup(of: (Int, String, String)?.self) { group in
            for (i, t) in titles.enumerated() {
                group.addTask {
                    guard let text = await extract(host: host, title: t, limit: limit, full: full) else { return nil }
                    return (i, t, text)
                }
            }
            var out: [(Int, String, String)] = []
            for await r in group { if let r = r { out.append(r) } }
            return out.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
    }

    /// DuckDuckGo's instant answer: a short, sourced summary of a topic from the open web.
    static func instantAnswer(_ query: String) async -> String? {
        guard let url = HTTP.url("https://api.duckduckgo.com/", [("q", query), ("format", "json"), ("no_html", "1"), ("skip_disambig", "1")]),
              let root = try? await HTTP.json(url) as? [String: Any] else { return nil }
        let text = (root["AbstractText"] as? String) ?? ""
        return text.count > 40 ? TextClean.shorten(text, limit: 700) : nil
    }

    static func lookUp(host: String, query: String, limit: Int) async -> (title: String, text: String)? {
        guard let url = HTTP.url("https://\(host)\(apiPath(host))", [
            ("action", "query"), ("list", "search"), ("srsearch", query), ("srlimit", "3"), ("format", "json")
        ]), let root = try? await HTTP.json(url) as? [String: Any],
              let q = root["query"] as? [String: Any], let hits = q["search"] as? [[String: Any]], !hits.isEmpty else {
            Diagnostics.add("NO RESULTS \(host) for \"\(query)\"")
            return nil
        }
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
            // A second opinion from Wikipedia for places, teams and the main characters, to cross-check the comics wiki.
            if hasWiki {
                for q in (data.locations.prefix(6) + data.teams.prefix(4) + data.characters.prefix(4).map { $0.name }) {
                    group.addTask {
                        guard let r = await lookUp(host: "en.wikipedia.org", query: q + " comics", limit: 650) else { return nil }
                        return KnowledgeNote(title: q + " (Wikipedia)", text: r.text, source: "Wikipedia")
                    }
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
                                            "wanna", "want", "live", "lived", "living", "lives", "visit", "visiting", "visits", "characters", "character",
                                            "all", "any", "the", "and", "are", "was", "how", "who", "his", "her", "its", "did", "can", "you", "tell"]

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

    // MARK: Spelling

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Fixes misspelled names in a question by matching its words against the names in this comic's fact sheets
    /// ("Atillian" -> "Attilan"). Returns the corrected question and the corrections made.
    static func canonical(_ question: String, vocabulary: [String]) -> (text: String, fixes: [(String, String)]) {
        var words: Set<String> = []
        for v in vocabulary {
            for w in v.components(separatedBy: CharacterSet.letters.inverted) where w.count >= 4 { words.insert(w) }
        }
        var out = question
        var fixes: [(String, String)] = []
        for raw in question.components(separatedBy: CharacterSet.letters.inverted) where raw.count >= 5 {
            let lower = raw.lowercased()
            if words.contains(where: { $0.lowercased() == lower }) { continue }
            var best: (String, Int)?
            for w in words {
                let wl = w.lowercased()
                if abs(wl.count - lower.count) > 2 { continue }
                let d = distance(Array(lower), Array(wl))
                if d <= (lower.count >= 7 ? 2 : 1), best == nil || d < best!.1 { best = (w, d) }
            }
            if let b = best {
                out = out.replacingOccurrences(of: raw, with: b.0)
                fixes.append((raw, b.0))
            }
        }
        return (out, fixes)
    }

    /// The live search, given at most a few seconds so a slow connection never stalls the answer.
    static func liveParts(_ query: String, publisher: String?, notes: [KnowledgeNote], seconds: UInt64 = 8) async -> [String] {
        let key = terms(query).joined(separator: " ")
        guard !key.isEmpty else { return [] }
        return await withTaskGroup(of: [String]?.self) { group in
            group.addTask { await searchParts(key, publisher: publisher, notes: notes, deep: true) }
            group.addTask { try? await Task.sleep(nanoseconds: seconds * 1_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    /// What the model's search tool runs: the saved notes first, then the comics wiki and Wikipedia, live.
    static func search(_ query: String, publisher: String?, notes: [KnowledgeNote], deep: Bool = true) async -> String {
        let parts = await searchParts(query, publisher: publisher, notes: notes, deep: deep)
        if parts.isEmpty { return "Nothing found for \(query)." }
        let best = Passages.best(parts: parts, question: query, maxChars: 2800)
        return (best.isEmpty ? parts : best).joined(separator: "\n")
    }

    /// Everything the sources returned for a topic, one entry per page, before it is cut down to the best passages.
    static func searchParts(_ query: String, publisher: String?, notes: [KnowledgeNote], deep: Bool = true) async -> [String] {
        var parts: [String] = relevant(notes.filter { !$0.title.hasPrefix("Plot") }, to: query, budget: 900, each: 450)
        let ts = terms(query)
        if !ts.isEmpty { parts = parts.filter { p in ts.contains(where: { p.lowercased().contains($0.prefix(6)) }) } }
        let host = fandomHost(publisher)
        let house = (publisher ?? "").isEmpty ? "comics" : (publisher ?? "") + " comics"
        // Every source is asked at once, so more sources cost no extra waiting.
        async let fan: [(title: String, text: String)] = {
            guard let h = host else { return [] }
            return await lookUpMany(host: h, query: query, count: 3, limit: 1200)
        }()
        async let wiki: [(title: String, text: String)] = lookUpMany(host: "en.wikipedia.org", query: query, count: 3, limit: 1100)
        async let wiki2: [(title: String, text: String)] = lookUpMany(host: "en.wikipedia.org", query: query + " " + house, count: 2, limit: 900)
        async let hero: [(title: String, text: String)] = lookUpMany(host: "superheroes.fandom.com", query: query, count: 1, limit: 900)
        async let instant: String? = instantAnswer(query + " " + house)
        // "Who lives there / who is in it / what is its history" is answered by the full page and its member lists, not the intro.
        async let deepFan: [(title: String, text: String)] = {
            guard deep, let h = host else { return [] }
            return await lookUpMany(host: h, query: query, count: 1, limit: 2600, full: true)
        }()
        async let deepWiki: [(title: String, text: String)] = deep ? lookUpMany(host: "en.wikipedia.org", query: query + " " + house, count: 1, limit: 2600, full: true) : []
        async let people: [(title: String, text: String)] = deep ? lookUpMany(host: "en.wikipedia.org", query: query + " residents members inhabitants", count: 2, limit: 700) : []
        async let peopleFan: [(title: String, text: String)] = {
            guard deep, let h = host else { return [] }
            return await lookUpMany(host: h, query: query + " residents members", count: 2, limit: 700)
        }()
        var seen = Set<String>()
        func add(_ label: String, _ list: [(title: String, text: String)]) {
            for r in list where seen.insert(r.title.lowercased() + "|" + String(r.text.prefix(60)).lowercased()).inserted {
                parts.append("[\(r.title) – \(label)] " + r.text)
            }
        }
        add("full page, comics wiki", await deepFan)
        add("full page, Wikipedia", await deepWiki)
        add("comics wiki", await fan)
        add("comics wiki", await peopleFan)
        add("Wikipedia", await wiki)
        add("Wikipedia", await people)
        add("Wikipedia", await wiki2)
        add("Superhero wiki", await hero)
        if let i = await instant, !seen.contains(String(i.prefix(60)).lowercased()) { parts.append("[Web summary] " + i) }
        return parts
    }

    /// One whole page by name from the comics wiki, falling back to Wikipedia (what the model's page-reading tool runs).
    static func readPage(_ title: String, publisher: String?) async -> String {
        async let fan: String? = {
            guard let h = fandomHost(publisher) else { return nil }
            return await extract(host: h, title: title, limit: 3200, full: true)
        }()
        async let wiki: String? = extract(host: "en.wikipedia.org", title: title, limit: 3200, full: true)
        var out: [String] = []
        if let f = await fan { out.append("[\(title) – comics wiki, full page] " + f) }
        if let w = await wiki { out.append("[\(title) – Wikipedia, full page] " + w) }
        return out.isEmpty ? "No page called \(title)." : out.joined(separator: "\n")
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
