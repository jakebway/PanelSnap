import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var settings: AppSettings

    @State private var showImporter = false
    @State private var showSettings = false
    @State private var opened: ComicEntry?
    @State private var search = ""
    @State private var sort: SortMode = .recent

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

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18, alignment: .top)]

    var body: some View {
        NavigationStack {
            Group {
                if library.comics.isEmpty && !library.isImporting {
                    emptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            if let c = continueReading, search.isEmpty {
                                continueCard(c)
                            }
                            LazyVGrid(columns: columns, spacing: 22) {
                                ForEach(visible) { entry in
                                    ComicCell(entry: entry)
                                        .onTapGesture { opened = entry }
                                        .contextMenu { menu(for: entry) }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 40)
                    }
                    .searchable(text: $search, prompt: "Search your comics")
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(SortMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let status = library.importStatus {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(status).font(.subheadline)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut, value: library.importStatus)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await library.importFiles(urls) }
            }
        }
        .fullScreenCover(item: $opened) { entry in
            ReaderHost(entry: entry)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("Some files couldn't be added", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { newValue in if !newValue { library.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    // MARK: Pieces

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                    .frame(width: 120, height: 120)
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.accent)
            }
            Text("Your library is empty")
                .font(.title2.weight(.bold))
            Text("Add comics from the Files app, iCloud Drive, or anywhere on your iPhone. PanelSnap reads CBZ, CBR, CB7, PDF and EPUB.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button {
                showImporter = true
            } label: {
                Label("Add Comics", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func continueCard(_ entry: ComicEntry) -> some View {
        Button {
            opened = entry
        } label: {
            HStack(spacing: 16) {
                CoverView(entry: entry)
                    .frame(width: 74, height: 110)
                VStack(alignment: .leading, spacing: 6) {
                    Text("CONTINUE READING")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                    Text(entry.title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("Page \(entry.lastPage + 1) of \(entry.pageCount)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProgressView(value: entry.progress)
                        .tint(Theme.accent)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
            Rectangle().fill(Color(.tertiarySystemFill))
            if let img = CoverCache.shared.image(for: library.coverURL(for: entry)) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "book.closed.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
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
                            .foregroundStyle(.white, Theme.accent)
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
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(entry.format.label) · \(entry.pageCount) pages")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
