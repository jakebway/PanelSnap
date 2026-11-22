import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Answers questions about the comic with the language model built into the phone (Apple Intelligence). Nothing is sent
/// anywhere and no key is needed. The model is only given what Companion has gathered, and told to stick to it.
@MainActor
final class CompanionAsk: ObservableObject {
    @Published var answer = ""
    @Published var busy = false
    @Published var failed = false

    static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    private static let instructions = """
    You help someone who is reading a comic book. You are given information about the comic, the issue and its characters. \
    Answer using only that information and plain common sense. If the information does not say, answer that you don't \
    know from what is available. Never invent plot details, powers or relationships. Do not reveal anything beyond what \
    the information contains. Keep answers short: at most four sentences, friendly and clear.
    """

    func ask(_ question: String, context: String) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !q.isEmpty else { return }
        busy = true
        failed = false
        answer = ""
        defer { busy = false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let response = try await session.respond(to: "COMIC INFORMATION:\n\(context)\n\nQUESTION: \(q)")
                answer = response.content
            } catch {
                failed = true
            }
        }
        #endif
    }
}

extension CompanionData {
    /// Everything the model may use, as plain text. The plot of the issue is left out unless spoilers are allowed.
    func llmContext(spoilers: Bool, mark: IssueMark?, page: Int, pageCount: Int) -> String {
        var out: [String] = []
        var title = series ?? "an unknown comic"
        if let i = issue, !i.isEmpty { title += " #\(i)" }
        var line = "Reading: \(title)"
        if let p = publisher { line += " (\(p)\(year.map { ", \($0)" } ?? ""))" }
        out.append(line)
        if let m = mark {
            out.append("This file is a collected edition. The reader is on page \(page + 1) of \(pageCount), which is inside issue #\(m.issue).")
        }
        if let s = seriesSummary?.text { out.append("About the series: " + TextClean.shorten(s, limit: 500)) }
        if let s = issueSummary?.text { out.append("About this issue: " + TextClean.shorten(s, limit: 600)) }
        if let s = issueSynopsis?.text {
            if spoilers { out.append("Plot of this issue (spoilers): " + TextClean.shorten(s, limit: 1300)) }
            else { out.append("A plot summary exists but is hidden to avoid spoilers; do not guess the plot.") }
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
        return String(out.joined(separator: "\n").prefix(6500))
    }
}
