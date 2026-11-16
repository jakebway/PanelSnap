import Foundation

/// The built-in "who's who". It ships inside the app (Resources/Characters.json), so character guides work offline
/// and need no account or key. Built from the Superhero API (MIT) and FiveThirtyEight's comic-characters data (CC BY 4.0).
struct GlossaryEntry: Codable {
    var n: String
    var r: String?
    var p: String
    var ap: Int?
    var y: Int?
    var w: String?
    var al: [String]?
    var fa: String?
    var g: String?
    var rel: String?
    var occ: String?
    var img: String?
}

final class CharacterGlossary {
    static let shared = CharacterGlossary()
    static let sourceName = "Built-in guide"

    private(set) var entries: [GlossaryEntry] = []
    private var byName: [String: Int] = [:]          // normalised name / real name / alias -> entry

    private init() {
        guard let url = Bundle.main.url(forResource: "Characters", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([GlossaryEntry].self, from: data) else {
            Console.log("glossary: Characters.json missing from the app")
            return
        }
        entries = list
        for (i, e) in list.enumerated() {
            for key in [e.n, e.r ?? ""] {
                let k = CharacterGlossary.norm(key)
                if k.count >= 3 && byName[k] == nil { byName[k] = i }
            }
        }
        for (i, e) in list.enumerated() {
            for a in e.al ?? [] {
                let k = CharacterGlossary.norm(a)
                if k.count >= 6 && byName[k] == nil { byName[k] = i }
            }
        }
        Console.log("glossary: \(list.count) built-in characters loaded")
    }

    static func norm(_ s: String) -> String {
        var out = ""
        for u in s.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(u) {
            out.unicodeScalars.append(u)
        }
        return out
    }

    /// Lower-case words separated by single spaces, e.g. "Spider-Man!" -> "spider man".
    private static func words(_ s: String) -> String {
        var out = ""
        var lastSpace = true
        for u in s.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) {
                out.unicodeScalars.append(u)
                lastSpace = false
            } else if !lastSpace {
                out += " "
                lastSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    func find(name: String) -> GlossaryEntry? {
        var cleaned = name
        if let r = cleaned.range(of: " [") { cleaned = String(cleaned[cleaned.startIndex..<r.lowerBound]) }
        if let i = byName[CharacterGlossary.norm(cleaned)] { return entries[i] }
        return nil
    }

    /// Characters named in the comic's title / series (case-insensitive) first, then names that show up
    /// at least twice (or are a full two-word name) in longer text such as a synopsis.
    func matches(titles: [String], texts: [String], limit: Int) -> [GlossaryEntry] {
        var found: [Int] = []
        var seen = Set<Int>()

        var titleHits: [(Int, Int)] = []          // (position, entry)
        for t in titles {
            let padded = " " + CharacterGlossary.words(t) + " "
            if padded.count < 5 { continue }
            for (i, e) in entries.enumerated() where !seen.contains(i) {
                for key in [e.n, e.r ?? ""] {
                    let w = CharacterGlossary.words(key)
                    if w.count < 4 { continue }
                    if let r = padded.range(of: " " + w + " ") {
                        titleHits.append((padded.distance(from: padded.startIndex, to: r.lowerBound), i))
                        seen.insert(i)
                        break
                    }
                }
            }
        }
        titleHits.sort { $0.0 < $1.0 }
        found += titleHits.map { $0.1 }

        // Longer text: count 1-3 word phrases, keeping their capital letters.
        var counts: [String: Int] = [:]
        for text in texts {
            let tokens = text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "'") }).map(String.init)
            if tokens.isEmpty { continue }
            for n in 1...3 {
                if tokens.count < n { break }
                for i in 0...(tokens.count - n) {
                    let first = tokens[i].first
                    if first == nil || !(first!.isUppercase) { continue }
                    counts[tokens[i..<(i + n)].joined(separator: " "), default: 0] += 1
                }
            }
        }
        var textHits: [(Int, Int)] = []           // (count, entry)
        for (i, e) in entries.enumerated() where !seen.contains(i) {
            var best = 0
            for key in [e.n, e.r ?? ""] where !key.isEmpty {
                let c = counts[key] ?? 0
                let multiword = key.contains(" ")
                if c >= 2 || (multiword && c >= 1) { best = max(best, c) }
            }
            if best > 0 { textHits.append((best, i)) }
        }
        textHits.sort { ($0.0, entries[$0.1].ap ?? 0) > ($1.0, entries[$1.1].ap ?? 0) }
        found += textHits.map { $0.1 }

        return found.prefix(limit).map { entries[$0] }
    }

    func publisherGuess(_ list: [GlossaryEntry]) -> String? {
        var tally: [String: Int] = [:]
        for e in list { tally[e.p, default: 0] += 1 }
        guard let top = tally.max(by: { $0.value < $1.value }), top.value >= 2 || list.count == 1 else { return nil }
        switch top.key {
        case "Marvel": return "Marvel Comics"
        case "DC": return "DC Comics"
        default: return nil
        }
    }

    func card(_ e: GlossaryEntry) -> CharacterCard {
        var real: String?
        if let r = e.r, !r.isEmpty, CharacterGlossary.norm(r) != CharacterGlossary.norm(e.n) { real = r }
        var facts: [Fact] = []
        if let real = real { facts.append(Fact(label: "Real name", value: real)) }
        if let a = e.al, !a.isEmpty { facts.append(Fact(label: "Also called", value: a.prefix(3).joined(separator: ", "))) }
        if let fa = e.fa, !fa.isEmpty {
            facts.append(Fact(label: "First appeared", value: fa))
        } else if let y = e.y, y > 0 {
            facts.append(Fact(label: "First appeared", value: String(y)))
        }
        if let ap = e.ap, ap >= 50 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            let n = f.string(from: NSNumber(value: ap)) ?? String(ap)
            facts.append(Fact(label: "Comics", value: "In about \(n) issues (2014 count)"))
        }
        if let g = e.g, !g.isEmpty { facts.append(Fact(label: "Teams", value: g)) }
        if let rel = e.rel, !rel.isEmpty { facts.append(Fact(label: "Family & friends", value: rel)) }
        if let o = e.occ, !o.isEmpty { facts.append(Fact(label: "Job", value: o)) }
        facts.append(Fact(label: "Publisher", value: e.p))
        var link = e.w
        if link?.isEmpty == true { link = nil }
        return CharacterCard(name: e.n, role: real, blurb: nil,
                             imageURL: (e.img?.isEmpty == false) ? e.img : nil,
                             url: link, source: CharacterGlossary.sourceName, facts: facts)
    }

    /// Adds the built-in facts to a card that came from somewhere else (e.g. the comic's own metadata).
    func enrich(_ c: CharacterCard, with e: GlossaryEntry) -> CharacterCard {
        let built = card(e)
        var out = c
        if out.facts == nil { out.facts = built.facts }
        if out.imageURL == nil { out.imageURL = built.imageURL }
        if out.url == nil { out.url = built.url }
        if out.role == nil { out.role = built.role }
        return out
    }
}
