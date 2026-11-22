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

    // Collected editions (omnibus, trade, complete collection): which issue the reader is in, found from the page text.
    @Published private(set) var issueMarks: [IssueMark] = []
    @Published private(set) var activeMark: IssueMark?
    @Published private(set) var scanning = false
    @Published private(set) var scanFraction: Double = 0
    @Published private(set) var scanFinished = false
    @Published private(set) var plannedCount = 0                 // issues the collection's description says it contains
    private(set) var currentPage = 0
    private(set) var pageCount = 0
    private let baseIdentity: ComicIdentity
    private var wholeData: CompanionData?
    private var variant = ""                  // which cache file the data on screen belongs to ("" = the whole file)
    private var generation = 0                // bumped whenever a new lookup starts, so an older one stops writing
    private var pageTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var scanState = ScanState()
    private var plan: [PlannedIssue] = []
    private var scanSource: ComicSource?
    private var planModelTried = Set<String>()

    init(entry: ComicEntry, identity: ComicIdentity, settings: AppSettings, coverURL: URL) {
        self.entry = entry
        self.identity = identity
        self.baseIdentity = identity
        self.settings = settings
        self.coverURL = coverURL
        let base = CompanionModel.baseline(identity)
        self.data = base
        self.fixSeries = identity.series ?? ""
        self.fixIssue = identity.issue ?? ""
        self.ask = CompanionAsk(comicID: entry.id)
    }

    /// The question box. Lives here (not in the panel) so questions and answers survive closing the panel.
    let ask: CompanionAsk

    /// Which issue questions belong to.
    var issueKey: String { return activeMark.map { "\($0.series ?? "")#\($0.issue)" } ?? "" }

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

    // MARK: Following the reader through a collected edition

    /// Called once when the comic opens. Reads the description for the list of issues, then reads page text (starting at
    /// the page you are on) to find where each of them starts.
    func attach(source: ComicSource, page: Int) {
        currentPage = page
        pageCount = source.pageCount
        scanSource = source
        scanState = IssueScanner.readState(entry.id) ?? ScanState()
        load()                                   // fetch (or read the saved) details now, not when the panel opens
        refreshPlan()
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in      // get ready for questions straight away, quietly
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await self?.readRecentPages()
        }
        if scanState.finished {
            scanFinished = true
            applyMarks()
            return
        }
        applyMarks()
        startScanIfWorthwhile()
    }

    private func startScanIfWorthwhile() {
        guard scanTask == nil, !scanState.finished, let source = scanSource else { return }
        guard plan.count >= 2 || IssueScanner.looksLikeCollection(baseIdentity, pageCount: source.pageCount) else { return }
        scanning = true
        let id = entry.id
        let start = currentPage
        let initial = scanState
        var seen = Set<String>()
        let titles = plan.map { $0.series }.filter { seen.insert($0).inserted }
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let final = await IssueScanner.scan(source: source, id: id, from: start, state: initial, titles: titles) { partial in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.scanState = partial
                    self.scanFraction = Double(partial.done.count) / Double(max(1, source.pageCount))
                    self.applyMarks()
                }
            }
            await MainActor.run {
                guard let self = self else { return }
                self.scanTask = nil
                self.scanState = final
                self.scanning = false
                self.scanFinished = final.finished
                self.applyMarks()
            }
        }
    }

    func stopScanning() {
        prepareTask?.cancel()
        scanTask?.cancel()
        scanTask = nil
        scanning = false
        pageTask?.cancel()
    }

    // MARK: Fact sheets for Ask

    @Published private(set) var notes: [KnowledgeNote] = []

    /// Reads the saved fact sheets for what is on screen, or fetches them all at once (every character, place and team
    /// in parallel) and saves them, so the next time this comic opens they are already there.
    private func loadKnowledge(gen: Int) async {
        let key = variant
        if let saved = Knowledge.read(entry.id, variant: key) {
            guard gen == generation else { return }
            notes = saved
            ask.notes = saved
            return
        }
        let snapshot = data
        let built = await Knowledge.gather(data: snapshot, publisher: snapshot.publisher ?? identity.publisher,
                                           series: snapshot.series ?? identity.series ?? "", collection: baseIdentity.summary)
        guard gen == generation, !built.isEmpty else { return }
        notes = built
        ask.notes = built
        Knowledge.write(entry.id, variant: key, built)
    }

    // MARK: What the reader has read (for Ask)

    @Published private(set) var readingPages = false
    private var pageText: [Int: String] = [:]
    private var pageTextLoaded = false
    private var prepareTask: Task<Void, Never>?

    private var pageTextFile: URL { return Paths.companionCache.appendingPathComponent(entry.id.uuidString + "-text-v1.json") }

    /// Where the issue the reader is in begins (or a sensible stretch back, if that isn't known).
    /// Never past the current page: right after jumping back into an earlier issue, the issue Companion follows can
    /// still be the later one for a moment.
    private var readStart: Int {
        let cp = max(0, currentPage)
        if let m = activeMark, m.page <= cp { return max(0, m.page, cp - 40) }
        return max(0, cp - 20)
    }

    /// Reads new pages shortly after the reader settles on one, so a question never has to wait for them.
    private func schedulePrepare() {
        guard !readingPages else { return }
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if Task.isCancelled { return }
            await self?.readRecentPages()
        }
    }

    /// Reads the lettering of this issue's pages up to two pages past the current one (newest first), a few pages at a
    /// time, saving after each batch so nothing is lost and a question can use whatever is ready.
    func readRecentPages() async {
        guard let source = scanSource, currentPage >= 0, pageCount > 0 else { return }
        if !pageTextLoaded {
            pageTextLoaded = true
            if let data = try? Data(contentsOf: pageTextFile), let saved = try? JSONDecoder().decode([String: String].self, from: data) {
                for (k, v) in saved { if let i = Int(k) { pageText[i] = v } }
            }
        }
        guard !readingPages else { return }
        readingPages = true
        defer { readingPages = false }
        while !Task.isCancelled {
            let cp = min(max(0, currentPage), pageCount - 1)
            let end = min(pageCount - 1, cp + 2)
            let lo = min(readStart, cp)
            let ahead = end > cp ? Array((cp + 1)...end) : []
            let order = Array((lo...cp).reversed()) + ahead
            let want = Array(order.filter { pageText[$0] == nil }.prefix(3))
            if want.isEmpty { break }
            let found: [Int: String] = await Task.detached(priority: .utility) {
                var out: [Int: String] = [:]
                for p in want {
                    autoreleasepool {
                        if let img = source.pageImage(at: p, maxPixel: 1500) { out[p] = IssueScanner.readDialogue(img) }
                    }
                }
                return out
            }.value
            for p in want { pageText[p] = found[p] ?? "" }
            let saved = Dictionary(uniqueKeysWithValues: pageText.map { (String($0.key), $0.value) })
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: pageTextFile, options: .atomic) }
        }
    }

    /// Everything the on-device model gets: the issue's details, the plot up to where you are (or all of it with
    /// spoilers on) and the words on the pages you have read, choosing the pages that matter most for the question.
    func askContext(spoilers: Bool, question: String, budget: Int) async -> String {
        if !readingPages { await readRecentPages() }               // usually already done in the background
        else {
            for _ in 0..<15 where readingPages && pageText[currentPage] == nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        var progress: Double?
        if let m = activeMark {
            let next = issueMarks.first(where: { $0.page > m.page })?.page ?? pageCount
            progress = Double(currentPage - m.page + 1) / Double(max(1, next - m.page))
        }
        // Fix misspelled names, then search the wiki ourselves (the model often skips its own search tool).
        var vocab = notes.map { $0.title } + data.locations + data.teams + data.characters.map { $0.name }
        if let s = data.series { vocab.append(s) }
        let corrected = Knowledge.canonical(question, vocabulary: vocab)
        let fixedQuestion = corrected.text
        let publisher = data.publisher ?? identity.publisher
        let allNotes = notes
        async let live = Knowledge.liveSearch(fixedQuestion, publisher: publisher, notes: allNotes)
        let infoBudget = budget * 3 / 10
        let info = data.llmContext(spoilers: spoilers, mark: activeMark, page: currentPage, pageCount: pageCount, progress: progress, limit: infoBudget)
        // Fact sheets about the people and places in this issue. The plot sheet follows the spoiler setting.
        let usable = notes.filter { spoilers || !$0.title.hasPrefix("Plot") }
        let facts = Knowledge.relevant(usable, to: fixedQuestion, budget: budget / 4)
        let found = await live
        // The sources come first: they are what answers are made from.
        var ctx = ""
        if !found.isEmpty { ctx += "SOURCES - live search for \"\(fixedQuestion)\":\n" + TextClean.shorten(found, limit: budget * 2 / 5) + "\n\n" }
        if !facts.isEmpty { ctx += "SOURCES - fact sheets from the comics wiki and Wikipedia:\n" + facts.joined(separator: "\n") + "\n\n" }
        ctx += "ABOUT THE COMIC BEING READ:\n" + info
        if !corrected.fixes.isEmpty {
            ctx += "\n\nThe reader misspelled: " + corrected.fixes.map { "\"\($0.0)\" means \"\($0.1)\"" }.joined(separator: ", ") + "."
        }
        let pages = choosePages(question: fixedQuestion, budget: min(budget - ctx.count - 300, budget / 3))
        if !pages.isEmpty {
            ctx += "\n\nWORDS ON PAGES THE READER HAS READ IN THIS ISSUE (shows who is in the scene and what they say; page \(currentPage + 1) is on screen; read by machine, so expect misspellings):\n"
                + pages.joined(separator: "\n")
        }
        return ctx
    }

    /// The page on screen, as a picture the on-device model can look at.
    func currentPageImage() async -> CGImage? {
        guard let source = scanSource, currentPage >= 0 else { return nil }
        let p = currentPage
        return await Task.detached(priority: .userInitiated) { source.pageImage(at: p, maxPixel: 1024) }.value
    }

    /// The last few pages always, then the pages that share the most words with the question, then the rest newest first.
    private func choosePages(question: String, budget: Int) -> [String] {
        guard budget > 200, currentPage >= 0 else { return [] }
        let range = Array(readStart...max(readStart, currentPage)).filter { !(pageText[$0] ?? "").isEmpty }
        if range.isEmpty { return [] }
        let stop: Set<String> = ["what", "who", "whom", "where", "when", "which", "that", "this", "with", "they", "their", "there",
                                 "have", "does", "about", "from", "were", "into", "issue", "page", "comic", "going", "happening", "wanna", "want"]
        let terms = question.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count > 3 && !stop.contains($0) }.map { String($0.prefix(5)) }
        func score(_ p: Int) -> Int {
            guard !terms.isEmpty, let t = pageText[p]?.lowercased() else { return 0 }
            return terms.reduce(0) { $0 + (t.contains($1) ? 1 : 0) }
        }
        var chosen: [Int] = []
        var used = 0
        func take(_ p: Int) {
            guard !chosen.contains(p), let t = pageText[p] else { return }
            let piece = min(t.count, 1400) + 12
            if used + piece > budget { return }
            chosen.append(p); used += piece
        }
        for p in range.suffix(3).reversed() { take(p) }
        for p in range.sorted(by: { score($0) > score($1) }) where score(p) > 0 { take(p) }
        for p in range.reversed() { take(p) }
        return chosen.sorted().map { "[page \($0 + 1)] " + String((pageText[$0] ?? "").prefix(1400)) }
    }

    // MARK: The description's list of issues

    /// Looks for "Collects X #1-4, Y #1-12 ..." in the comic's own description and in what Companion has fetched.
    func refreshPlan() {
        var texts: [String] = []
        if let t = baseIdentity.summary { texts.append(t) }
        let whole = wholeData ?? (variant.isEmpty ? data : nil)
        for block in [whole?.issueSummary, whole?.issueSynopsis, whole?.seriesSummary] {
            if let t = block?.text { texts.append(t) }
        }
        for t in texts {
            let p = IssuePlan.parse(t)
            if p.count >= 2 { setPlan(p); return }
        }
        // Nothing the plain reader understood: ask the on-device model about a text that looks like a contents list.
        for t in texts where plan.isEmpty && !planModelTried.contains(t) {
            let lower = t.lowercased()
            guard lower.contains("collect") || lower.contains("reprint") || lower.contains("issues") else { continue }
            planModelTried.insert(t)
            Task { [weak self] in
                let p = await IssuePlan.askModel(t)
                if p.count >= 2 { self?.setPlan(p) }
            }
            break
        }
    }

    private func setPlan(_ p: [PlannedIssue]) {
        if p == plan { return }
        plan = p
        plannedCount = p.count
        applyMarks()
        if scanTask != nil {                    // restart so the scan also looks for the series titles it now knows
            scanTask?.cancel()
            scanTask = nil
        }
        startScanIfWorthwhile()
    }

    private func applyMarks() {
        let marks = IssueScanner.marks(from: scanState.candidates, plan: plan, pageCount: pageCount)
        if marks != issueMarks { issueMarks = marks }
        pageChanged(currentPage)
    }

    /// Called as the reader turns pages. Switches Companion to the issue the page belongs to.
    func pageChanged(_ page: Int) {
        currentPage = page
        guard !issueMarks.isEmpty else { schedulePrepare(); return }
        let mark = issueMarks.last(where: { $0.page <= page })
        if mark == activeMark { return }
        if let m = mark, let a = activeMark, m.issue == a.issue, m.series == a.series {
            activeMark = m                      // same issue, just pinned down more exactly: nothing to look up again
            schedulePrepare()
            return
        }
        pageTask?.cancel()
        if activeMark == nil {                  // the first answer on opening: no reason to wait
            activate(mark)
            schedulePrepare()
            return
        }
        pageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)      // wait until the reader settles on a page
            if Task.isCancelled { return }
            self?.activate(mark)
            self?.schedulePrepare()
        }
    }

    private func activate(_ mark: IssueMark?) {
        if activeMark == nil && wholeData == nil { wholeData = data }
        activeMark = mark
        generation += 1
        guard let mark = mark else {                       // front matter, before the first issue
            variant = ""
            identity = baseIdentity
            if let whole = wholeData { data = whole }
            phase = .done
            return
        }
        var id = baseIdentity
        let name = (mark.series?.isEmpty == false ? mark.series : nil) ?? IssueScanner.baseSeries(baseIdentity.series ?? "")
        var pretty = name == name.uppercased() ? name.capitalized : name       // "THE AMAZING SPIDER-MAN" -> "The Amazing Spider-Man"
        if pretty.lowercased().hasPrefix("the ") { pretty = String(pretty.dropFirst(4)) }
        id.series = pretty
        id.issue = mark.issue
        id.year = mark.year
        id.title = nil
        id.summary = nil
        id.characters = []
        id.teams = []
        id.locations = []
        id.storyArc = nil
        id.volume = nil
        identity = id
        variant = "issue-\(id.series ?? "")-\(mark.issue)"
        if let cached = CompanionCache.read(entry.id, variant: variant, maxAgeDays: 21) {
            data = cached
            applyGlossary()
            phase = .done
            updateTip()
            let g = generation
            Task { [weak self] in await self?.loadKnowledge(gen: g) }
            return
        }
        var fresh = CompanionModel.baseline(id)
        fresh.series = id.series
        fresh.issue = mark.issue
        data = fresh
        applyGlossary()
        if settings.onlineLookup {
            phase = .loading
            Task { await runLookups() }
        } else {
            phase = .done
        }
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
            refreshPlan()
            let g = generation
            Task { [weak self] in await self?.loadKnowledge(gen: g) }
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
        generation += 1
        let gen = generation
        let cacheVariant = variant
        running = true
        defer { if gen == generation { running = false } }

        let id = identity
        var d = data
        let seriesName = id.series ?? ""

        if seriesName.isEmpty {
            phase = .done
            tip = "I couldn't work out this comic's name from its file. Tap “Not the right comic?” to type it in."
            return
        }

        // Every source at once: the Grand Comics Database, the Marvel / DC wiki for this issue, Wikipedia and (manga) AniList.
        let pub = d.publisher ?? id.publisher
        let issueNumber = id.issue ?? d.issue
        let year = id.year
        let volume = id.volume
        let seriesForWiki = d.series ?? seriesName
        let dataPublisher = d.publisher
        let manga = id.isManga
        let needFandom = issueNumber != nil && (d.issueSynopsis == nil || d.creators.isEmpty || d.characters.isEmpty)
        let needWiki = d.seriesSummary == nil
        var results: [(Int, CompanionData)] = []
        await withTaskGroup(of: (Int, CompanionData?).self) { group in
            group.addTask { (0, await GCDProvider.lookup(series: seriesName, issue: id.issue, year: year, publisher: pub)) }
            if needFandom, pub != nil, let number = issueNumber {
                group.addTask { (1, await FandomProvider.lookup(publisher: pub, series: seriesForWiki, volume: volume, issue: number, year: year)) }
            }
            if needWiki { group.addTask { (2, await WikipediaProvider.series(name: seriesForWiki, publisher: dataPublisher)) } }
            if manga { group.addTask { (4, await AniListProvider.lookup(series: seriesName, strict: false)) } }
            for await (i, r) in group { if let r = r { results.append((i, r)) } }
        }
        guard gen == generation else { return }
        for (_, r) in results.sorted(by: { $0.0 < $1.0 }) { d.fill(from: r) }
        data = d
        // The publisher was unknown until the Grand Comics Database answered: now the wiki can be asked.
        if needFandom, pub == nil, d.publisher != nil, let number = issueNumber,
           let wiki = await FandomProvider.lookup(publisher: d.publisher, series: seriesForWiki, volume: volume, issue: number, year: year) {
            guard gen == generation else { return }
            d.fill(from: wiki)
            data = d
        }
        if d.seriesSummary == nil, let ol = await OpenLibraryProvider.lookup(series: d.series ?? seriesName, publisher: d.publisher) {
            guard gen == generation else { return }
            d.fill(from: ol)
            data = d
        }
        if d.seriesSummary == nil, !manga, let al = await AniListProvider.lookup(series: seriesName, strict: true) {
            guard gen == generation else { return }
            d.fill(from: al)
            data = d
        }

        guard gen == generation else { return }
        // 6. Built-in guide again, now that there's more text to read names from.
        applyGlossary()
        d = data
        d.fetchedAt = Date()
        data = d
        phase = .done
        updateTip()
        CompanionCache.write(entry.id, variant: cacheVariant, d)
        if cacheVariant.isEmpty { refreshPlan() }
        Task { [weak self] in await self?.loadKnowledge(gen: gen) }

        // 7. Character blurbs (quietly, in the background).
        await enrichCharacters(gen)
        guard gen == generation else { return }
        var finalData = data
        finalData.fetchedAt = Date()
        CompanionCache.write(entry.id, variant: cacheVariant, finalData)
    }

    private func enrichCharacters(_ gen: Int) async {
        let publisher = data.publisher
        let names = data.characters.prefix(12).filter { $0.blurb == nil }.map { $0.name }
        if names.isEmpty { return }
        await withTaskGroup(of: CharacterCard?.self) { group in
            for name in names {
                group.addTask {
                    return await WikipediaProvider.character(name: name, publisher: publisher)
                }
            }
            for await card in group {
                guard let card = card, gen == generation else { continue }
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
