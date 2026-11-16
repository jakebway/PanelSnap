import Foundation
import SwiftUI

@MainActor
final class CompanionModel: ObservableObject {

    enum Phase {
        case idle
        case loading
        case done
    }

    @Published private(set) var data: CompanionData
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var tip: String?
    @Published var fixSeries: String
    @Published var fixIssue: String

    let entry: ComicEntry
    let coverURL: URL
    private var identity: ComicIdentity
    private let settings: AppSettings
    private var started = false
    private var running = false

    init(entry: ComicEntry, identity: ComicIdentity, settings: AppSettings, coverURL: URL) {
        self.entry = entry
        self.identity = identity
        self.settings = settings
        self.coverURL = coverURL
        let base = CompanionModel.baseline(identity)
        self.data = base
        self.fixSeries = identity.series ?? ""
        self.fixIssue = identity.issue ?? ""
    }

    /// What we already know from the file itself, with no internet.
    static func baseline(_ id: ComicIdentity) -> CompanionData {
        var d = CompanionData()
        d.series = id.series
        d.issue = id.issue
        d.volume = id.volume
        d.year = id.year
        d.publisher = id.publisher
        d.title = id.title
        if let s = id.summary, !s.isEmpty {
            d.issueSummary = TextBlock(text: TextClean.html(s), source: "Comic file", url: nil)
        }
        d.characters = id.characters.map { CharacterCard(name: $0, role: nil, blurb: nil, imageURL: nil, url: nil, source: nil) }
        d.teams = id.teams
        d.locations = id.locations
        d.genres = id.genres
        if let arc = id.storyArc { d.arcs = [arc] }
        func add(_ role: String, _ names: [String]) {
            for n in names { d.creators.append(Credit(role: role, name: n)) }
        }
        add("Writer", id.writers)
        add("Penciller", id.pencillers)
        add("Inker", id.inkers)
        add("Colorist", id.colorists)
        add("Letterer", id.letterers)
        add("Cover", id.coverArtists)
        add("Editor", id.editors)
        if let web = id.web, let first = web.split(separator: " ").first, first.hasPrefix("http") {
            d.links.append(LinkItem(title: "Link from the comic file", url: String(first)))
        }
        d.sources = ["Comic file"]
        return d
    }

    // MARK: Loading

    func load(force: Bool = false) {
        if started && !force { return }
        started = true

        if !force, let cached = CompanionCache.read(entry.id, maxAgeDays: 21) {
            data = cached
            applyGlossary()
            phase = .done
            updateTip()
            return
        }
        applyGlossary()
        guard settings.onlineLookup else {
            phase = .done
            tip = "Online lookup is off, so this is the built-in guide only. Turn it on in Settings for story summaries and more."
            return
        }
        if running { return }
        phase = .loading
        Task { await runLookups() }
    }

    func relookup(series: String, issue: String) {
        identity.series = series.trimmingCharacters(in: .whitespaces).isEmpty ? nil : series
        identity.issue = issue.trimmingCharacters(in: .whitespaces).isEmpty ? nil : issue
        var fresh = CompanionModel.baseline(identity)
        fresh.series = identity.series
        fresh.issue = identity.issue
        data = fresh
        applyGlossary()
        started = true
        if settings.onlineLookup {
            phase = .loading
            Task { await runLookups() }
        }
    }

    private func updateTip() {
        let d = data
        let empty = d.issueSynopsis == nil && d.seriesSummary == nil && d.issueSummary == nil && d.characters.isEmpty
        tip = (empty && phase != .loading)
            ? "I couldn't find anything about this one. Tap “Not the right comic?” to type its real name."
            : nil
    }

    /// The built-in guide: no internet, no account. Adds facts to characters we already know about
    /// and picks out famous characters named in the title or any summary text.
    private func applyGlossary() {
        let glossary = CharacterGlossary.shared
        var d = data
        for i in d.characters.indices {
            if let e = glossary.find(name: d.characters[i].name) {
                d.characters[i] = glossary.enrich(d.characters[i], with: e)
            }
        }
        let titles = [d.series, d.title, d.arcs.first].compactMap { $0 }
        let texts = [d.issueSummary?.text, d.issueSynopsis?.text, d.seriesSummary?.text].compactMap { $0 }
        let room = max(0, 12 - d.characters.count)
        if room > 0 {
            let found = glossary.matches(titles: titles, texts: texts, limit: room)
            for e in found where !d.characters.contains(where: { CompanionData.same($0.name, e.n) }) {
                d.characters.append(glossary.card(e))
            }
            if d.publisher == nil, let p = glossary.publisherGuess(found) { d.publisher = p }
        }
        if !d.characters.isEmpty && !d.sources.contains(CharacterGlossary.sourceName) {
            d.sources.append(CharacterGlossary.sourceName)
        }
        data = d
    }

    private func runLookups() async {
        if running { return }
        running = true
        defer { running = false }

        let id = identity
        var d = data
        let seriesName = id.series ?? ""

        if seriesName.isEmpty {
            phase = .done
            tip = "I couldn't work out this comic's name from its file. Tap “Not the right comic?” to type it in."
            return
        }

        // 1. Grand Comics Database: credits, cast and sometimes a synopsis.
        if let gcd = await GCDProvider.lookup(series: seriesName, issue: id.issue, year: id.year, publisher: d.publisher ?? id.publisher) {
            d.fill(from: gcd)
            data = d
        }

        // 2. Marvel / DC fan wikis: issue synopsis, creators and who appears.
        if let number = id.issue ?? d.issue, d.issueSynopsis == nil || d.creators.isEmpty || d.characters.isEmpty {
            if let wiki = await FandomProvider.lookup(publisher: d.publisher ?? id.publisher, series: d.series ?? seriesName, volume: id.volume, issue: number) {
                d.fill(from: wiki)
                data = d
            }
        }

        // 3. Wikipedia series background.
        if d.seriesSummary == nil {
            if let wp = await WikipediaProvider.series(name: d.series ?? seriesName, publisher: d.publisher) {
                d.fill(from: wp)
                data = d
            }
        }

        // 4. Open Library, for graphic novels and collected editions.
        if d.seriesSummary == nil {
            if let ol = await OpenLibraryProvider.lookup(series: d.series ?? seriesName, publisher: d.publisher) {
                d.fill(from: ol)
                data = d
            }
        }

        // 5. AniList for manga (or as a last resort with a strict name match).
        if id.isManga || d.seriesSummary == nil {
            if let al = await AniListProvider.lookup(series: seriesName, strict: !id.isManga) {
                d.fill(from: al)
                data = d
            }
        }

        // 6. Built-in guide again, now that there's more text to read names from.
        applyGlossary()
        d = data
        d.fetchedAt = Date()
        data = d
        phase = .done
        updateTip()
        CompanionCache.write(entry.id, d)

        // 7. Character blurbs (quietly, in the background).
        await enrichCharacters()
        var finalData = data
        finalData.fetchedAt = Date()
        CompanionCache.write(entry.id, finalData)
    }

    private func enrichCharacters() async {
        let publisher = data.publisher
        let names = data.characters.prefix(8).filter { $0.blurb == nil }.map { $0.name }
        if names.isEmpty { return }
        await withTaskGroup(of: CharacterCard?.self) { group in
            for name in names {
                group.addTask {
                    return await WikipediaProvider.character(name: name, publisher: publisher)
                }
            }
            for await card in group {
                guard let card = card else { continue }
                if let i = data.characters.firstIndex(where: { CompanionData.same($0.name, card.name) }) {
                    data.characters[i].blurb = card.blurb
                    if data.characters[i].imageURL == nil { data.characters[i].imageURL = card.imageURL }
                    if data.characters[i].url == nil { data.characters[i].url = card.url }
                    data.characters[i].source = card.source
                }
            }
        }
    }

    /// Called when someone opens a character that has no description yet.
    func loadCharacter(_ name: String) async {
        if let i = data.characters.firstIndex(where: { $0.name == name }), data.characters[i].facts == nil,
           let e = CharacterGlossary.shared.find(name: name) {
            data.characters[i] = CharacterGlossary.shared.enrich(data.characters[i], with: e)
        }
        guard settings.onlineLookup else { return }
        guard let i = data.characters.firstIndex(where: { $0.name == name }), data.characters[i].blurb == nil else { return }
        if let card = await WikipediaProvider.character(name: name, publisher: data.publisher) {
            if let j = data.characters.firstIndex(where: { $0.name == name }) {
                data.characters[j].blurb = card.blurb
                if data.characters[j].imageURL == nil { data.characters[j].imageURL = card.imageURL }
                if data.characters[j].url == nil { data.characters[j].url = card.url }
                data.characters[j].source = card.source
            }
        }
    }
}
