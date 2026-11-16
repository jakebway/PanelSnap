import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var settings: AppSettings

    @Environment(\.scenePhase) private var scenePhase
    @State private var route: Route?
    @State private var search = ""

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

    private var visible: [ComicEntry] {
        var list = library.comics
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(q) }
        }
        list.sort { $0.addedAt > $1.addedAt }
        return list
    }

    private var continueReading: ComicEntry? {
        return library.comics
            .filter { $0.hasStarted && !$0.finished }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
            .first
    }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16, alignment: .top)]

    /// Tap a file and it is added straight away (like iOXcode). Long-press the button to pick several at once.
    private func addComics(multiple: Bool = false) {
        FilePicker.present(types: [UTType.item], multiple: multiple) { urls in
            Task { await library.importFiles(urls) }
        }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            FullWidthCentered {
                ZStack {
                VStack(spacing: 0) {
                    header
                    if library.comics.isEmpty && !library.isImporting {
                        emptyState
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                // This top band sits beside the Duo's corner camera, so it holds the useful stuff.
                                VStack(alignment: .leading, spacing: 14) {
                                    if showSearch {
                                        searchField
                                    }
                                    if search.isEmpty {
                                        if let c = continueReading {
                                            continueCard(c)
                                        } else {
                                            statsTile
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: Theme.cameraHeight - 64, alignment: .top)
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
                            .padding(.top, 0)
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
                        .contextMenu {
                            Button { addComics(multiple: true) } label: {
                                Label("Select several files", systemImage: "checklist")
                            }
                        }
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
            }
        }
        .animation(.easeInOut, value: library.importStatus)
        .onAppear {
            Console.logEnvironment(reason: "library appeared")
            Task { await library.scanFolder() }
        }
        .onChange(of: scenePhase) { _, phase in
            Console.log("app state: \(phase)")
            if phase == .active { Task { await library.scanFolder() } }
        }
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

    private var showSearch: Bool { return library.comics.count > 6 }

    private var header: some View {
        ZStack {
            Text("Library")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            HStack {
                Button { route = .settings } label: { CircleIcon(systemName: "gearshape.fill") }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
            TextField("Search", text: $search)
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
        .padding(.trailing, Theme.cameraWidth)      // stay clear of the Duo's corner camera
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
            Text("Tap Add Comics and choose a file. PanelSnap reads CBZ, CBR, CB7, PDF and EPUB.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.horizontal, 28)
            Button { addComics() } label: {
                Label("Add Comics", systemImage: "plus")
            }
            .buttonStyle(YellowButtonStyle())
            .contextMenu {
                Button { addComics(multiple: true) } label: {
                    Label("Select several files", systemImage: "checklist")
                }
            }
            .padding(.top, 8)
            Button { Task { await library.scanFolder() } } label: {
                Label("Scan Comics folder", systemImage: "arrow.clockwise")
            }
            .buttonStyle(GreyButtonStyle())
            Text("Or drop files into Files › On My iPhone › PanelSnap › Comics. They appear here by themselves.")
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.horizontal, 28)
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
            HStack(spacing: 14) {
                CoverView(entry: entry)
                    .frame(width: 58, height: 86)
                VStack(alignment: .leading, spacing: 5) {
                    Text("CONTINUE READING")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.accent)
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("Page \(entry.lastPage + 1) of \(entry.pageCount)")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                    ProgressView(value: entry.progress)
                        .tint(Theme.accent)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.trailing, Theme.cameraWidth)      // stay clear of the Duo's corner camera
    }

    /// Shown in the top band when nothing is in progress.
    private var statsTile: some View {
        let finished = library.comics.filter { $0.finished }.count
        let reading = library.comics.filter { $0.hasStarted && !$0.finished }.count
        return HStack(spacing: 0) {
            stat(library.comics.count, "Comics")
            stat(reading, "Reading")
            stat(finished, "Finished")
        }
        .padding(.vertical, 18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.trailing, Theme.cameraWidth)
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.accent)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
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
