import Foundation

// MARK: - Grand Comics Database (no key needed)

/// The GCD is a volunteer-built catalogue of comics. Its public API works without an account.
/// Data is shared under CC BY-SA 4.0 (https://www.comics.org).
enum GCDProvider {
    static let base = "https://www.comics.org/api"

    private static func clean(_ s: Any?) -> String? {
        guard var t = s as? String else { return nil }
        t = t.replacingOccurrences(of: "\\(signed\\)|\\(credited\\)|\\(uncredited\\)|\\[[^\\]]*\\]", with: "", options: .regularExpression)
        t = TextClean.tidy(t)
        if t.isEmpty || t == "?" || t.lowercased() == "none" || t.lowercased() == "n/a" { return nil }
        return t
    }

    private static func names(_ s: Any?) -> [String] {
        guard let raw = s as? String else { return [] }
        return raw.split(separator: ";").compactMap { part in
            var t = String(part)
            t = t.replacingOccurrences(of: "\\([^)]*\\)|\\[[^\\]]*\\]", with: "", options: .regularExpression)
            t = TextClean.tidy(t)
            return (t.isEmpty || t == "?" || t.lowercased() == "none") ? nil : t
        }
    }

    /// "Batman [Bruce Wayne]; Joker (flashback)" -> [("Batman", "Bruce Wayne"), ("Joker", nil)]
    private static func characters(_ raw: String) -> [(String, String?)] {
        let parts: [String]
        if raw.contains(";") {
            parts = raw.split(separator: ";").map(String.init)
        } else {
            // A plain comma list, but keep commas that sit inside brackets/parentheses.
            var out: [String] = []
            var depth = 0
            var cur = ""
            for ch in raw {
                if ch == "(" || ch == "[" { depth += 1 }
                if ch == ")" || ch == "]" { depth = max(0, depth - 1) }
                if ch == "," && depth == 0 { out.append(cur); cur = "" } else { cur.append(ch) }
            }
            out.append(cur)
            parts = out
        }
        var result: [(String, String?)] = []
        for p in parts {
            var name = p
            var real: String?
            if let r = p.range(of: "\\[([^\\]]+)\\]", options: .regularExpression) {
                real = String(p[r]).trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            }
            name = name.replacingOccurrences(of: "\\([^)]*\\)|\\[[^\\]]*\\]", with: "", options: .regularExpression)
            name = TextClean.tidy(name)
            if name.count < 2 || name.lowercased().hasPrefix("plus ") || name.lowercased() == "none" { continue }
            result.append((name, real))
        }
        return result
    }

    private static func seriesBaseName(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*$", with: "", options: .regularExpression)
    }

    static func lookup(series: String, issue: String?, year: Int?, publisher: String?) async -> CompanionData? {
        guard let number = issue, !number.isEmpty else { return nil }
        var path = "/series/name/\(HTTP.encode(series))/issue/\(HTTP.encode(number))"
        if let y = year { path += "/year/\(y)" }
        guard let listURL = URL(string: base + path + "/?format=json"),
              let root = try? await HTTP.json(listURL) as? [String: Any],
              let results = root["results"] as? [[String: Any]], !results.isEmpty else {
            Console.log("gcd: nothing for \(series) #\(number)")
            return nil
        }

        // The name search matches anywhere in a title, so keep only exact series names, originals first.
        let want = Similarity.normalize(series)
        let exact = results.filter {
            let n = Similarity.normalize(seriesBaseName(($0["series_name"] as? String) ?? ""))
            return n == want && ($0["variant_of"] == nil || $0["variant_of"] is NSNull)
        }
        guard let pick = exact.first(where: { (($0["series_name"] as? String) ?? "").contains("(\(year ?? 0) series)") }) ?? exact.first,
              let urlString = pick["api_url"] as? String, let url = URL(string: urlString),
              let d = try? await HTTP.json(url) as? [String: Any] else { return nil }

        var out = CompanionData()
        out.sources.append("Grand Comics Database")
        if let c = d["cover"] as? String, !c.isEmpty { out.coverURL = c }
        if let n = d["number"] as? Int { out.issue = String(n) }
        if let t = clean(d["title"]) { out.title = t }
        if let p = clean(d["indicia_publisher"]) { out.publisher = out.publisher ?? p }
        let siteID = urlString.split(separator: "/").dropLast().last.map(String.init) ?? ""
        let siteURL = "https://www.comics.org/issue/\(siteID)/"
        out.links.append(LinkItem(title: "This issue on the Grand Comics Database", url: siteURL))

        for n in names(d["editing"]) { out.creators.append(Credit(role: "Editor", name: n)) }

        var synopses: [String] = []
        var cast: [(String, String?)] = []
        if let stories = d["story_set"] as? [[String: Any]] {
            for st in stories {
                let type = (st["type"] as? String) ?? ""
                if type == "cover" {
                    for n in names(st["pencils"]) { out.creators.append(Credit(role: "Cover", name: n)) }
                    continue
                }
                guard type == "comic story" else { continue }
                let roles: [(String, String)] = [("script", "Writer"), ("pencils", "Penciller"), ("inks", "Inker"),
                                                 ("colors", "Colorist"), ("letters", "Letterer")]
                for (key, role) in roles {
                    for n in names(st[key]) { out.creators.append(Credit(role: role, name: n)) }
                }
                if let g = clean(st["genre"]) {
                    for part in g.split(separator: ";") {
                        let t = part.trimmingCharacters(in: .whitespaces).capitalized
                        if !t.isEmpty && !out.genres.contains(t) { out.genres.append(t) }
                    }
                }
                if let ch = st["characters"] as? String { cast += characters(ch) }
                if let syn = clean(st["synopsis"]), syn.count > 30 { synopses.append(syn) }
            }
        }
        if !synopses.isEmpty {
            out.issueSynopsis = TextBlock(text: TextClean.shorten(synopses.joined(separator: "\n\n"), limit: 1800),
                                          source: "Grand Comics Database", url: siteURL)
        }
        var seen = Set<String>()
        for (name, real) in cast where seen.insert(Similarity.normalize(name)).inserted {
            out.characters.append(CharacterCard(name: name, role: real, blurb: nil, imageURL: nil, url: nil, source: nil))
            if out.characters.count >= 24 { break }
        }
        return out
    }
}

// MARK: - Open Library (books and graphic novels, no key needed)

enum OpenLibraryProvider {
    /// A description for collected editions / graphic novels that Wikipedia may not cover.
    static func lookup(series: String, publisher: String?) async -> CompanionData? {
        guard let url = HTTP.url("https://openlibrary.org/search.json", [
            ("q", series + " graphic novel"), ("limit", "5"), ("fields", "key,title,first_publish_year")
        ]), let root = try? await HTTP.json(url) as? [String: Any],
              let docs = root["docs"] as? [[String: Any]] else { return nil }
        let want = Similarity.normalize(series)
        for doc in docs {
            guard let key = doc["key"] as? String, let title = doc["title"] as? String,
                  Similarity.score(title, series) >= 55, !want.isEmpty,
                  let workURL = URL(string: "https://openlibrary.org\(key).json"),
                  let work = try? await HTTP.json(workURL) as? [String: Any] else { continue }
            var text: String?
            if let d = work["description"] as? String { text = d }
            else if let o = work["description"] as? [String: Any] { text = o["value"] as? String }
            guard var t = text else { continue }
            t = t.components(separatedBy: "\n----").first ?? t
            t = TextClean.shorten(TextClean.html(t), limit: 900)
            if t.count < 60 { continue }
            var out = CompanionData()
            let page = "https://openlibrary.org\(key)"
            out.seriesSummary = TextBlock(text: t, source: "Open Library", url: page)
            out.links.append(LinkItem(title: "Open Library: " + title, url: page))
            out.sources.append("Open Library")
            return out
        }
        return nil
    }
}

// MARK: - Wikipedia (no key needed)

enum WikipediaProvider {

    struct Page {
        var title: String
        var extract: String
        var url: String?
        var imageURL: String?
    }

    static func lookup(query: String, mustMention: [String]) async -> Page? {
        guard let searchURL = HTTP.url("https://en.wikipedia.org/w/api.php", [
            ("action", "query"), ("list", "search"), ("srsearch", query), ("srlimit", "4"), ("format", "json")
        ]) else { return nil }
        guard let root = try? await HTTP.json(searchURL) as? [String: Any],
              let q = root["query"] as? [String: Any],
              let hits = q["search"] as? [[String: Any]] else { return nil }

        for hit in hits {
            guard let title = hit["title"] as? String else { continue }
            let slug = title.replacingOccurrences(of: " ", with: "_")
            let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
            guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/" + encoded),
                  let obj = try? await HTTP.json(url) as? [String: Any] else { continue }
            if (obj["type"] as? String) == "disambiguation" { continue }
            guard let extract = obj["extract"] as? String, extract.count > 40 else { continue }
            let lower = extract.lowercased()
            if !mustMention.contains(where: { lower.contains($0) }) { continue }

            var page = Page(title: title, extract: extract, url: nil, imageURL: nil)
            if let urls = obj["content_urls"] as? [String: Any],
               let desktop = urls["desktop"] as? [String: Any] {
                page.url = desktop["page"] as? String
            }
            if let thumb = obj["thumbnail"] as? [String: Any] {
                page.imageURL = thumb["source"] as? String
            }
            return page
        }
        return nil
    }

    static func series(name: String, publisher: String?) async -> CompanionData? {
        var query = name + " comic series"
        if let p = publisher, !p.isEmpty { query = name + " " + p + " comic series" }
        guard let page = await lookup(query: query, mustMention: ["comic", "manga", "graphic novel", "series"]) else { return nil }
        var out = CompanionData()
        out.seriesSummary = TextBlock(text: TextClean.shorten(page.extract, limit: 900), source: "Wikipedia", url: page.url)
        if let u = page.url { out.links.append(LinkItem(title: "Wikipedia: " + page.title, url: u)) }
        out.sources.append("Wikipedia")
        return out
    }

    static func character(name: String, publisher: String?) async -> CharacterCard? {
        var query = name + " comics character"
        if let p = publisher, !p.isEmpty { query = name + " " + p + " character" }
        guard let page = await lookup(query: query, mustMention: ["fictional", "character", "superhero", "villain", "comic", "manga"]) else { return nil }
        return CharacterCard(
            name: name,
            role: nil,
            blurb: TextClean.shorten(page.extract, limit: 520),
            imageURL: page.imageURL,
            url: page.url,
            source: "Wikipedia"
        )
    }
}

// MARK: - Marvel / DC fan wikis (no key needed, best effort)

enum FandomProvider {

    static func host(for publisher: String?) -> (host: String, name: String)? {
        let p = (publisher ?? "").lowercased()
        if p.contains("marvel") { return ("marvel.fandom.com", "Marvel Database") }
        if p == "dc" || p.contains("dc comics") || p.contains("vertigo") || p.contains("dc black label") {
            return ("dc.fandom.com", "DC Database")
        }
        return nil
    }

    static func lookup(publisher: String?, series: String, volume: String?, issue: String, year: Int? = nil) async -> CompanionData? {
        guard let site = host(for: publisher) else { return nil }
        let vol = (volume?.isEmpty == false) ? volume! : "1"

        var candidates: [String] = ["\(series) Vol \(vol) \(issue)"]
        if vol != "1" { candidates.append("\(series) Vol 1 \(issue)") }
        if year != nil {
            // The same name was reused for later runs ("Vision and the Scarlet Witch" 1982 is Vol 1, 1985 is Vol 2).
            for v in 2...5 where !candidates.contains("\(series) Vol \(v) \(issue)") { candidates.append("\(series) Vol \(v) \(issue)") }
        }

        // Fall back to the wiki's search if the guessed page name is wrong.
        if let searchURL = HTTP.url("https://\(site.host)/api.php", [
            ("action", "query"), ("list", "search"), ("srsearch", "\(series) \(issue)"), ("srlimit", "5"), ("format", "json")
        ]), let root = try? await HTTP.json(searchURL) as? [String: Any],
           let q = root["query"] as? [String: Any], let hits = q["search"] as? [[String: Any]] {
            for h in hits {
                guard let t = h["title"] as? String else { continue }
                let lower = t.lowercased()
                if lower.hasSuffix(" " + issue) && lower.contains(series.lowercased()) && !candidates.contains(t) {
                    candidates.append(t)
                }
            }
        }

        for title in candidates {
            guard let parseURL = HTTP.url("https://\(site.host)/api.php", [
                ("action", "parse"), ("page", title), ("prop", "wikitext"), ("redirects", "1"),
                ("format", "json"), ("formatversion", "2")
            ]), let root = try? await HTTP.json(parseURL) as? [String: Any],
               let parse = root["parse"] as? [String: Any] else { continue }

            var wikitext: String?
            if let s = parse["wikitext"] as? String {
                wikitext = s
            } else if let o = parse["wikitext"] as? [String: Any] {
                wikitext = o["*"] as? String
            }
            guard let text = wikitext else { continue }
            if let want = year, let r = text.range(of: "\\|\\s*Year\\s*=\\s*(\\d{4})", options: .regularExpression) {
                let found = Int(text[r].filter { $0.isNumber }.suffix(4)) ?? want
                if found < want - 1 || found > want + 4 { continue }      // a different run with the same name
            }
            let synopsis = extractSynopsis(text)
            let pageTitle = (parse["title"] as? String) ?? title
            let slug = pageTitle.replacingOccurrences(of: " ", with: "_")
            let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
            let pageURL = "https://\(site.host)/wiki/\(encoded)"

            var out = CompanionData()
            out.links.append(LinkItem(title: "\(site.name): \(pageTitle)", url: pageURL))
            if let s = synopsis {
                out.issueSynopsis = TextBlock(text: TextClean.shorten(s, limit: 2200), source: site.name, url: pageURL)
            }
            out.sources.append(site.name)
            out.creators = credits(in: text)
            out.characters = appearances(in: text, host: site.host)
            return out
        }
        return nil
    }

    private static func linkNames(_ raw: String) -> [String] {
        var names: [String] = []
        let ns = raw as NSString
        if let re = try? NSRegularExpression(pattern: "\\[\\[([^\\]|#]+)(?:\\|([^\\]]*))?\\]\\]") {
            for m in re.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
                var shown = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ns.substring(with: m.range(at: 1))
                shown = shown.replacingOccurrences(of: "\\s*\\(.*\\)$", with: "", options: .regularExpression)
                shown = TextClean.tidy(shown)
                if !shown.isEmpty { names.append(shown) }
            }
        }
        return names
    }

    /// | Writer1_1 = [[Name]] style infobox fields.
    static func credits(in wikitext: String) -> [Credit] {
        let fields: [(String, String)] = [("Writer", "Writer"), ("Penciler", "Penciller"), ("Inker", "Inker"),
                                          ("Colourist", "Colorist"), ("Letterer", "Letterer"), ("Editor", "Editor"),
                                          ("CoverArtist", "Cover")]
        var out: [Credit] = []
        for (field, role) in fields {
            let pattern = "\\|\\s*" + field + "\\d*(?:_\\d+)?\\s*=\\s*([^\\n]*)"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = wikitext as NSString
            for m in re.matches(in: wikitext, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                let raw = ns.substring(with: m.range(at: 1))
                var found = linkNames(raw)
                if found.isEmpty {
                    let plain = TextClean.wiki(raw)
                    if plain.count > 1 && plain.count < 40 && plain != "?" { found = [plain] }
                }
                for n in found where !out.contains(where: { $0.name == n && $0.role == role }) {
                    out.append(Credit(role: role, name: n))
                }
            }
        }
        return out
    }

    /// The "Appearing in" lists: featured characters first, then supporting, then villains.
    static func appearances(in wikitext: String, host: String) -> [CharacterCard] {
        var out: [CharacterCard] = []
        let pattern = "(?:Featured|Supporting|Antagonists|Villains)\\s*Characters?:?\\s*\\n(.*?)(?=\\n\\s*(?:Featured|Supporting|Antagonists|Villains|Other|Races|Locations|Items|Vehicles|Synopsis|Solicit|Notes|Trivia|\\|)|\\n==|\\z)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = wikitext as NSString
        for m in re.matches(in: wikitext, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
            for name in linkNames(ns.substring(with: m.range(at: 1))) where !out.contains(where: { CompanionData.same($0.name, name) }) {
                out.append(CharacterCard(name: name, role: nil, blurb: nil, imageURL: nil, url: nil, source: nil))
            }
        }
        return Array(out.prefix(20))
    }

    /// Pulls the "Synopsis" parts out of the wiki page's source.
    static func extractSynopsis(_ wikitext: String) -> String? {
        var parts: [String] = []

        // Template style: | Synopsis1 = text...
        let templatePattern = "\\|\\s*Synopsis\\d*\\s*=\\s*(.*?)(?=\\n\\s*\\|\\s*[A-Za-z0-9_]+\\s*=|\\n\\s*\\}\\})"
        if let re = try? NSRegularExpression(pattern: templatePattern, options: [.dotMatchesLineSeparators]) {
            let ns = wikitext as NSString
            let matches = re.matches(in: wikitext, range: NSRange(location: 0, length: ns.length))
            for m in matches where m.numberOfRanges > 1 {
                let raw = ns.substring(with: m.range(at: 1))
                let cleaned = TextClean.wiki(raw)
                if cleaned.count > 40 && !cleaned.lowercased().contains("not yet written") {
                    parts.append(cleaned)
                }
            }
        }

        // Heading style: == Synopsis for "Title" == ...
        if parts.isEmpty {
            let headingPattern = "==+\\s*Synopsis[^=]*==+\\s*\\n(.*?)(?=\\n==|\\z)"
            if let re = try? NSRegularExpression(pattern: headingPattern, options: [.dotMatchesLineSeparators]) {
                let ns = wikitext as NSString
                let matches = re.matches(in: wikitext, range: NSRange(location: 0, length: ns.length))
                for m in matches where m.numberOfRanges > 1 {
                    let cleaned = TextClean.wiki(ns.substring(with: m.range(at: 1)))
                    if cleaned.count > 40 && !cleaned.lowercased().contains("not yet written") {
                        parts.append(cleaned)
                    }
                }
            }
        }
        if parts.isEmpty { return nil }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - AniList (manga, no key needed)

enum AniListProvider {

    static func lookup(series: String, strict: Bool) async -> CompanionData? {
        guard let url = URL(string: "https://graphql.anilist.co") else { return nil }
        let query = """
        query ($s: String) {
          Media(search: $s, type: MANGA) {
            siteUrl
            title { romaji english }
            description(asHtml: false)
            genres
            coverImage { large }
            staff(perPage: 6) { edges { role node { name { full } } } }
            characters(perPage: 12, sort: ROLE) { nodes { name { full } image { medium } siteUrl } }
          }
        }
        """
        let payload: [String: Any] = ["query": query, "variables": ["s": series]]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        guard let root = try? await HTTP.json(url, method: "POST", body: body, headers: ["Content-Type": "application/json"]) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let media = data["Media"] as? [String: Any] else { return nil }

        if strict {
            var names: [String] = []
            if let t = media["title"] as? [String: Any] {
                if let r = t["romaji"] as? String { names.append(r) }
                if let e = t["english"] as? String { names.append(e) }
            }
            let ok = names.contains(where: { Similarity.score($0, series) >= 55 })
            if !ok { return nil }
        }

        var out = CompanionData()
        if let desc = media["description"] as? String, !desc.isEmpty {
            out.seriesSummary = TextBlock(text: TextClean.shorten(TextClean.html(desc), limit: 900), source: "AniList", url: media["siteUrl"] as? String)
        }
        if let g = media["genres"] as? [String] { out.genres = g }
        if let cover = media["coverImage"] as? [String: Any] { out.coverURL = cover["large"] as? String }
        if let staff = media["staff"] as? [String: Any], let edges = staff["edges"] as? [[String: Any]] {
            for e in edges {
                guard let node = e["node"] as? [String: Any], let name = (node["name"] as? [String: Any])?["full"] as? String else { continue }
                out.creators.append(Credit(role: (e["role"] as? String) ?? "Staff", name: name))
            }
        }
        if let chars = media["characters"] as? [String: Any], let nodes = chars["nodes"] as? [[String: Any]] {
            for n in nodes {
                guard let name = (n["name"] as? [String: Any])?["full"] as? String else { continue }
                let img = (n["image"] as? [String: Any])?["medium"] as? String
                out.characters.append(CharacterCard(name: name, role: nil, blurb: nil, imageURL: img, url: n["siteUrl"] as? String, source: "AniList"))
            }
        }
        if let site = media["siteUrl"] as? String { out.links.append(LinkItem(title: "Series on AniList", url: site)) }
        out.sources.append("AniList")
        return out
    }
}
