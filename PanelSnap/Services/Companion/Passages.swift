import Foundation
import NaturalLanguage

/// Picks the few sentences, out of everything the searches found, that are closest in meaning to the question.
/// Uses Apple's built-in sentence embeddings (on the phone, no download) together with a keyword match.
enum Passages {
    private static let embedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    /// Loads the embedding model now, so the first question doesn't pay for it.
    static func warm() { _ = embedding?.vector(for: "warm up") }

    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count > 2 { out.append(s) }
            return true
        }
        return out
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    /// `parts` look like "[Title – source] text". Returns the same shape, cut down to the best sentences
    /// (each with its neighbours for context) within `maxChars`, in the original source order.
    static func best(parts: [String], question: String, maxChars: Int) -> [String] {
        guard !parts.isEmpty else { return [] }
        let keys = Knowledge.terms(question).map { String($0.prefix(6)) }
        let qv = embedding?.vector(for: question)
        let ql = question.lowercased()
        let wantsList = ["who", "which", "members", "live", "lives", "resident", "team", "list", "all"].contains { ql.contains($0) }
        var labels: [String] = []
        var sents: [[String]] = []
        for p in parts {
            var label = "[source] ", body = p
            if p.hasPrefix("["), let r = p.range(of: "] ") { label = String(p[..<r.upperBound]); body = String(p[r.upperBound...]) }
            labels.append(label)
            sents.append(sentences(body))
        }
        struct Item { var part: Int; var idx: Int; var score: Double }
        var items: [Item] = []
        for (pi, ss) in sents.enumerated() {
            for (si, s) in ss.enumerated() {
                let lower = s.lowercased()
                var hit = 0
                for k in keys where lower.contains(k) { hit += 1 }
                let kw = keys.isEmpty ? 0 : Double(hit) / Double(keys.count)
                var sem = 0.0
                if let e = embedding, let qv = qv, let sv = e.vector(for: s) { sem = max(0, cosine(qv, sv)) }
                // Member and resident lists read as a run of capitalised names; they rarely look like the question itself.
                var listBonus = 0.0
                if wantsList {
                    let names = s.split(separator: " ").filter { $0.first?.isUppercase == true }.count
                    if names >= 4 && s.contains(",") { listBonus = 0.25 } else if names >= 3 { listBonus = 0.1 }
                }
                items.append(Item(part: pi, idx: si, score: 0.55 * kw + 0.45 * sem + (si == 0 ? 0.15 : 0) + listBonus))
            }
        }
        guard let top = items.map({ $0.score }).max(), top >= 0 else { return Array(parts.prefix(3)) }
        var picked = [Set<Int>](repeating: [], count: parts.count)
        var used = 0
        for it in items.sorted(by: { $0.score > $1.score }) {
            let ss = sents[it.part]
            var add: [Int] = []
            for j in max(0, it.idx - 1)...min(ss.count - 1, it.idx + 1) where !picked[it.part].contains(j) { add.append(j) }
            var cost = add.reduce(0) { $0 + ss[$1].count + 1 }
            if picked[it.part].isEmpty { cost += labels[it.part].count }
            if used + cost > maxChars { if used >= maxChars - 150 { break }; continue }
            for j in add { picked[it.part].insert(j) }
            used += cost
        }
        var out: [String] = []
        for (pi, set) in picked.enumerated() where !set.isEmpty {
            var text = ""
            var prev = -2
            for j in set.sorted() {
                if prev != -2 && j != prev + 1 { text += " … " } else if prev != -2 { text += " " }
                text += sents[pi][j]
                prev = j
            }
            out.append(labels[pi] + text)
        }
        return out
    }
}
