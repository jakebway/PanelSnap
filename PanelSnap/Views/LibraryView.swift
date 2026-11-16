import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var settings: AppSettings

    @State private var route: Route?
    @State private var search = ""
    @State private var sort: SortMode = .recent

    /// One presentation slot for everything (reader + settings) so SwiftUI presentations never fight each other.
    enum Route: Identifiable {
        case reader(ComicEntry)
        case settings
        var id: String {
            switch self {
            case .reader(let e): return "reader-" + e.id.uuidString
            case .settings: return "settings"
            }
        }
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case recent = "Recently added"
        case title = "Title"
        case progress = "Reading progress"
        var id: String { return rawValue }
    }

    private var visible: [ComicEntry] {
        var list = library.comics
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(q) }
        }
        switch sort {
        case .recent:
            list.sort { $0.addedAt > $1.addedAt }
        case .title:
            list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .progress:
            list.sort { $0.progress > $1.progress }
        }
        return list
    }

    private var continueReading: ComicEntry? {
        return library.comics
            .filter { $0.hasStarted && !$0.finished }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
            .first
    }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16, alignment: .top)]

    private func addComics() {
        FilePicker.present(types: [UTType.item], multiple: true) { urls in
            Task { await library.importFiles(urls) }
        }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if library.comics.isEmpty && !library.isImporting {
                    emptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            searchField
                            if let c = continueReading, search.isEmpty {
                                continueCard(c)
                            }
                            LazyVGrid(columns: columns, spacing: 22) {
                                ForEach(visible) { entry in
                                    ComicCell(entry: entry)
                                        .onTapGesture { route = .reader(entry) }
                                        .contextMenu { menu(for: entry) }
                                }
                            }
                        }
                        .frame(maxWidth: 900)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .padding(.bottom, 110)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // floating yellow "add" button (hidden on the empty screen, which has its own big one)
            if !(library.comics.isEmpty && !library.isImporting) {
                VStack {
                    Spacer()
                    Button { addComics() } label: {
                        Label("Add Comics", systemImage: "plus")
                    }
                    .buttonStyle(YellowButtonStyle())
                    .shadow(color: .black.opacity(0.6), radius: 14, y: 6)
                    .padding(.bottom, 22)
                }
            }

            if let status = library.importStatus {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        ProgressView().tint(Theme.accent)
                        Text(status).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Theme.card2, in: Capsule())
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                    .padding(.bottom, 92)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let message = library.errorMessage {
                errorCard(message)
            }
        }
        .animation(.easeInOut, value: library.importStatus)
        .fullScreenCover(item: $route) { r in
            switch r {
            case .reader(let entry):
                ReaderHost(entry: entry)
            case .settings:
                SettingsView()
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        ZStack {
            Text("Library")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            HStack {
                Button { route = .settings } label: { CircleIcon(systemName: "gearshape.fill") }
                Spacer()
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(SortMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                } label: { CircleIcon(systemName: "arrow.up.arrow.down") }
            }
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
            TextField("Search your comics", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Theme.card)
                    .frame(width: 112, height: 112)
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.accent)
            }
            Text("Your library is empty")
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text("Add comics from the Files app, iCloud Drive, or anywhere on your iPhone. PanelSnap reads CBZ, CBR, CB7, PDF and EPUB.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.horizontal, 28)
            Button { addComics() } label: {
                Label("Add Comics", systemImage: "plus")
            }
            .buttonStyle(YellowButtonStyle())
            .padding(.top, 8)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorCard(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
                .onTapGesture { library.errorMessage = nil }
            VStack(spacing: 14) {
                Text("Some files couldn't be added")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                Button("OK") { library.errorMessage = nil }
                    .buttonStyle(YellowButtonStyle(compact: true))
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(30)
        }
    }

    private func continueCard(_ entry: ComicEntry) -> some View {
        Button {
            route = .reader(entry)
        } label: {
            HStack(spacing: 16) {
                CoverView(entry: entry)
                    .frame(width: 74, height: 110)
                VStack(alignment: .leading, spacing: 6) {
                    Text("CONTINUE READING")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.accent)
                    Text(entry.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("Page \(entry.lastPage + 1) of \(entry.pageCount)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                    ProgressView(value: entry.progress)
                        .tint(Theme.accent)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.secondary)
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func menu(for entry: ComicEntry) -> some View {
        Button {
            library.markRead(id: entry.id, !entry.finished)
        } label: {
            Label(entry.finished ? "Mark as unread" : "Mark as read",
                  systemImage: entry.finished ? "arrow.uturn.backward" : "checkmark.circle")
        }
        Button {
            library.setManga(id: entry.id, !entry.isManga)
        } label: {
            Label(entry.isManga ? "Read left-to-right" : "Read right-to-left (manga)",
                  systemImage: "arrow.left.arrow.right")
        }
        Button(role: .destructive) {
            library.delete(entry)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

struct CoverView: View {
    @EnvironmentObject var library: LibraryStore
    let entry: ComicEntry

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.card2)
            if let img = CoverCache.shared.image(for: library.coverURL(for: entry)) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "book.closed.fill")
                    .font(.title)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 7, y: 4)
    }
}

struct ComicCell: View {
    let entry: ComicEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverView(entry: entry)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if entry.finished {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.black, Theme.accent)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if entry.hasStarted && !entry.finished {
                        ProgressView(value: entry.progress)
                            .tint(Theme.accent)
                            .padding(8)
                    }
                }
            Text(entry.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(entry.format.label) · \(entry.pageCount) pages")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
        }
        .contentShape(Rectangle())
    }
}
