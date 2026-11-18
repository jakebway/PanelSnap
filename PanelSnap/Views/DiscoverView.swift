import SwiftUI

/// New comic releases, week by week, most popular first. Pick one to open its listing, or to search your Home
/// website for it.
enum DiscoverTab: String, CaseIterable, Identifiable {
    case forYou, current, next, previous
    var id: String { return rawValue }
    var label: String {
        switch self {
        case .forYou: return "For You"
        case .current: return "This Week"
        case .next: return "Next Week"
        case .previous: return "Last Week"
        }
    }
    var week: ReleaseWeek? {
        switch self {
        case .forYou: return nil
        case .current: return .current
        case .next: return .next
        case .previous: return .previous
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
    @State private var search = ""
    @State private var publisher: String?
    @State private var sort: DiscoverSort = .popular
    @State private var selected: DiscoverComic?

    private var searching: Bool { return search.trimmingCharacters(in: .whitespaces).count >= 2 }
    private var weekList: [DiscoverComic] { return tab.week.flatMap { model.weeks[$0] } ?? [] }

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
                    if tab != .forYou, !publishers.isEmpty { chips }
                }
                content
            }
        }
        .readSafeTop($topInset)
        .readLandscape($landscape)
        .task(id: tab) {
            publisher = nil
            if let w = tab.week { await model.load(w) }
            else {
                await model.recommend(libraryTitles: library.comics.map { $0.title })
                await model.load(.current)
                await model.load(.next)
            }
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
                .presentationDetents([.medium, .large])
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
            } else if tab != .forYou {
                Menu {
                    Picker("Sort", selection: $sort) { ForEach(DiscoverSort.allCases) { Text($0.label).tag($0) } }
                } label: {
                    Text(sort.label).font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", on: publisher == nil) { publisher = nil }
                ForEach(publishers, id: \.self) { p in chip(p, on: publisher == p) { publisher = p } }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 8)
    }

    private func chip(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.footnote.weight(.semibold))
                .foregroundStyle(on ? Theme.onAccent : Color.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(on ? Theme.accent : Theme.card2, in: Capsule())
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if searching {
            if model.searching && model.searchResults.isEmpty {
                Spacer(); ProgressView().tint(Theme.accent); Spacer()
            } else if model.searchResults.isEmpty {
                Spacer(); Text("No comics found").foregroundStyle(Theme.secondary); Spacer()
            } else {
                list(model.searchResults)
            }
        } else if let w = tab.week {
            weekContent(w)
        } else {
            forYouContent
        }
    }

    @ViewBuilder private func weekContent(_ w: ReleaseWeek) -> some View {
        if model.loadingWeeks.contains(w) && model.weeks[w] == nil {
            Spacer(); ProgressView().tint(Theme.accent); Spacer()
        } else if model.failedWeeks.contains(w) {
            failure { Task { await model.load(w, force: true) } }
        } else if visibleWeek.isEmpty {
            Spacer(); Text("Nothing here yet").foregroundStyle(Theme.secondary); Spacer()
        } else {
            list(visibleWeek) { await model.load(w, force: true) }
        }
    }

    private var forYouContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.forYou.isEmpty && library.comics.isEmpty {
                    Text("Add a few comics to your library and this page will suggest more like them.")
                        .font(.subheadline).foregroundStyle(Theme.secondary)
                }
                shelf("You May Also Like", model.forYou)
                shelf("Popular This Week", Array((model.weeks[.current] ?? []).sorted { $0.pulls > $1.pulls }.prefix(20)))
                shelf("Coming Next Week", Array((model.weeks[.next] ?? []).sorted { $0.pulls > $1.pulls }.prefix(20)))
                if model.forYou.isEmpty && model.weeks[.current] == nil && model.weeks[.next] == nil {
                    if model.failedWeeks.isEmpty { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 40) }
                    else { failure { Task { await model.load(.current, force: true); await model.load(.next, force: true) } } }
                }
                Text("Data from League of Comic Geeks (leagueofcomicgeeks.com).")
                    .font(.caption2).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder private func shelf(_ title: String, _ items: [DiscoverComic]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(items) { c in
                            Button { selected = c } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    CoverThumb(url: c.cover, width: 104)
                                    Text(c.title).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                                        .frame(width: 104, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
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

    private func list(_ items: [DiscoverComic], refresh: (() async -> Void)? = nil) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(items) { comic in
                    Button { selected = comic } label: { row(comic) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            Text("Data from League of Comic Geeks (leagueofcomicgeeks.com).")
                .font(.caption2).foregroundStyle(Theme.secondary)
                .padding(.vertical, 18)
        }
        .refreshable { if let r = refresh { await r() } }
    }

    private func row(_ c: DiscoverComic) -> some View {
        HStack(spacing: 12) {
            CoverThumb(url: c.cover)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                if !c.publisher.isEmpty { Text(c.publisher).font(.caption).foregroundStyle(Theme.accent) }
                if c.pulls > 0 { Text("\(c.pulls.formatted()) pulls").font(.caption).foregroundStyle(Theme.secondary) }
            }
            Spacer(minLength: 4)
            if !c.price.isEmpty { Text(c.price).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.secondary)
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A cover picture that falls back to a plain tile when there is none.
private struct CoverThumb: View {
    let url: URL?
    var width: CGFloat = 46
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack { Theme.card2; Image(systemName: "book.closed").foregroundStyle(Theme.secondary) }
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct DetailSheet: View {
    let comic: DiscoverComic
    var onFind: () -> Void
    var onOpen: (URL) -> Void

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        CoverThumb(url: comic.cover, width: 90)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(comic.title).font(.title3.weight(.bold)).foregroundStyle(.white)
                            Text(comic.publisher).font(.subheadline).foregroundStyle(Theme.accent)
                            HStack(spacing: 10) {
                                if !comic.price.isEmpty { Text(comic.price).font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary) }
                                if comic.pulls > 0 { Text("\(comic.pulls.formatted()) pulls").font(.footnote).foregroundStyle(Theme.secondary) }
                            }
                        }
                    }
                    if !comic.summary.isEmpty {
                        Text(comic.summary).font(.subheadline).foregroundStyle(Color(white: 0.85))
                    }
                    Button { onFind() } label: {
                        Label("Find on My Home Website", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(YellowButtonStyle(compact: false))
                    if let url = comic.listingURL, url.scheme?.hasPrefix("http") == true {
                        Button { onOpen(url) } label: {
                            Label("Open Listing in Browser", systemImage: "globe").frame(maxWidth: .infinity)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 12)
                        .background(Theme.card2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(20)
            }
        }
    }
}
