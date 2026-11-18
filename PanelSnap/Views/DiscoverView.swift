import SwiftUI

/// New comic releases, week by week, most popular first. Pick one to open its listing, or to search your Home
/// website for it.
struct DiscoverView: View {
    var onFind: (DiscoverComic) -> Void
    var onOpen: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DiscoverModel()
    @State private var topInset: CGFloat = 0
    @State private var landscape = false
    @State private var search = ""
    @State private var publisher: String?
    @State private var sort: DiscoverSort = .popular
    @State private var selected: DiscoverComic?

    private var publishers: [String] {
        let counts = Dictionary(grouping: model.comics.filter { !$0.publisher.isEmpty }, by: { $0.publisher }).mapValues { $0.count }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(12).map { $0.key }
    }

    private var visible: [DiscoverComic] {
        var list = model.comics
        if let p = publisher { list = list.filter { $0.publisher == p } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.publisher.localizedCaseInsensitiveContains(q) } }
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
                Picker("Week", selection: $model.week) {
                    ForEach(ReleaseWeek.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                searchField
                if !publishers.isEmpty { chips }
                content
            }
        }
        .readSafeTop($topInset)
        .readLandscape($landscape)
        .task(id: model.week) { publisher = nil; await model.load() }
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
            TextField("Search this week's releases", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary) }
                    .accessibilityLabel("Clear search")
            }
            Menu {
                Picker("Sort", selection: $sort) { ForEach(DiscoverSort.allCases) { Text($0.label).tag($0) } }
            } label: {
                Text(sort.label).font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
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

    @ViewBuilder private var content: some View {
        if model.loading && model.comics.isEmpty {
            Spacer(); ProgressView().tint(Theme.accent); Spacer()
        } else if model.failed {
            Spacer()
            VStack(spacing: 12) {
                Text("Couldn't load the release list").font(.headline)
                Text("Check your connection and try again.").font(.subheadline).foregroundStyle(Theme.secondary)
                Button("Try Again") { Task { await model.load(force: true) } }.buttonStyle(YellowButtonStyle(compact: true))
                if let url = URL(string: "https://leagueofcomicgeeks.com/comics/new-comics") {
                    Button("Open the list in the browser") { onOpen(url) }
                        .font(.footnote).foregroundStyle(Theme.accent)
                }
            }
            .multilineTextAlignment(.center)
            .padding(30)
            Spacer()
        } else if visible.isEmpty {
            Spacer(); Text("Nothing matches").foregroundStyle(Theme.secondary); Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(visible) { comic in
                        Button { selected = comic } label: { row(comic) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                Text("Data from League of Comic Geeks (leagueofcomicgeeks.com).")
                    .font(.caption2).foregroundStyle(Theme.secondary)
                    .padding(.vertical, 18)
            }
            .refreshable { await model.load(force: true) }
        }
    }

    private func row(_ c: DiscoverComic) -> some View {
        HStack(spacing: 12) {
            CoverThumb(url: c.cover)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                Text(c.publisher).font(.caption).foregroundStyle(Theme.accent)
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
