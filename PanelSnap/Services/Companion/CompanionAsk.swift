import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One question and its answer, kept per comic so they are still there next time.
struct AskExchange: Codable, Identifiable, Hashable {
    var id = UUID()
    var question: String
    var answer: String
    var issueKey: String           // which issue of a collection it was asked in ("" = the whole book)
    var failed = false
    var date = Date()
}

/// Answers questions about the comic with the language model built into the phone (Apple Intelligence). Nothing is sent
/// anywhere and no key is needed. The model is given what Companion has gathered plus the words on the pages read so far.
@MainActor
final class CompanionAsk: ObservableObject {
    @Published private(set) var history: [AskExchange] = []
    @Published private(set) var busy = false
    private let file: URL

    init(comicID: UUID) {
        file = Paths.companionCache.appendingPathComponent(comicID.uuidString + "-ask-v1.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([AskExchange].self, from: data) {
            history = saved
        }
    }

    static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    private static let instructions = """
    You are a sharp, well-read comics expert sitting beside someone while they read. \
    Answer the question directly in your first sentence, naming names. Then add only what helps: who those characters are, \
    how they relate to each other, and why it matters here. Use the words printed on the pages (names in speech balloons \
    and captions show who is present and who is talking to whom), the cast list and the plot notes. You may add well-known \
    facts about famous comic characters and places when they fit the information, for example that the Inhumans live on the Moon. \
    Never repeat yourself, never restate the question, no filler and no apologies. Only if the information really does not \
    contain the answer, say so in one short sentence and give the best clue you have. Never reveal events the reader has not \
    reached unless the information marks them as allowed spoilers. At most four sentences unless the reader asks for more.
    """

    func ask(_ question: String, issueKey: String, context makeContext: () async -> String) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !q.isEmpty else { return }
        busy = true
        defer { busy = false; save() }
        var item = AskExchange(question: q, answer: "", issueKey: issueKey)
        // Earlier questions in this issue, so follow-ups like "and who is she?" make sense.
        let earlier = history.filter { $0.issueKey == issueKey && !$0.failed }.suffix(2)
            .map { "Reader: \($0.question)\nYou: \($0.answer)" }.joined(separator: "\n")
        history.append(item)
        let index = history.count - 1
        let context = await makeContext()
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            var ctx = context
            for attempt in 0..<2 {
                let prompt = "COMIC INFORMATION:\n\(ctx)\n\n" + (earlier.isEmpty ? "" : "EARLIER IN THIS CONVERSATION:\n\(earlier)\n\n") + "QUESTION: \(q)"
                do {
                    let session = LanguageModelSession(instructions: Self.instructions)
                    let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 260)
                    let response = try await session.respond(to: prompt, options: options)
                    item.answer = Self.tidy(response.content)
                    break
                } catch {
                    if attempt == 0 { ctx = String(ctx.prefix(ctx.count / 2)); continue }     // too long for the model: try with less
                    item.failed = true
                }
            }
        } else { item.failed = true }
        #else
        item.failed = true
        #endif
        if index < history.count { history[index] = item }
    }

    func clear(issueKey: String) {
        history.removeAll { $0.issueKey == issueKey }
        save()
    }

    private func save() {
        let keep = Array(history.suffix(60))
        if let data = try? JSONEncoder().encode(keep) { try? data.write(to: file, options: .atomic) }
    }

    /// Drops sentences the model said twice, which is how "talking in circles" usually shows up.
    static func tidy(_ text: String) -> String {
        var seen = Set<String>()
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
            let key = s.lowercased().filter { $0.isLetter }
            if key.count > 12, !seen.insert(key).inserted { return }
            out.append(s)
        }
        return out.joined(separator: " ")
    }
}

extension CompanionData {
    /// Everything the model may use, as plain text. The plot of the issue is left out unless spoilers are allowed.
    func llmContext(spoilers: Bool, mark: IssueMark?, page: Int, pageCount: Int, progress: Double? = nil, limit: Int = 6500) -> String {
        var out: [String] = []
        var title = series ?? "an unknown comic"
        if let i = issue, !i.isEmpty { title += " #\(i)" }
        var line = "Reading: \(title)"
        if let p = publisher { line += " (\(p)\(year.map { ", \($0)" } ?? ""))" }
        out.append(line)
        if let m = mark {
            out.append("This file is a collected edition. The reader is on page \(page + 1) of \(pageCount), inside \(m.series ?? "issue") #\(m.issue)\(m.year.map { " (\($0) series)" } ?? "").")
        }
        if let s = seriesSummary?.text { out.append("About the series: " + TextClean.shorten(s, limit: 500)) }
        if let s = issueSummary?.text { out.append("About this issue: " + TextClean.shorten(s, limit: 600)) }
        if let s = issueSynopsis?.text {
            if spoilers { out.append("Plot of this issue (spoilers): " + TextClean.shorten(s, limit: 1300)) }
            else if let f = progress, f > 0.03 {
                out.append("What happens in this issue up to roughly where the reader is (do not go beyond it): " + Self.firstPart(s, fraction: min(1, f + 0.1), limit: 1300))
            } else { out.append("The rest of the plot is hidden to avoid spoilers; do not guess what happens next.") }
        }
        if !characters.isEmpty {
            out.append("Characters in this issue:")
            for c in characters.prefix(10) {
                var l = "- " + c.name
                if let r = c.role, !r.isEmpty { l += " (\(r))" }
                if let b = c.blurb, !b.isEmpty { l += ": " + TextClean.shorten(b, limit: 260) }
                let facts = (c.facts ?? []).prefix(4).map { "\($0.label): \($0.value)" }.joined(separator: "; ")
                if !facts.isEmpty { l += " [" + facts + "]" }
                out.append(l)
            }
        }
        if !teams.isEmpty { out.append("Teams: " + teams.prefix(8).joined(separator: ", ")) }
        if !locations.isEmpty { out.append("Places: " + locations.prefix(8).joined(separator: ", ")) }
        if !arcs.isEmpty { out.append("Story arc: " + arcs.joined(separator: ", ")) }
        if !creators.isEmpty { out.append("Creators: " + creators.prefix(8).map { "\($0.role) \($0.name)" }.joined(separator: ", ")) }
        return String(out.joined(separator: "\n").prefix(limit))
    }

    /// The opening part of a synopsis, cut at a sentence end.
    static func firstPart(_ text: String, fraction: Double, limit: Int) -> String {
        let clean = TextClean.shorten(text, limit: 4000)
        let want = min(limit, max(120, Int(Double(clean.count) * fraction)))
        if clean.count <= want { return clean }
        let head = String(clean.prefix(want))
        if let r = head.range(of: ". ", options: .backwards), head.distance(from: head.startIndex, to: r.lowerBound) > 60 {
            return String(head[..<r.upperBound])
        }
        return head + "…"
    }
}
