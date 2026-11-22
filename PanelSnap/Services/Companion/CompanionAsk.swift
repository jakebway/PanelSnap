import Foundation
import CoreGraphics
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
    var engine: String? = nil      // "cloud" = Apple's Private Cloud Compute model, "page" = on-device and saw the page
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

    /// How much text the model can take, in characters, after room for its instructions, tools and answer.
    /// The phone says how big the model's window is (4K tokens on iOS 26, 8K on newer phones with iOS 27).
    static func contextBudget() async -> Int {
        var tokens = 4096
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            tokens = (try? await SystemLanguageModel.default.contextSize) ?? 4096
        }
        #endif
        return max(3000, Int(Double(tokens - 1400) * 2.9))
    }

    private static let instructions = """
    You are a careful comics expert sitting beside someone while they read. You only state facts that appear in the \
    provided information: the fact sheets, the cast and plot notes, the words printed on the pages, or what the \
    searchKnowledge and lookUpCharacter tools return. Never fill gaps from memory and never guess. \
    For any question about who someone is, who lives somewhere, what a place or group is, or how people are connected, \
    FIRST call searchKnowledge with the key words (for example "Moon Inhumans"), then answer from what it returns together \
    with the page words (names in balloons and captions show who is present and who is talking to whom). \
    Answer in your first sentence, naming names, then add only what helps. Never repeat yourself, no filler, no apologies. \
    If the information still does not say, reply exactly: "I couldn't find that in my sources," and add the closest fact you do have. \
    People who live somewhere are the ones the sources say belong there; people only shown visiting are visitors, not residents. \
    For a "who lives at / who is in" question, name every resident or member the sources or the page words mention (for example people \
    greeted as family, rulers, doctors or guards there), group them, and then say who is only visiting. Do not answer with just the \
    people in the scene. \
    Visitors are only the people the pages show arriving from somewhere else. A spouse, parent or child of a resident who is shown \
    at home with the family there lives there too. When the reader pushes back ("I thought X lived there"), check the sources and \
    the page words again and change your answer if they show the reader is right; do not just repeat yourself. \
    Write each person once, with no repeated names and no brackets inside brackets; group people on short lines, for example \
    "Royal family: …" then "Others: …" then "Visiting: …". \
        A hero's codename and real name are one person (Scarlet Witch is Wanda Maximoff): mention them once. \
    Do not reveal events the reader has not reached unless spoilers are allowed. At most four sentences unless asked for more. \
    The page words and any attached picture only show who is in the scene and what they say; they do not tell you where \
    anyone lives or what a place or group is. For that, use only the live search results and fact sheets.
    """

    /// The fact sheets for what is on screen. Changing them restarts the warmed-up session so it carries the new tools.
    var notes: [KnowledgeNote] = [] {
        didSet {
            #if canImport(FoundationModels)
            warm = nil
            #endif
        }
    }

    #if canImport(FoundationModels)
    private var warm: AnyObject?          // a session made and warmed up ahead of time, so the first words come sooner
    #endif
    private var warmPublisher: String?

    /// Loads the model into memory before a question is asked (Apple recommends this when there is a second or more).
    func prewarm(publisher: String?) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard Self.isSupported, warm == nil || warmPublisher != publisher else { return }
            let session = Self.makeSession(publisher: publisher, permissive: false, notes: notes)
            session.prewarm()
            warm = session
            warmPublisher = publisher
        }
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func makeSession(publisher: String?, permissive: Bool, notes: [KnowledgeNote]) -> LanguageModelSession {
        let model = permissive ? SystemLanguageModel(guardrails: .permissiveContentTransformations) : SystemLanguageModel.default
        let tools: [any Tool] = [KnowledgeSearchTool(publisher: publisher, notes: notes), CharacterLookupTool(publisher: publisher)]
        return LanguageModelSession(model: model, tools: tools, instructions: Instructions(Self.instructions))
    }
    #endif

    /// Asks one question. The question shows straight away; `makeContext` gathers what the model should read
    /// (given the space available) and the answer appears as it is written.
    private var cloudFailed = false        // Private Cloud Compute refused once this session: don't keep trying

    func ask(_ question: String, issueKey: String, publisher: String?, context makeContext: (Int) async -> String,
             pageImage: () async -> CGImage?) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !q.isEmpty else { return }
        busy = true
        defer { busy = false; save(); prewarm(publisher: publisher) }
        let earlier = history.filter { $0.issueKey == issueKey && !$0.failed }.suffix(2)
            .map { "Reader: \($0.question)\nYou: \(TextClean.shorten($0.answer, limit: 400))" }.joined(separator: "\n")
        history.append(AskExchange(question: q, answer: "", issueKey: issueKey))
        let index = history.count - 1
        func set(_ text: String, failed: Bool = false, engine: String? = nil) {
            guard index < history.count else { return }
            history[index].answer = text
            history[index].failed = failed
            if engine != nil { history[index].engine = engine }
        }
        func makePrompt(_ ctx: String) -> String {
            let p = ctx + "\n\n" + (earlier.isEmpty ? "" : "EARLIER IN THIS CONVERSATION:\n\(earlier)\n\n") + "QUESTION: \(q)"
            Self.writeDebug(question: q, prompt: p, notes: notes)
            return p
        }
        #if canImport(FoundationModels)
        // 1. Apple's larger server model (Private Cloud Compute): 32K of reading and real reasoning, still private.
        if #available(iOS 27.0, *), !cloudFailed, UserDefaults.standard.bool(forKey: "companion.tryCloudModel"), ModernAsk.cloudAvailable {
            let ctx = await makeContext(60_000)
            do {
                let text = try await ModernAsk.cloud(prompt: makePrompt(ctx), instructions: Self.instructions,
                                                     tools: [KnowledgeSearchTool(publisher: publisher, notes: notes), CharacterLookupTool(publisher: publisher)])
                set(Self.tidy(text), engine: "cloud")
                return
            } catch {
                cloudFailed = true            // offline, out of today's allowance or not allowed: use the phone's model
                set("")
            }
        }
        // 2. The model on the phone, looking at the page on screen as well (iOS 27).
        var page: CGImage? = nil
        // The picture only helps when the question is about what is on screen. For "who lives where" style questions it
        // pulled the answer away from the sources, so those are answered from the sources alone.
        if #available(iOS 27.0, *), Self.needsPage(q) { page = await pageImage() }
        if #available(iOS 26.0, *) {
            var budget = await Self.contextBudget() - earlier.count - q.count - (page != nil ? 2500 : 0)
            var permissive = false
            for attempt in 0..<3 {
                let ctx = await makeContext(budget)
                let prompt = makePrompt(ctx)
                let session: LanguageModelSession
                if attempt == 0, let w = warm as? LanguageModelSession { session = w; warm = nil }
                else { session = Self.makeSession(publisher: publisher, permissive: permissive, notes: notes) }
                do {
                    let options = GenerationOptions(temperature: 0.1, maximumResponseTokens: 320)
                    var latest = ""
                    if #available(iOS 27.0, *), let page = page, attempt == 0 {
                        latest = try await ModernAsk.withPage(session: session, prompt: prompt, page: page, options: options) { set($0) }
                        set(Self.tidy(latest), engine: "page")
                        return
                    }
                    for try await snap in session.streamResponse(to: prompt, options: options) {
                        latest = snap.content
                        set(latest)
                    }
                    set(Self.tidy(latest))
                    return
                } catch let e as LanguageModelSession.GenerationError {
                    switch e {
                    case .exceededContextWindowSize: budget = budget * 6 / 10          // too much to read: try with less
                    case .guardrailViolation: permissive = true                       // comic fights can trip the filter
                    default: if attempt >= 1 { set("", failed: true); return }
                    }
                    set("")
                } catch {
                    if attempt >= 1 { set("", failed: true); return }
                    set("")
                }
            }
            set("", failed: true)
            return
        }
        #endif
        set("", failed: true)
    }

    static func needsPage(_ q: String) -> Bool {
        let l = q.lowercased()
        return ["this page", "this panel", "this scene", "picture", "image", "panel", "what is happening", "what's happening", "what are they doing",
                "what is she doing", "what is he doing", "going on", "shown", "pictured", "looking at", "on screen", "this issue"].contains { l.contains($0) }
    }

    /// Saves what the model was given for the latest question to Files › PanelSnap › Companion Debug, so a wrong answer
    /// can be traced to missing or wrong sources.
    static func writeDebug(question: String, prompt: String, notes: [KnowledgeNote]) {
        let folder = Paths.documents.appendingPathComponent("Companion Debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var out = "QUESTION: \(question)\n\nFACT SHEETS GATHERED (\(notes.count)): " + notes.map { "\($0.title) [\($0.source), \($0.text.count) chars]" }.joined(separator: "; ")
        out += "\n\nLOOKUP LOG (errors only):\n" + (Diagnostics.text.isEmpty ? "(none)" : Diagnostics.text)
        out += "\n\n===== EXACT PROMPT SENT TO THE MODEL (\(prompt.count) characters) =====\n" + prompt
        try? out.write(to: folder.appendingPathComponent("last-question.txt"), atomically: true, encoding: .utf8)
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
            for c in characters.prefix(limit > 7000 ? 18 : 10) {
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


#if canImport(FoundationModels)
/// Lets the model look up a character it doesn't know, from the built-in guide and then Wikipedia.
@available(iOS 26.0, *)
struct CharacterLookupTool: Tool {
    let name = "lookUpCharacter"
    let description = "Looks up who a comic book character is: real name, first appearance, family, team and a short bio."
    let publisher: String?

    @Generable
    struct Arguments {
        @Guide(description: "The character's name, for example Black Bolt or Quicksilver")
        var name: String
    }

    func call(arguments: Arguments) async throws -> String {
        let name = arguments.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if let e = CharacterGlossary.shared.find(name: name) {
            var l = e.n
            if let r = e.r, !r.isEmpty { l += ", real name " + r }
            if let fa = e.fa, !fa.isEmpty { l += ", first appeared in " + fa }
            if let rel = e.rel, !rel.isEmpty { l += ". Family: " + rel }
            if let occ = e.occ, !occ.isEmpty { l += ". Occupation: " + occ }
            parts.append(l + ".")
        }
        if let card = await WikipediaProvider.character(name: name, publisher: publisher), let b = card.blurb {
            parts.append(TextClean.shorten(b, limit: 700))
        }
        return parts.isEmpty ? "No information found about \(name)." : parts.joined(separator: " ")
    }
}
#endif


#if canImport(FoundationModels)
/// The iOS 27 additions: Apple's server model and pictures in prompts.
@available(iOS 27.0, *)
@MainActor
enum ModernAsk {
    static var cloudAvailable: Bool {
        if case .available = PrivateCloudComputeLanguageModel().availability { return true }
        return false
    }

    static func cloud(prompt: String, instructions: String, tools: [any Tool]) async throws -> String {
        let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: Instructions(instructions))
        let response = try await session.respond(to: prompt, contextOptions: ContextOptions(reasoningLevel: .light))
        return response.content
    }

    static func withPage(session: LanguageModelSession, prompt: String, page: CGImage, options: GenerationOptions,
                         update: (String) -> Void) async throws -> String {
        var latest = ""
        let stream = session.streamResponse(options: options) {
            prompt
            Attachment(page).label("page on screen")
        }
        for try await snap in stream {
            latest = snap.content
            update(latest)
        }
        return latest
    }
}
#endif


#if canImport(FoundationModels)
/// Lets the model search before it answers: the facts gathered for this comic first, then the comics wiki and Wikipedia, live.
@available(iOS 26.0, *)
struct KnowledgeSearchTool: Tool {
    let name = "searchKnowledge"
    let description = "Searches the fact sheets for this comic, the comics wiki and Wikipedia. Use it for any question about who someone is, who lives somewhere, or what a place, team or group is."
    let publisher: String?
    let notes: [KnowledgeNote]

    @Generable
    struct Arguments {
        @Guide(description: "Key words to look up, for example: Inhumans Moon, or Black Bolt")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        return await Knowledge.search(arguments.query, publisher: publisher, notes: notes)
    }
}
#endif
