import Foundation

/// A short log of what the lookups did (which sites answered, which refused), written into the debug file.
enum Diagnostics {
    private static let lock = NSLock()
    private static var lines: [String] = []
    static func add(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(s)
        if lines.count > 80 { lines.removeFirst(lines.count - 80) }
    }
    static var text: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

enum HTTP {
    static let userAgent = "PanelSnap/1.0 (iOS comic reader; https://github.com/jakebway/PanelSnap)"

    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ s: String) -> String {
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func url(_ base: String, _ items: [(String, String)]) -> URL? {
        let query = items.map { $0.0 + "=" + encode($0.1) }.joined(separator: "&")
        return URL(string: base + (base.contains("?") ? "&" : "?") + query)
    }

    static func json(_ url: URL, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) async throws -> Any {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.httpMethod = method
        req.httpBody = body
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            Diagnostics.add("FAILED \(url.host ?? "?") \(url.query?.prefix(60) ?? ""): \(error.localizedDescription)")
            throw error
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Diagnostics.add("HTTP \(http.statusCode) \(url.host ?? "?") \(url.query?.prefix(60) ?? "")")
            throw URLError(.badServerResponse)
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}

/// Turns HTML / wiki markup into readable plain text.
enum TextClean {

    static func html(_ input: String) -> String {
        var s = input
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "</p>", with: "\n\n")
        s = s.replacingOccurrences(of: "<li>", with: "• ")
        s = s.replacingOccurrences(of: "</li>", with: "\n")
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        return tidy(s)
    }

    static func decodeEntities(_ input: String) -> String {
        var s = input
        let map: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&#039;", "'"),
            ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
            ("&ldquo;", "“"), ("&rdquo;", "”"), ("&ndash;", "–"), ("&mdash;", "—"), ("&hellip;", "…")
        ]
        for (k, v) in map { s = s.replacingOccurrences(of: k, with: v) }
        return s
    }

    static func tidy(_ input: String) -> String {
        var s = input.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cuts text to roughly `limit` characters at a sentence end.
    static func shorten(_ input: String, limit: Int) -> String {
        if input.count <= limit { return input }
        let head = String(input.prefix(limit))
        if let r = head.range(of: ". ", options: .backwards), head.distance(from: head.startIndex, to: r.lowerBound) > limit / 2 {
            return String(head[head.startIndex..<r.lowerBound]) + "."
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func wiki(_ input: String) -> String {
        var s = input
        s = s.replacingOccurrences(of: "<ref[^>]*/>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?s)<ref[^>]*>.*?</ref>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<!--.*?-->", with: "", options: [.regularExpression])
        for _ in 0..<5 {
            s = s.replacingOccurrences(of: "\\{\\{[^{}]*\\}\\}", with: "", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "\\[\\[(?:File|Image|Category):[^\\]]*\\]\\]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[\\[[^\\]|]*\\|([^\\]]*)\\]\\]", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[\\[([^\\]]*)\\]\\]", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "'{2,5}", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        return tidy(s)
    }
}

enum Similarity {
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let kept = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        var out = ""
        out.unicodeScalars.append(contentsOf: kept)
        return out
    }

    /// Roughly "do these two series names mean the same thing?"
    static func score(_ a: String, _ b: String) -> Int {
        let x = normalize(a)
        let y = normalize(b)
        if x.isEmpty || y.isEmpty { return 0 }
        if x == y { return 100 }
        let stripped = { (s: String) -> String in
            return s.hasPrefix("the") ? String(s.dropFirst(3)) : s
        }
        if stripped(x) == stripped(y) { return 95 }
        if x.contains(y) || y.contains(x) { return 55 }
        return 0
    }
}
