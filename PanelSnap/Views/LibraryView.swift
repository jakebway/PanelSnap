import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var settings: AppSettings

    @Environment(\.scenePhase) private var scenePhase
    @State private var route: Route?
    @State private var search = ""
    @State private var topInset: CGFloat = 0
    @State private var themeStamp = ""                      // changes after Settings closes, to repaint with new colours

    // Organising
    @State private var shelf: String?                       // nil = every comic
    @State private var organizing = false
    @State private var continueID: UUID?                    // which Continue Reading card leads the row
    @State private var selection = Set<UUID>()
    @State private var showRename = false
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var showShelfAlert = false
    @State private var shelfRenaming: String?               // nil = creating a new shelf
    @State private var shelfMoveIDs = Set<UUID>()           // comics to move into a shelf that is being created
    @State private var shelfText = ""
    @State private var showDeleteShelf = false
    @State private var shelfToDelete = ""
    @State private var showDeleteComics = false
    @State private var deleteIDs = Set<UUID>()

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

    private func sorted(_ list: [ComicEntry], by sort: LibrarySort) -> [ComicEntry] {
        var out = list
        switch sort {
        case .recent: out.sort { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
        case .added: out.sort { $0.addedAt > $1.addedAt }
        case .title: out.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .custom: break
        }
        return out
    }

    private var visible: [ComicEntry] {
        var list = library.comics
        if let s = shelf { list = list.filter { $0.shelf == s } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(q) }
        }
        return sorted(list, by: settings.librarySort)
    }

    /// Everything you have started and not finished, most recently read first.
    private var continueList: [ComicEntry] {
        let started = library.comics.filter { $0.hasStarted && !$0.finished }
        let ordered = started.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        return Array(ordered.prefix(8))
    }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16, alignment: .top)]

    /// One picker for everything: choose a single comic or as many as you like.
    private func addComics() {
        let target = shelf
        FilePicker.present(types: [UTType.item], multiple: true) { urls in
            Task { await library.importFiles(urls, shelf: target) }
        }
    }

    private func addFolder() {
        let target = shelf
        FilePicker.presentFolder { url in
            Task { await library.importFolder(url, shelf: target) }
        }
    }

    /// Add button (pick one or many files at once) plus a small button to import a whole folder.
    private var addRow: some View {
        HStack(spacing: 12) {
            Button { addComics() } label: {
                Label("Add Comics", systemImage: "plus")
            }
            .buttonStyle(YellowButtonStyle())
            Button { addFolder() } label: { CircleIcon(systemName: "folder.fill") }
                .accessibilityLabel("Add a whole folder")
        }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            // A soft red glow at the top, like the speed-line background of the icon.
            VStack {
                LinearGradient(colors: [Theme.red.opacity(0.34), Theme.red.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 260)
                Spacer()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            FullWidthCentered {
                ZStack {
                VStack(spacing: 0) {
                    header
                    if library.comics.isEmpty && !library.isImporting {
                        emptyState
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                // This top band sits beside the Duo's corner camera, so it holds the useful stuff.
                                VStack(alignment: .leading, spacing: 14) {
                                    if showSearch {
                                        searchField
                                    }
                                    if search.isEmpty && !organizing {
                                        let list = continueList
                                        if list.count == 1 {
                                            continueCard(list[0])
                                                .padding(.trailing, cameraPad)      // stay clear of the Duo's corner camera
                                        } else if list.count > 1 {
                                            continueRow(list)
                                        } else {
                                            statsTile
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: wideStatus ? 0 : Theme.cameraHeight - 64, alignment: .top)

                                shelfBar
                                sortRow

                                let items = visible
                                if items.isEmpty {
                                    Text(shelf == nil ? "No comics match your search." : "Nothing on this shelf yet. Tap Organize, select comics and choose Shelf.")
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.top, 30)
                                } else {
                                    LazyVGrid(columns: columns, spacing: 22) {
                                        ForEach(items) { entry in
                                            cell(entry)
                                        }
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

                // floating bottom bar: the yellow "add" button, or the actions while organising
                if !(library.comics.isEmpty && !library.isImporting) {
                    VStack {
                        Spacer()
                        Group {
                            if organizing { organizeBar } else { addRow }
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
            .id(themeStamp)
        }
        .animation(.easeInOut, value: library.importStatus)
        .readSafeTop($topInset)
        .onChange(of: route?.id) { _, id in
            if id == nil { themeStamp = settings.themeKey }
        }
        .onAppear {
            Console.logEnvironment(reason: "library appeared")
            Task { await library.scanFolder() }
        }
        .onChange(of: scenePhase) { _, phase in
            Console.log("app state: \(phase)")
            if phase == .active {
                Task { await library.scanFolder() }
            } else {
                library.flush()          // don't lose progress if iOS closes the app
            }
        }
        .onChange(of: library.shelves) { _, list in
            if let s = shelf, !list.contains(s) { shelf = nil }
        }
        .alert("Rename comic", isPresented: $showRename) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let id = renameID { library.rename(id: id, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(shelfRenaming == nil ? "New shelf" : "Rename shelf", isPresented: $showShelfAlert) {
            TextField("Shelf name", text: $shelfText)
            Button(shelfRenaming == nil ? "Create" : "Save") { commitShelfName() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if shelfRenaming == nil && !shelfMoveIDs.isEmpty {
                Text("The selected comics move onto it.")
            }
        }
        .confirmationDialog("Delete this shelf?", isPresented: $showDeleteShelf, titleVisibility: .visible) {
            Button("Delete shelf", role: .destructive) {
                library.deleteShelf(shelfToDelete)
                if shelf == shelfToDelete { shelf = nil }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The comics stay in your library.")
        }
        .confirmationDialog(deleteIDs.count == 1 ? "Delete this comic?" : "Delete \(deleteIDs.count) comics?",
                            isPresented: $showDeleteComics, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.delete(ids: deleteIDs)
                selection.subtract(deleteIDs)
                deleteIDs = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files are removed from PanelSnap.")
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

    // MARK: Organising

    private func cell(_ entry: ComicEntry) -> some View {
        ComicCell(entry: entry, organizing: organizing, selected: selection.contains(entry.id))
            .onTapGesture {
                if organizing {
                    if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
                } else {
                    route = .reader(entry)
                }
            }
            .contextMenu {
                if !organizing { menu(for: entry) }
            }
            .modifier(ReorderModifier(enabled: organizing, id: entry.id) { dragged, target in
                reorder(dragged, onto: target)
            })
    }

    private func reorder(_ dragged: UUID, onto target: UUID) {
        if settings.librarySort != .custom {
            // Freeze what is on screen as "my order", then move the comic within it.
            library.applyOrder(sorted(library.comics, by: settings.librarySort).map { $0.id })
            settings.librarySort = .custom
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            library.moveComic(dragged, onto: target)
        }
    }

    private func commitShelfName() {
        if let old = shelfRenaming {
            library.renameShelf(old, to: shelfText)
            if shelf == old { shelf = library.shelves.first(where: { $0.caseInsensitiveCompare(shelfText.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }) ?? old }
        } else if let name = library.addShelf(shelfText) {
            if !shelfMoveIDs.isEmpty {
                library.move(shelfMoveIDs, toShelf: name)
                shelfMoveIDs = []
            } else {
                shelf = name
            }
        }
    }

    private func newShelf(moving ids: Set<UUID>) {
        shelfRenaming = nil
        shelfMoveIDs = ids
        shelfText = ""
        showShelfAlert = true
    }

    private func endOrganizing() {
        organizing = false
        selection = []
    }

    private func shelfChip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(count)").font(.caption.weight(.bold)).opacity(0.6)
            }
            .foregroundStyle(selected ? Theme.onAccent : Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(selected ? Theme.accent : Theme.card2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var shelfBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                shelfChip("All", count: library.comics.count, selected: shelf == nil) { shelf = nil }
                ForEach(library.shelves, id: \.self) { name in
                    shelfChip(name, count: library.comics.filter { $0.shelf == name }.count, selected: shelf == name) { shelf = name }
                        .contextMenu {
                            Button {
                                shelfRenaming = name
                                shelfText = name
                                shelfMoveIDs = []
                                showShelfAlert = true
                            } label: { Label("Rename shelf", systemImage: "pencil") }
                            Button(role: .destructive) {
                                shelfToDelete = name
                                showDeleteShelf = true
                            } label: { Label("Delete shelf", systemImage: "trash") }
                        }
                }
                Button { newShelf(moving: []) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34)
                        .background(Theme.card2, in: Circle())
                }
                .accessibilityLabel("New shelf")
            }
            .padding(.vertical, 2)
        }
    }

    private var sortRow: some View {
        HStack {
            Menu {
                Picker("Sort", selection: $settings.librarySort) {
                    ForEach(LibrarySort.allCases) { sort in
                        Label(sort.label, systemImage: sort.icon).tag(sort)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(settings.librarySort.label)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.secondary)
            }
            Spacer()
            if organizing {
                Button(selection.count == visible.count && !selection.isEmpty ? "Select none" : "Select all") {
                    if selection.count == visible.count { selection = [] } else { selection = Set(visible.map { $0.id }) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.trailing, 6)
                Button("Done") { endOrganizing() }
                    .buttonStyle(YellowButtonStyle(compact: true))
            } else {
                Button { organizing = true } label: {
                    Label("Organize", systemImage: "square.grid.2x2")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func barPill(_ icon: String, _ text: String, tint: Color = .white) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.card2, in: Capsule())
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
    }

    /// Actions for the comics that are selected while organising.
    private var organizeBar: some View {
        HStack(spacing: 10) {
            Menu {
                shelfItems(for: selection)
            } label: { barPill("folder", "Shelf") }
            Menu {
                Button { library.markRead(ids: selection, true) } label: { Label("Mark as read", systemImage: "checkmark.circle") }
                Button { library.markRead(ids: selection, false) } label: { Label("Mark as unread", systemImage: "arrow.uturn.backward") }
            } label: { barPill("checkmark.circle", "Read") }
            Button {
                deleteIDs = selection
                showDeleteComics = true
            } label: { barPill("trash", "Delete", tint: Theme.red) }
            .buttonStyle(.plain)
        }
        .opacity(selection.isEmpty ? 0.45 : 1)
        .disabled(selection.isEmpty)
        .overlay(alignment: .top) {
            Text(selection.isEmpty ? "Tap comics to select them" : "\(selection.count) selected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)
                .offset(y: -22)
        }
    }

    @ViewBuilder
    private func shelfItems(for ids: Set<UUID>) -> some View {
        Button { library.move(ids, toShelf: nil) } label: { Label("No shelf", systemImage: "tray") }
        ForEach(library.shelves, id: \.self) { name in
            Button { library.move(ids, toShelf: name) } label: { Label(name, systemImage: "folder") }
        }
        Button { newShelf(moving: ids) } label: { Label("New shelf…", systemImage: "plus") }
    }

    // MARK: Pieces

    private var showSearch: Bool { return library.comics.count > 6 }

    /// On the wide layout the Duo's status widget is a short capsule in the corner (the layout starts below the
    /// system's safe area), so only the header needs to avoid it. On the narrow layout it is a tall box.
    private var wideStatus: Bool { return topInset > 20 }
    private var cameraPad: CGFloat { return wideStatus ? 0 : Theme.cameraWidth }

    private var header: some View {
        ZStack {
            ComicTitle(text: "Library")
            HStack {
                Button { route = .settings } label: { CircleIcon(systemName: "gearshape.fill") }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, wideStatus ? 22 : 30)      // wide screen: the camera widget is a short capsule, so the title can sit level with it
        .padding(.bottom, 14)
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
        .padding(.trailing, cameraPad)      // stay clear of the Duo's corner camera
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
            Text("Tap Add Comics and choose one or more files, or use the folder button for a whole folder. PanelSnap reads CBZ, CBR, CB7, PDF and EPUB.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.horizontal, 28)
            addRow
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

    /// Several books in progress: cards sized to fit exactly (one per page on the narrow layout, two on the wide one),
    /// snapping into place, so nothing is ever sliced off at the edge.
    private func continueRow(_ list: [ComicEntry]) -> some View {
        let perPage = wideStatus ? 2 : 1
        return VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(list) { entry in
                        continueCard(entry)
                            .containerRelativeFrame(.horizontal, count: perPage, spacing: 12)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $continueID)
            if list.count > perPage {
                HStack(spacing: 6) {
                    ForEach(list) { entry in
                        Circle()
                            .fill(entry.id == (continueID ?? list.first?.id) ? Theme.accent : Theme.secondary.opacity(0.35))
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
        .padding(.trailing, cameraPad)
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
                        .tint(Theme.red)
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
        .padding(.trailing, cameraPad)
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
            renameID = entry.id
            renameText = entry.title
            showRename = true
        } label: { Label("Rename", systemImage: "pencil") }
        Menu {
            shelfItems(for: [entry.id])
        } label: { Label("Move to shelf", systemImage: "folder") }
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
        Button {
            organizing = true
            selection = [entry.id]
        } label: { Label("Select…", systemImage: "checkmark.circle.badge.plus") }
        Button(role: .destructive) {
            deleteIDs = [entry.id]
            showDeleteComics = true
        } label: { Label("Delete", systemImage: "trash") }
    }
}

/// Lets a cell be dragged onto another one (only while organising).
private struct ReorderModifier: ViewModifier {
    let enabled: Bool
    let id: UUID
    let onDrop: (UUID, UUID) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let first = items.first, let dragged = UUID(uuidString: first) else { return false }
                    onDrop(dragged, id)
                    return true
                }
        } else {
            content
        }
    }
}

struct CoverView: View {
    @EnvironmentObject var library: LibraryStore
    let entry: ComicEntry
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.card2)
            if let img = image {
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
        .task(id: entry.id) {
            let url = library.coverURL(for: entry)
            if let hit = CoverCache.shared.cached(url) {
                image = hit
            } else {
                image = await CoverCache.shared.load(url)
            }
        }
    }
}

struct ComicCell: View {
    let entry: ComicEntry
    var organizing = false
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverView(entry: entry)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    if organizing && selected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if organizing {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected ? Theme.onAccent : Color.white, selected ? Theme.accent : Color.black.opacity(0.35))
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if entry.finished {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.onAccent, Theme.accent)
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
