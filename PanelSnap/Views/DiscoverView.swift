import SwiftUI

/// New comic releases, week by week. Pick one to open its official listing, or to search your Home website for it.
struct DiscoverView: View {
    var onFind: (DiscoverComic) -> Void
    var onOpen: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DiscoverModel()
    @State private var topInset: CGFloat = 0
    @State private var landscape = false
    @State private var search = ""
    @State private var selected: DiscoverComic?

    private var visible: [DiscoverComic] {
        var list = model.comics
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.title.localizedCaseInsensitiveContains(q) } }
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
                content
            }
        }
        .readSafeTop($topInset)
        .readLandscape($landscape)
        .task(id: model.week) { await model.load() }
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
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
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
                if let url = URL(string: "https://gocollect.com/blog/category/comiclist/this-week") {
                    Button("Open ComicList in the browser") { onOpen(url) }
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
                Text("Data from the Grand Comics Database (comics.org), CC BY-SA.")
                    .font(.caption2).foregroundStyle(Theme.secondary)
                    .padding(.vertical, 18)
            }
            .refreshable { await model.load(force: true) }
        }
    }

    private func row(_ c: DiscoverComic) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(c.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                if !c.year.isEmpty { Text(c.year + " series").font(.caption).foregroundStyle(Theme.accent) }
            }
            Spacer(minLength: 4)
            if !c.price.isEmpty { Text(c.price).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.secondary)
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text(comic.title).font(.title3.weight(.bold)).foregroundStyle(.white)
                        if !comic.year.isEmpty { Text(comic.year + " series").font(.subheadline).foregroundStyle(Theme.accent) }
                        HStack(spacing: 10) {
                            if !comic.price.isEmpty { Text(comic.price).font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary) }
                            if !comic.pages.isEmpty { Text(comic.pages + " pages").font(.footnote).foregroundStyle(Theme.secondary) }
                        }
                    }
                    Button { onFind() } label: {
                        Label("Find on My Home Website", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(YellowButtonStyle(compact: false))
                    if let url = comic.listingURL {
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
