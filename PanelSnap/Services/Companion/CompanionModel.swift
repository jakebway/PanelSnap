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
            phase = .done
            updateTip()
            return
        }
        guard settings.onlineLookup else {
            phase = .done
            tip = "Online lookup is off. Turn it on in Settings to see character guides and series info."
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
        started = true
        if settings.onlineLookup {
            phase = .loading
            Task { await runLookups() }
        }
    }

    private func updateTip() {
        if settings.comicVineKey.isEmpty {
            tip = "Tip: add a free Comic Vine key in Settings for much richer character and story info."
        } else {
            tip = nil
        }
    }

    private func runLookups() async {
        if running { return }
        running = true
        defer { running = false }

        let id = identity
        let key = settings.comicVineKey
        var d = data
        let seriesName = id.series ?? ""

        if seriesName.isEmpty {
            phase = .done
            tip = "I couldn't work out this comic's name from its file. Tap “Not the right comic?” to type it in."
            return
        }

        // 1. Comic Vine (best source, needs a free key).
        if !key.isEmpty {
            if let cv = try? await ComicVineProvider.lookup(series: seriesName, issue: id.issue, year: id.year, key: key) {
                d.fill(from: cv)
                data = d
            }
        }

        // 2. Fan wiki issue synopsis for Marvel / DC.
        if d.issueSynopsis == nil, let number = id.issue ?? d.issue {
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

        // 4. AniList for manga (or as a last resort with a strict name match).
        if id.isManga || d.seriesSummary == nil {
            if let al = await AniListProvider.lookup(series: seriesName, strict: !id.isManga) {
                d.fill(from: al)
                data = d
            }
        }

        d.fetchedAt = Date()
        data = d
        phase = .done
        updateTip()
        CompanionCache.write(entry.id, d)

        // 5. Character blurbs (quietly, in the background).
        await enrichCharacters()
        var finalData = data
        finalData.fetchedAt = Date()
        CompanionCache.write(entry.id, finalData)
    }

    private func enrichCharacters() async {
        let publisher = data.publisher
        let names = data.characters.prefix(10).filter { $0.blurb == nil }.map { $0.name }
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
