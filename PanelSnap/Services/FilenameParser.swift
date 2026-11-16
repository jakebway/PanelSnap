import Foundation

/// Turns file names like "Batman 012 (2016) (Digital).cbz" into series / issue / year.
enum FilenameParser {

    static func parse(_ fileName: String) -> ComicIdentity {
        var name = fileName
        if let dot = name.lastIndex(of: "."), name.distance(from: dot, to: name.endIndex) <= 6 {
            name = String(name[name.startIndex..<dot])
        }
        name = name.replacingOccurrences(of: "_", with: " ")

        var identity = ComicIdentity()

        // Year in parentheses, e.g. (2016)
        if let m = firstMatch("\\((19\\d{2}|20\\d{2})\\)", in: name) {
            identity.year = Int(m)
        }

        // Remove (...) and [...] groups.
        var cleaned = replace("\\([^)]*\\)", in: name, with: " ")
        cleaned = replace("\\[[^\\]]*\\]", in: cleaned, with: " ")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Volume: v2, vol 2, volume 2
        if let vol = firstMatch("(?i)\\bv(?:ol(?:ume)?)?\\.?\\s*(\\d{1,3})\\b", in: cleaned, group: 1) {
            identity.volume = vol
            cleaned = replace("(?i)\\bv(?:ol(?:ume)?)?\\.?\\s*\\d{1,3}\\b", in: cleaned, with: " ")
        }

        // Issue: "#12", "No. 12", "Issue 12", or a trailing number.
        var issue: String?
        var seriesPart = cleaned
        if let m = firstMatchRange("(?i)(?:#|\\bno\\.?\\s*|\\bissue\\s*)(\\d{1,4}(?:\\.\\d)?)", in: cleaned) {
            issue = m.number
            seriesPart = String(cleaned[cleaned.startIndex..<m.start])
        } else if let m = firstMatchRange("(?:^|[\\s-])(\\d{1,4}(?:\\.\\d)?)\\s*$", in: cleaned) {
            // A trailing 4-digit number that looks like a year ("Batman 2016") is the year, not issue #2016.
            if let n = Int(m.number), m.number.count == 4, (1900...2099).contains(n) {
                if identity.year == nil { identity.year = n }
                seriesPart = String(cleaned[cleaned.startIndex..<m.start])
            } else {
                issue = m.number
                seriesPart = String(cleaned[cleaned.startIndex..<m.start])
            }
        }

        if let i = issue {
            // Normalise "012" -> "12"
            if let n = Int(i) { identity.issue = String(n) } else { identity.issue = i }
        }

        seriesPart = replace("[\\s\\-:–—]+$", in: seriesPart, with: "")
        seriesPart = replace("\\s{2,}", in: seriesPart, with: " ")
        seriesPart = seriesPart.trimmingCharacters(in: .whitespacesAndNewlines)
        identity.series = seriesPart.isEmpty ? nil : seriesPart
        if identity.series == nil {
            let t = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            identity.series = t.isEmpty ? nil : t
        }
        return identity
    }

    // MARK: - regex helpers

    private struct Found {
        var number: String
        var start: String.Index
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let idx = m.numberOfRanges > group ? group : 0
        let r = m.range(at: idx)
        if r.location == NSNotFound { return nil }
        return ns.substring(with: r)
    }

    private static func firstMatchRange(_ pattern: String, in text: String) -> Found? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let whole = m.range(at: 0)
        let num = m.range(at: 1)
        if whole.location == NSNotFound || num.location == NSNotFound { return nil }
        guard let startIdx = Range(whole, in: text)?.lowerBound else { return nil }
        return Found(number: ns.substring(with: num), start: startIdx)
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
