import Foundation

// MARK: - Comic Vine (needs a free API key)

enum ComicVineProvider {
    static let base = "https://comicvine.gamespot.com/api"

    static func lookup(series: String, issue: String?, year: Int?, key: String) async throws -> CompanionData? {
        var out = CompanionData()

        // 1. Find the series ("volume" in Comic Vine speak).
        guard let searchURL = HTTP.url(base + "/search/", [
            ("api_key", key), ("format", "json"), ("resources", "volume"), ("query", series), ("limit", "10"),
            ("field_list", "id,name,start_year,publisher,count_of_issues,description,deck,image,site_detail_url")
        ]) else { return nil }
        guard let root = try await HTTP.json(searchURL) as? [String: Any],
              let results = root["results"] as? [[String: Any]], !results.isEmpty else { return nil }

        var best: [String: Any]?
        var bestScore = -1
        for r in results {
            let name = (r["name"] as? String) ?? ""
            var score = Similarity.score(name, series)
            if score == 0 { continue }
            if let y = year, let start = Int((r["start_year"] as? String) ?? "") {
                if start <= y { score += max(0, 20 - (y - start)) } else { score -= 10 }
            }
            if let count = r["count_of_issues"] as? Int { score += min(count / 20, 10) }
            if score > bestScore {
                bestScore = score
                best = r
            }
        }
        guard let volume = best, let volumeID = volume["id"] as? Int else { return nil }

        out.series = volume["name"] as? String
        if let pub = volume["publisher"] as? [String: Any] { out.publisher = pub["name"] as? String }
        if let s = volume["start_year"] as? String { out.year = Int(s) }
        if let desc = volume["description"] as? String, !desc.isEmpty {
            let text = TextClean.shorten(TextClean.html(desc), limit: 900)
            if text.count > 30 {
                out.seriesSummary = TextBlock(text: text, source: "Comic Vine", url: volume["site_detail_url"] as? String)
            }
        } else if let deck = volume["deck"] as? String, !deck.isEmpty {
            out.seriesSummary = TextBlock(text: TextClean.html(deck), source: "Comic Vine", url: volume["site_detail_url"] as? String)
        }
        if let url = volume["site_detail_url"] as? String {
            out.links.append(LinkItem(title: "Series on Comic Vine", url: url))
        }
        out.sources.append("Comic Vine")

        // 2. Find the issue.
        guard let number = issue, !number.isEmpty,
              let issuesURL = HTTP.url(base + "/issues/", [
                ("api_key", key), ("format", "json"), ("limit", "1"),
                ("filter", "volume:\(volumeID),issue_number:\(number)"),
                ("field_list", "id,name,issue_number,site_detail_url")
              ]),
              let issuesRoot = try await HTTP.json(issuesURL) as? [String: Any],
              let issues = issuesRoot["results"] as? [[String: Any]],
              let first = issues.first,
              let issueID = first["id"] as? Int else {
            return out
        }

        // 3. Get everything about that issue.
        guard let detailURL = HTTP.url(base + "/issue/4000-\(issueID)/", [
            ("api_key", key), ("format", "json"),
            ("field_list", "name,issue_number,description,deck,cover_date,image,person_credits,character_credits,team_credits,location_credits,story_arc_credits,site_detail_url")
        ]),
              let detailRoot = try await HTTP.json(detailURL) as? [String: Any],
              let d = detailRoot["results"] as? [String: Any] else {
            return out
        }

        out.issue = d["issue_number"] as? String
        if let t = d["name"] as? String, !t.isEmpty { out.title = t }
        if let image = d["image"] as? [String: Any] {
            out.coverURL = (image["medium_url"] as? String) ?? (image["small_url"] as? String)
        }
        if let cover = d["cover_date"] as? String, cover.count >= 4, let y = Int(cover.prefix(4)) {
            out.year = out.year ?? y
        }
        if let siteURL = d["site_detail_url"] as? String {
            out.links.append(LinkItem(title: "This issue on Comic Vine", url: siteURL))
        }

        var blurb = ""
        if let desc = d["description"] as? String, !desc.isEmpty { blurb = TextClean.html(desc) }
        if blurb.isEmpty, let deck = d["deck"] as? String { blurb = TextClean.html(deck) }
        if blurb.count > 30 {
            // Comic Vine issue descriptions are often full plot summaries, so keep them behind the spoiler shield.
            out.issueSynopsis = TextBlock(text: TextClean.shorten(blurb, limit: 1800), source: "Comic Vine", url: d["site_detail_url"] as? String)
        }

        if let people = d["person_credits"] as? [[String: Any]] {
            for p in people {
                guard let name = p["name"] as? String else { continue }
                let roles = ((p["role"] as? String) ?? "Credit").split(separator: ",")
                for r in roles {
                    let role = r.trimmingCharacters(in: .whitespaces).capitalized
                    out.creators.append(Credit(role: role, name: name))
                }
            }
        }
        if let chars = d["character_credits"] as? [[String: Any]] {
            for c in chars {
                guard let name = c["name"] as? String else { continue }
                out.characters.append(CharacterCard(name: name, role: nil, blurb: nil, imageURL: nil,
                                                    url: c["site_detail_url"] as? String, source: nil))
            }
        }
        if let teams = d["team_credits"] as? [[String: Any]] {
            out.teams = teams.compactMap { $0["name"] as? String }
        }
        if let places = d["location_credits"] as? [[String: Any]] {
            out.locations = places.compactMap { $0["name"] as? String }
        }
        if let arcs = d["story_arc_credits"] as? [[String: Any]] {
            out.arcs = arcs.compactMap { $0["name"] as? String }
        }
        return out
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

    static func lookup(publisher: String?, series: String, volume: String?, issue: String) async -> CompanionData? {
        guard let site = host(for: publisher) else { return nil }
        let vol = (volume?.isEmpty == false) ? volume! : "1"

        var candidates: [String] = ["\(series) Vol \(vol) \(issue)"]
        if vol != "1" { candidates.append("\(series) Vol 1 \(issue)") }

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
            return out
        }
        return nil
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
