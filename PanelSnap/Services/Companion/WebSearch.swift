import Foundation

/// A plain web search with no key: DuckDuckGo's HTML results, then the readable text of the top pages.
enum WebSearch {
    private static let browser = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    /// Sites that are already searched directly, or that never hold readable facts.
    private static let skip = ["wikipedia.org", "fandom.com", "youtube.com", "youtu.be", "facebook.com", "instagram.com", "tiktok.com", "pinterest.",
                               "twitter.com", "x.com", "amazon.", "ebay.", "quora.com", "reddit.com", "imdb.com"]

    struct Result { var title: String; var url: URL; var snippet: String }

    private static func get(_ url: URL, timeout: TimeInterval) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue(browser, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Diagnostics.add("HTTP \(http.statusCode) \(url.host ?? "?")")
                return nil
            }
            let capped = data.prefix(600_000)
            return String(data: capped, encoding: .utf8) ?? String(data: capped, encoding: .isoLatin1)
        } catch {
            Diagnostics.add("FAILED \(url.host ?? "?"): \(error.localizedDescription)")
            return nil
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = text as NSString
        return rx.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        }
    }

    static func results(_ query: String) async -> [Result] {
        guard let url = HTTP.url("https://html.duckduckgo.com/html/", [("q", query)]), let html = await get(url, timeout: 6) else { return [] }
        let links = matches("<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", in: html)
        let snippets = matches("class=\"result__snippet\"[^>]*>(.*?)</a>", in: html).map { $0[0] }
        var out: [Result] = []
        for (i, l) in links.enumerated() {
            var href = TextClean.decodeEntities(l[0])
            if href.hasPrefix("//") { href = "https:" + href }
            var target = href
            if let c = URLComponents(string: href), let u = c.queryItems?.first(where: { $0.name == "uddg" })?.value { target = u }
            guard let u = URL(string: target), let host = u.host?.lowercased(), u.scheme?.hasPrefix("http") == true else { continue }
            if skip.contains(where: { host.contains($0) }) { continue }
            let title = TextClean.html(l[1])
            let snip = i < snippets.count ? TextClean.html(snippets[i]) : ""
            out.append(Result(title: title, url: u, snippet: snip))
        }
        if out.isEmpty { Diagnostics.add("NO RESULTS duckduckgo for \"\(query)\"") }
        return out
    }

    /// The readable text of a web page: no scripts, menus or footers, and only lines that read like sentences.
    static func readable(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "nav", "header", "footer", "aside", "form", "noscript", "svg"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>.*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<!--.*?-->", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "</(p|div|h[1-6]|tr|section|article)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        let text = TextClean.html(s)
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 50 }
        return lines.joined(separator: " ")
    }

    /// Search, read the top pages at once, and return one entry per page. Never takes longer than `seconds`.
    static func parts(_ query: String, pages: Int = 4, seconds: UInt64 = 5) async -> [(title: String, text: String)] {
        return await withTaskGroup(of: [(title: String, text: String)]?.self) { group in
            group.addTask {
                let found = Array(await results(query).prefix(pages))
                return await withTaskGroup(of: (Int, String, String)?.self) { inner in
                    for (i, r) in found.enumerated() {
                        inner.addTask {
                            let host = (r.url.host ?? "").replacingOccurrences(of: "www.", with: "")
                            var body = r.snippet
                            if let html = await get(r.url, timeout: 4) {
                                let page = readable(html)
                                if page.count > 200 { body += " " + TextClean.shorten(page, limit: 4500) }
                            }
                            return body.count > 40 ? (i, "\(r.title) (\(host))", body) : nil
                        }
                    }
                    var got: [(Int, String, String)] = []
                    for await x in inner {
                        if let x = x { got.append(x) }
                        if got.count >= 3 { inner.cancelAll(); break }      // three readable pages are plenty; don't wait for the slow one
                    }
                    return got.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
                }
            }
            group.addTask { try? await Task.sleep(nanoseconds: seconds * 1_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }
}
