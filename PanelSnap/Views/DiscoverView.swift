import SwiftUI

/// Discover: what to read next. For You (suggestions from your library) and Shop (every release week: what is out now and
/// what is coming). Search covers every comic, old and new. Pick any comic for the full story and a way to find it.
enum DiscoverTab: String, CaseIterable, Identifiable {
    case forYou, shop
    var id: String { return rawValue }
    var label: String {
        switch self {
        case .forYou: return "For You"
        case .shop: return "Shop"
        }
    }
}

struct DiscoverView: View {
    var onFind: (DiscoverComic) -> Void
    var onOpen: (URL) -> Void

    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = DiscoverModel.shared
    @State private var topInset: CGFloat = 0
    @State private var landscape = false
    @State private var tab: DiscoverTab = .forYou
    @State private var shopPick: ReleaseWeek?
    @State private var search = ""
    @State private var publisher: String?
    @State private var sort: DiscoverSort = .popular
    @State private var selected: DiscoverComic?

    private var searching: Bool { return search.trimmingCharacters(in: .whitespaces).count >= 2 }
    /// Every release week in time order: the last two that are out, then the ones still to come.
    private var shopWeeks: [ReleaseWeek] { return Array(ReleaseWeek.recent.reversed()) + ReleaseWeek.upcoming }
    private var shopWeek: ReleaseWeek {
        if let p = shopPick, shopWeeks.contains(p) { return p }
        return ReleaseWeek.recent.first ?? shopWeeks.first ?? .current
    }
    private var weekList: [DiscoverComic] { return model.weeks[shopWeek] ?? [] }
    private let grid = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14, alignment: .top)]

    private var publishers: [String] {
        let counts = Dictionary(grouping: weekList.filter { !$0.publisher.isEmpty }, by: { $0.publisher }).mapValues { $0.count }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(12).map { $0.key }
    }

    private var visibleWeek: [DiscoverComic] {
        var list = weekList
        if let p = publisher { list = list.filter { $0.publisher == p } }
        switch sort {
        case .popular: list.sort { $0.pulls != $1.pulls ? $0.pulls > $1.pulls : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .title: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return list
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                searchField
                if !searching {
                    Picker("Section", selection: $tab) {
                        ForEach(DiscoverTab.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                }
                content
            }
        }
        .readSafeTop($topInset)
        .readLandscape($landscape)
        .onAppear { model.refreshClock() }
        .task(id: tab) {
            switch tab {
            case .forYou: await model.prefetch(libraryTitles: TitleTools.byRecency(library.comics))
            case .shop: await model.load(shopWeek)
            }
        }
        .task(id: shopWeek) {
            publisher = nil
            if tab == .shop { await model.load(shopWeek) }
        }
        .task(id: search) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            await model.search(search)
        }
        .sheet(item: $selected) { comic in
            DetailSheet(comic: comic,
                        onFind: { selected = nil; onFind(comic) },
                        onOpen: { url in selected = nil; onOpen(url) })
                .presentationDetents([.large])
        }
    }

    private var header: some View {
        ZStack {
            ComicTitle(text: "Discover")
            HStack {
                Button("Done") { dismiss() }.buttonStyle(YellowButtonStyle(compact: true))
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, topInset > 20 ? (landscape ? 22 : 8) : 30)
        .padding(.bottom, 12)
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
            TextField("Search every comic, old and new", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary) }
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if searching {
            if model.searching && model.searchResults.isEmpty {
                Spacer(); ProgressView().tint(Theme.accent); Spacer()
            } else if model.searchResults.isEmpty {
                Spacer(); Text("No comics found").foregroundStyle(Theme.secondary); Spacer()
            } else {
                gridScroll(model.searchResults)
            }
        } else {
            switch tab {
            case .forYou: forYouContent
            case .shop: shopContent
            }
        }
    }

    // MARK: Shop

    private var shopContent: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shopWeeks) { w in weekChip(w) }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 10)
            HStack(spacing: 14) {
                Text((shopWeek.isOut ? "Out " : "Coming ") + DiscoverView.dayText(DiscoverModel.releaseDate(shopWeek)))
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                if !publishers.isEmpty {
                    Menu {
                        Button("All Publishers") { publisher = nil }
                        ForEach(publishers, id: \.self) { p in Button(p) { publisher = p } }
                    } label: {
                        Label(publisher ?? "All", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent).lineLimit(1)
                    }
                }
                Menu {
                    Picker("Sort", selection: $sort) { ForEach(DiscoverSort.allCases) { Text($0.label).tag($0) } }
                } label: {
                    Image(systemName: "arrow.up.arrow.down").font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .accessibilityLabel("Sort")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            if model.loadingWeeks.contains(shopWeek) && model.weeks[shopWeek] == nil {
                Spacer(); ProgressView().tint(Theme.accent); Spacer()
            } else if model.failedWeeks.contains(shopWeek) {
                failure { Task { await model.load(shopWeek, force: true) } }
            } else if visibleWeek.isEmpty {
                Spacer()
                Text(model.weeks[shopWeek] == nil ? "Loading…" : (shopWeek.isOut ? "Nothing here" : "Nothing announced yet"))
                    .foregroundStyle(Theme.secondary)
                Spacer()
            } else {
                gridScroll(visibleWeek) { await model.load(shopWeek, force: true) }
            }
        }
    }

    /// One release week as a pill: its Wednesday. Weeks still to come have an outline; the chosen one is filled.
    private func weekChip(_ w: ReleaseWeek) -> some View {
        let on = w == shopWeek
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return Button { shopPick = w } label: {
            Text(f.string(from: DiscoverModel.releaseDate(w)))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(on ? Theme.onAccent : Color.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(on ? Theme.accent : (w.isOut ? Theme.card2 : Color.clear), in: Capsule())
                .overlay(Capsule().stroke(on || w.isOut ? Color.clear : Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    static func dayText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }

    // MARK: For You

    private var forYouContent: some View {
        let nothingYet = model.forYouSections.isEmpty && model.weeks[.current] == nil && model.weeks[.next] == nil
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if library.comics.isEmpty {
                    emptyLibrary
                }
                ForEach(model.forYouSections) { sec in shelf(sec) }
                if library.comics.isEmpty {
                    shelf(ForYouSection(title: "Trending This Week", subtitle: "What readers are pulling most",
                                        comics: Array((model.weeks[.current] ?? []).sorted { $0.pulls > $1.pulls }.prefix(12))))
                }
                if nothingYet {
                    if model.failedWeeks.isEmpty {
                        skeletonShelf(); skeletonShelf()
                    } else {
                        failure { Task { await model.load(.current, force: true); await model.load(.next, force: true) } }
                    }
                }
                attribution
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .ignoresSafeArea(.container, edges: .horizontal)      // fill the whole screen width
        .refreshable {
            await model.load(.current, force: true)
            await model.load(.next, force: true)
            await model.recommend(libraryTitles: TitleTools.byRecency(library.comics), force: true)
        }
    }

    private var emptyLibrary: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").font(.title3).foregroundStyle(Theme.accent)
            Text("Add a few comics to your library and this page will suggest more like them.")
                .font(.subheadline).foregroundStyle(Theme.secondary)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private func shelf(_ sec: ForYouSection) -> some View {
        if !sec.comics.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(sec.title, subtitle: sec.subtitle)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(sec.comics) { c in
                            Button { selected = c } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    CoverThumb(url: c.cover, width: 122)
                                    Text(c.title).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .frame(width: 122, alignment: .leading)
                                    if !c.publisher.isEmpty {
                                        Text(c.publisher).font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                                            .frame(width: 122, alignment: .leading)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.horizontal, -20)          // the row slides edge to edge
            }
        }
    }

    private func sectionHeader(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 4, height: 18)
                Text(title).font(.system(size: 19, weight: .heavy, design: .rounded)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.8)
            }
            if let subtitle = subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.footnote).foregroundStyle(Theme.secondary).padding(.leading, 12)
            }
        }
    }

    // MARK: Grid and cards

    private func card(_ c: DiscoverComic) -> some View {
        Button { selected = c } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverCard(url: c.cover)
                Text(c.title).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !c.publisher.isEmpty {
                    Text(c.publisher).font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .buttonStyle(.plain)
    }

    private func gridScroll(_ items: [DiscoverComic], refresh: (() async -> Void)? = nil) -> some View {
        ScrollView {
            LazyVGrid(columns: grid, spacing: 18) {
                ForEach(items) { c in card(c) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            attribution.padding(.vertical, 18).padding(.horizontal, 20)
        }
        .ignoresSafeArea(.container, edges: .horizontal)
        .refreshable { if let r = refresh { await r() } }
    }

    private var attribution: some View {
        Text("Data from League of Comic Geeks (leagueofcomicgeeks.com).")
            .font(.caption2).foregroundStyle(Theme.secondary)
    }

    /// Grey placeholders in the shape of a shelf, shown only the very first time, before anything has loaded.
    private func skeletonShelf() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 4).fill(Theme.card2).frame(width: 150, height: 18)
            skeletonRow
        }
    }

    private var skeletonRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(0..<5, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 8).fill(Theme.card).frame(width: 122, height: 183)
                        RoundedRectangle(cornerRadius: 3).fill(Theme.card).frame(width: 90, height: 10)
                    }
                }
            }
        }
        .disabled(true)
    }

    private func failure(_ retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Couldn't load the release list").font(.headline)
            Text("Check your connection and try again.").font(.subheadline).foregroundStyle(Theme.secondary)
            Button("Try Again", action: retry).buttonStyle(YellowButtonStyle(compact: true))
            if let url = URL(string: "https://leagueofcomicgeeks.com/comics/new-comics") {
                Button("Open the list in the browser") { onOpen(url) }.font(.footnote).foregroundStyle(Theme.accent)
            }
            Spacer()
        }
        .multilineTextAlignment(.center)
        .padding(30)
    }
}

/// A cover that fills whatever width it is given (2:3 shape).
private struct CoverCard: View {
    let url: URL?
    @State private var image: UIImage?

    init(url: URL?) {
        self.url = url
        _image = State(initialValue: DiscoverCovers.shared.cached(url))
    }

    var body: some View {
        Theme.card2
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image = image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                } else {
                    Image(systemName: "book.closed").foregroundStyle(Theme.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            .animation(.easeOut(duration: 0.18), value: image != nil)
            .task(id: url) {
                guard image == nil, let u = url else { return }
                image = await DiscoverCovers.shared.load(u)
            }
    }
}

/// A cover picture. It is taken from the cover cache, so it shows at once when it has been seen or fetched ahead.
private struct CoverThumb: View {
    let url: URL?
    var width: CGFloat = 46
    @State private var image: UIImage?

    init(url: URL?, width: CGFloat = 46) {
        self.url = url
        self.width = width
        _image = State(initialValue: DiscoverCovers.shared.cached(url))
    }

    var body: some View {
        ZStack {
            Theme.card2
            if let image = image {
                Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
            } else {
                Image(systemName: "book.closed").foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: width > 60 ? 8 : 6, style: .continuous))
        .shadow(color: .black.opacity(width > 60 ? 0.5 : 0), radius: 5, y: 3)
        .animation(.easeOut(duration: 0.18), value: image != nil)
        .task(id: url) {
            guard image == nil, let u = url else { return }
            image = await DiscoverCovers.shared.load(u)
        }
    }
}

/// Everything about one comic in one clean page: cover, facts, the story blurb, who made it, a note on the series, and the
/// two ways to go find it.
private struct DetailSheet: View {
    let comic: DiscoverComic
    /// The browser's home website, by name (getcomics.org unless it was changed).
    static var homeName: String {
        let host = URL(string: BrowserModel.shared.homeURL)?.host ?? ""
        let name = host.replacingOccurrences(of: "www.", with: "")
        return name.isEmpty ? "My Home Website" : name
    }

    var onFind: () -> Void
    var onOpen: (URL) -> Void
    @State private var detail: ComicDetail?
    @State private var loading = true

    private var releaseText: String? {
        guard let day = comic.released else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: day) else { return nil }
        let out = DateFormatter(); out.dateStyle = .long
        return out.string(from: d)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 16) {
                        CoverThumb(url: comic.cover, width: 112)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(comic.title).font(.title3.weight(.bold)).foregroundStyle(.white)
                            if !comic.publisher.isEmpty { Text(comic.publisher).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent) }
                            if let r = releaseText { fact("calendar", r) }
                            if comic.pulls > 0 { fact("person.2", "\(comic.pulls.formatted()) readers follow this") }
                            if let rating = comic.rating, rating > 0 { fact("star", "\(rating)% community rating") }
                        }
                    }

                    VStack(spacing: 10) {
                        Button { onFind() } label: {
                            Label("Find on \(Self.homeName)", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(YellowButtonStyle(compact: false))
                    }

                    if let about = detail?.about ?? (comic.summary.isEmpty ? nil : comic.summary) {
                        block("About This Comic") {
                            Text(about).font(.subheadline).lineSpacing(3).foregroundStyle(Color(white: 0.88))
                        }
                    }
                    if let people = detail?.creators, !people.isEmpty {
                        block("Creators") {
                            Text(people.joined(separator: " · ")).font(.subheadline).foregroundStyle(Color(white: 0.88))
                        }
                    }
                    if let series = detail?.seriesAbout {
                        block("About the Series") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(series).font(.subheadline).lineSpacing(3).foregroundStyle(Color(white: 0.88))
                                if let src = detail?.seriesSource { Text(src).font(.caption).foregroundStyle(Theme.secondary) }
                            }
                        }
                    }
                    if loading {
                        HStack(spacing: 8) { ProgressView().tint(Theme.accent); Text("Loading more…").font(.footnote).foregroundStyle(Theme.secondary) }
                    }
                }
                .padding(20)
            }
        }
        .task {
            detail = await DiscoverModel.shared.detail(for: comic)
            loading = false
        }
    }

    private func fact(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(Theme.secondary).frame(width: 16)
            Text(text).font(.footnote).foregroundStyle(Theme.secondary)
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder _ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
            body()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
