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
    @State private var landscape = false
    @State private var themeStamp = ""                      // changes after Settings closes, to repaint with new colours

    // Organising
    @State private var shelf: String?                       // nil = every comic
    @State private var organizing = false
    @State private var continueID: UUID?                    // which Continue Reading card leads the row
    @State private var selection = Set<UUID>()
    @State private var showRename = false
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var nameRequest: ShelfNameRequest?
    @StateObject private var dragState = DragState()
    @State private var dropHover: String?             // the shelf (or "" for the library) a dragged comic is hovering over
    @State private var showDeleteShelf = false
    @State private var draggingID: UUID?
    @State private var showShelfManager = false
    @State private var dragActive = false          // the dragged cover has really started moving (not just a long press for the menu)
    @State private var gridFrame: CGRect = .zero    // where the grid is on screen, so a drop past either end can be told apart
    @State private var shelfToDelete = ""
    @State private var showDeleteComics = false
    @State private var deleteIDs = Set<UUID>()

    /// One presentation slot for everything (reader + settings) so SwiftUI presentations never fight each other.
    enum Route: Identifiable {
        case reader(ComicEntry)
        case settings
        case browser
        case discover
        var id: String {
            switch self {
            case .reader(let e): return "reader-" + e.id.uuidString
            case .settings: return "settings"
            case .browser: return "browser"
            case .discover: return "discover"
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
        let q = search.trimmingCharacters(in: .whitespaces)
        if let s = shelf { list = list.filter { $0.shelf == s } }
        else if q.isEmpty { list = list.filter { $0.shelf == nil } }      // comics on a shelf appear inside that shelf

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

    /// Shelves appear among the comics, like folders on a Home Screen (not while searching).
    private var folders: [String] { return shelf == nil && search.trimmingCharacters(in: .whitespaces).isEmpty ? library.shelves : [] }

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

    /// A discreet "+" that offers files or a whole folder.
    private var addMenu: some View {
        Menu {
            Button { addComics() } label: { Label("Files", systemImage: "doc.on.doc") }
            Button { addFolder() } label: { Label("Folder", systemImage: "folder") }
            Divider()
            Button { newShelf(moving: []) } label: { Label("New Shelf", systemImage: "books.vertical") }
            if !library.shelves.isEmpty {
                Button { showShelfManager = true } label: { Label("Edit & Reorder Shelves", systemImage: "arrow.up.arrow.down") }
            }
            Button { route = .browser } label: { Label("Browser", systemImage: "globe") }
        } label: {
            CircleIcon(systemName: "plus")
        }
        .accessibilityLabel("Add Comics")
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

                                if let s = shelf { shelfHeader(s) }
                                sortRow

                                let items = visible
                                if items.isEmpty && folders.isEmpty {
                                    Text(shelf == nil ? "No comics match your search." : "Nothing on this shelf yet. Press and hold a comic, then choose Move to Shelf, or drag it onto the shelf.")
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.top, 30)
                                } else {
                                    LazyVGrid(columns: columns, spacing: 22) {
                                        ForEach(folders, id: \.self) { name in
                                            folderCell(name)
                                        }
                                        ForEach(items) { entry in
                                            cell(entry)
                                        }
                                    }
                                    .background(
                                        GeometryReader { g in
                                            Color.clear.preference(key: GridFrameKey.self, value: g.frame(in: .named("libscroll")))
                                        }
                                    )
                                }
                            }
                            .frame(maxWidth: 900)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.top, 0)
                            .padding(.bottom, organizing ? 110 : 40)
                        }
                        .coordinateSpace(name: "libscroll")
                        .onPreferenceChange(GridFrameKey.self) { gridFrame = $0 }
                        // Letting go past the last comic puts it at the end; above the first puts it at the start.
                        .onDrop(of: [.text], delegate: ListDropDelegate(
                            dragging: $draggingID, active: $dragActive,
                            gridFrame: { gridFrame }, first: visible.first?.id, last: visible.last?.id,
                            place: { dragged, target in reorder(dragged, onto: target) }))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // floating bottom bar: the yellow "add" button, or the actions while organising
                if organizing {
                    VStack {
                        Spacer()
                        Group {
                            if organizing { organizeBar }
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
        .readLandscape($landscape)
        .onChange(of: route?.id) { _, id in
            if id == nil { themeStamp = settings.themeKey }
        }
        .onAppear {
            Task { await library.scanFolder() }
            // Compile the browser's ad-block lists quietly in the background, so the browser opens instantly.
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await BrowserShield.shared.prepare()
            }
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
        .alert("Rename Comic", isPresented: $showRename) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let id = renameID { library.rename(id: id, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $nameRequest) { req in
            ShelfNameSheet(request: req, existing: library.shelves, preview: previewComics(for: req)) { name in commit(req, name) }
                .environmentObject(library)
        }
        .confirmationDialog("Delete Shelf?", isPresented: $showDeleteShelf, titleVisibility: .visible) {
            Button("Delete Shelf", role: .destructive) {
                library.deleteShelf(shelfToDelete)
                if shelf == shelfToDelete { shelf = nil }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The comics stay in your library.")
        }
        .confirmationDialog(deleteIDs.count == 1 ? "Delete Comic?" : "Delete \(deleteIDs.count) Comics?",
                            isPresented: $showDeleteComics, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.delete(ids: deleteIDs)
                selection.subtract(deleteIDs)
                deleteIDs = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files will be removed from PanelSnap.")
        }
        .task(id: library.comics.count) {
            if settings.showDiscover { await DiscoverModel.shared.prefetch(libraryTitles: TitleTools.byRecency(library.comics)) }
        }
        .sheet(isPresented: $showShelfManager) {
            ShelfManagerView().environmentObject(library)
        }
        .fullScreenCover(item: $route) { r in
            switch r {
            case .reader(let entry):
                ReaderHost(entry: entry)
            case .settings:
                SettingsView()
            case .browser:
                BrowserView()
            case .discover:
                DiscoverView(onFind: { comic in
                                 BrowserModel.shared.searchHome(comic.searchTerm)
                                 route = .browser
                             },
                             onOpen: { url in
                                 BrowserModel.shared.open(url)
                                 route = .browser
                             })
            }
        }
    }

    // MARK: Organising

    private func cell(_ entry: ComicEntry) -> some View {
        ComicCell(entry: entry, organizing: organizing, selected: selection.contains(entry.id), ledge: shelf != nil)
            .onTapGesture {
                draggingID = nil
                dragActive = false
                if organizing {
                    if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
                } else {
                    route = .reader(entry)
                }
            }
            .contextMenu {
                if !organizing { menu(for: entry) }
            }
            .modifier(ReorderModifier(id: entry.id, dragging: $draggingID, active: $dragActive, state: dragState,
                                    canStack: shelf == nil && search.trimmingCharacters(in: .whitespaces).isEmpty,
                                    onOver: { dragged, target in reorder(dragged, onto: target) },
                                    onStack: { dragged, target in stack(dragged, onto: target) }))
    }

    private func reorder(_ dragged: UUID, onto target: UUID) {
        if settings.librarySort != .custom {
            // Freeze what is on screen as "my order", then move the comic within it.
            library.applyOrder(sorted(library.comics, by: settings.librarySort).map { $0.id })
            settings.librarySort = .custom
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            library.moveComic(dragged, onto: target)
        }
    }


    private func previewComics(for req: ShelfNameRequest) -> [ComicEntry] {
        if let old = req.renaming { return library.comics.filter { $0.shelf == old } }
        return library.comics.filter { req.moving.contains($0.id) }
    }

    private func commit(_ req: ShelfNameRequest, _ name: String) {
        if let old = req.renaming {
            library.renameShelf(old, to: name)
            if shelf == old { shelf = library.shelves.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) ?? old }
        } else if let made = library.addShelf(name), !req.moving.isEmpty {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { library.move(req.moving, toShelf: made) }
            if organizing { endOrganizing() }
        }
    }

    /// The naming sheet, with the series of the comics going in as suggestions.
    private func request(renaming: String?, moving: Set<UUID>) -> ShelfNameRequest {
        let titles = library.comics.filter { moving.contains($0.id) }.map { $0.title }
        var suggestions = TitleTools.profile(from: titles).prefix(3).map { $0.name }
        let series = suggestions.first
        for generic in ["Favorites", "To Read", "Finished", "Event Crossovers"] { suggestions.append(generic) }
        var seen = Set<String>()
        suggestions = suggestions.filter { n in
            let k = n.lowercased()
            return !n.isEmpty && !library.shelves.contains { $0.lowercased() == k } && seen.insert(k).inserted
        }
        let initial = renaming ?? (series.flatMap { s in library.shelves.contains { $0.lowercased() == s.lowercased() } ? nil : s } ?? "")
        return ShelfNameRequest(renaming: renaming, moving: moving, initial: initial, suggestions: Array(suggestions.prefix(6)))
    }

    private func newShelf(moving ids: Set<UUID>) {
        nameRequest = request(renaming: nil, moving: ids)
    }

    /// One comic held over another: both go onto a new shelf, and you name it.
    private func stack(_ dragged: UUID, onto target: UUID) {
        draggingID = nil
        dragActive = false
        newShelf(moving: [dragged, target])
    }

    private func endOrganizing() {
        organizing = false
        selection = []
    }

    private func folderCell(_ name: String) -> some View {
        ShelfFolderCell(name: name, comics: library.comics.filter { $0.shelf == name }, highlighted: dropHover == name)
            .onTapGesture {
                draggingID = nil
                dragActive = false
                withAnimation(.snappy) { shelf = name }
            }
            .onDrop(of: [.text], delegate: ShelfDropDelegate(name: name, dragging: $draggingID, active: $dragActive, hover: $dropHover, key: name) { id, name in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { library.move([id], toShelf: name) }
            })
            .contextMenu {
                Button { nameRequest = request(renaming: name, moving: []) } label: { Label("Rename Shelf", systemImage: "pencil") }
                Button { showShelfManager = true } label: { Label("Edit & Reorder Shelves", systemImage: "arrow.up.arrow.down") }
                Button(role: .destructive) {
                    shelfToDelete = name
                    showDeleteShelf = true
                } label: { Label("Delete Shelf", systemImage: "trash") }
            }
    }

    /// Inside a shelf: a way back (comics dropped on it leave the shelf), the name, and a rename button.
    private func shelfHeader(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { withAnimation(.snappy) { shelf = nil } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                        Text("Library").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(dropHover == "" ? Theme.accent.opacity(0.35) : Theme.card2, in: Capsule())
                }
                .buttonStyle(.plain)
                .onDrop(of: [.text], delegate: ShelfDropDelegate(name: nil, dragging: $draggingID, active: $dragActive, hover: $dropHover, key: "") { id, name in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { library.move([id], toShelf: name) }
                })
                Spacer()
            }
            HStack(spacing: 10) {
                Text(name)
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Button { nameRequest = request(renaming: name, moving: []) } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30)
                        .background(Theme.card2, in: Circle())
                }
                .accessibilityLabel("Rename Shelf")
                Spacer()
            }
            .frame(minHeight: 44)
            .overlay {
                // While a comic is being dragged this becomes a big "take it off the shelf" target.
                if dragActive && draggingID != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.up")
                        Text("Drop here to take it off this shelf").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(dropHover == "" ? Theme.accent.opacity(0.35) : Theme.card2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                    .onDrop(of: [.text], delegate: ShelfDropDelegate(name: nil, dragging: $draggingID, active: $dragActive, hover: $dropHover, key: "") { id, name in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { library.move([id], toShelf: name) }
                    })
                }
            }
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
            if settings.showDiscover && !organizing {
                Button { route = .discover } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("Discover").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.card2, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Discover new comics")
            }
            if organizing {
                Button(selection.count == visible.count && !selection.isEmpty ? "Select none" : "Select all") {
                    if selection.count == visible.count { selection = [] } else { selection = Set(visible.map { $0.id }) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.trailing, 6)
                Button("Done") { endOrganizing() }
                    .buttonStyle(YellowButtonStyle(compact: true))
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
                Button { library.markRead(ids: selection, true) } label: { Label("Mark as Read", systemImage: "checkmark.circle") }
                Button { library.markRead(ids: selection, false) } label: { Label("Mark as Unread", systemImage: "arrow.uturn.backward") }
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
        Button { library.move(ids, toShelf: nil) } label: { Label("No Shelf", systemImage: "tray") }
        ForEach(library.shelves, id: \.self) { name in
            Button { library.move(ids, toShelf: name) } label: { Label(name, systemImage: "folder") }
        }
        Button { newShelf(moving: ids) } label: { Label("New Shelf…", systemImage: "plus") }
    }

    // MARK: Pieces

    private var showSearch: Bool { return library.comics.count > 6 }

    /// On the wide layout the Duo's status widget is a short capsule in the corner (the layout starts below the
    /// system's safe area), so only the header needs to avoid it. On the narrow layout it is a tall box.
    private var wideStatus: Bool { return topInset > 20 }          // the system already reserves the status area
    private var headerTop: CGFloat { return wideStatus ? (landscape ? 22 : 8) : 30 }
    private var cameraPad: CGFloat { return wideStatus ? 0 : Theme.cameraWidth }

    private var header: some View {
        ZStack {
            ComicTitle(text: "Library")
            HStack(spacing: 10) {
                Button { route = .settings } label: { CircleIcon(systemName: "gearshape.fill") }
                    .accessibilityLabel("Settings")
                addMenu
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, headerTop)      // wide screen: the camera widget is a short capsule, so the title can sit level with it
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
            Text("Your Library Is Empty")
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text("Tap the + at the top and choose files, a whole folder, or the ad-free browser. PanelSnap reads CBZ, CBR, CB7, PDF and EPUB.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.horizontal, 28)
            Button { Task { await library.scanFolder() } } label: {
                Label("Scan Comics Folder", systemImage: "arrow.clockwise")
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
                Text("Some Files Couldn't Be Added")
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
        let perPage = (wideStatus && landscape) ? 2 : 1
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
        } label: { Label("Move to Shelf", systemImage: "folder") }
        if entry.shelf != nil {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { library.move([entry.id], toShelf: nil) }
            } label: { Label("Remove from Shelf", systemImage: "tray.and.arrow.up") }
        }
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

/// Lets a cell be picked up with a long press. The other covers slide out of the way as it moves over their edges,
/// like rearranging apps on the Home Screen; resting on the middle of one for a moment makes a shelf from the two.
private struct ReorderModifier: ViewModifier {
    let id: UUID
    @Binding var dragging: UUID?
    @Binding var active: Bool
    @ObservedObject var state: DragState
    let canStack: Bool
    let onOver: (UUID, UUID) -> Void
    let onStack: (UUID, UUID) -> Void
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        let stacking = state.stackTarget == id
        content
            .opacity(dragging == id && active ? 0.35 : 1)
            .background(GeometryReader { g in Color.clear.preference(key: CellSizeKey.self, value: g.size) })
            .onPreferenceChange(CellSizeKey.self) { size = $0 }
            .overlay {
                if stacking {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 3)
                        .frame(height: size.width * 1.5)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(stacking ? 1.06 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: stacking)
            .onDrag {
                dragging = id
                return NSItemProvider(object: id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: CoverDropDelegate(id: id, dragging: $dragging, active: $active, state: state,
                                                            size: size, canStack: canStack, onOver: onOver, onStack: onStack))
    }
}

private struct CellSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct CoverDropDelegate: DropDelegate {
    let id: UUID
    @Binding var dragging: UUID?
    @Binding var active: Bool
    let state: DragState
    let size: CGSize
    let canStack: Bool
    let onOver: (UUID, UUID) -> Void
    let onStack: (UUID, UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool { return dragging != nil }

    /// Middle of the cover: wait to see if this becomes a shelf. Edges: move out of the way.
    private func handle(_ info: DropInfo) {
        guard let d = dragging else { return }
        active = true
        if d == id { state.clear(); return }
        let coverH = size.width * 1.5
        let p = info.location
        if !canStack { state.clear(); onOver(d, id); return }          // inside a shelf: just slide the covers apart
        let inMiddle = size.width > 0
            && p.x > size.width * 0.22 && p.x < size.width * 0.78
            && p.y > coverH * 0.2 && p.y < coverH * 0.8
        state.over(id, inMiddle: inMiddle) { onOver(d, id) }
    }

    func dropEntered(info: DropInfo) { handle(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        handle(info)
        return DropProposal(operation: .move)       // a move, so no green plus
    }
    func dropExited(info: DropInfo) { state.clear() }
    func performDrop(info: DropInfo) -> Bool {
        let stacked = state.stackTarget == id
        state.clear()
        if stacked, let d = dragging, d != id {
            onStack(d, id)
        } else {
            dragging = nil
            active = false
        }
        return true
    }
}

private struct GridFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Dropping on empty space: past the bottom of the comics means "last", above the top means "first".
private struct ListDropDelegate: DropDelegate {
    @Binding var dragging: UUID?
    @Binding var active: Bool
    let gridFrame: () -> CGRect
    let first: UUID?
    let last: UUID?
    let place: (UUID, UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool { return dragging != nil }
    func dropUpdated(info: DropInfo) -> DropProposal? { return DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil; active = false }
        guard let id = dragging else { return false }
        let f = gridFrame()
        if info.location.y > f.maxY, let l = last, l != id { place(id, l) }
        else if info.location.y < f.minY, let fi = first, fi != id { place(id, fi) }
        return true
    }
}

/// A shelf takes the comic being dragged (the Library button takes it off its shelf).
private struct ShelfDropDelegate: DropDelegate {
    let name: String?
    @Binding var dragging: UUID?
    @Binding var active: Bool
    @Binding var hover: String?
    let key: String
    let move: (UUID, String?) -> Void

    func validateDrop(info: DropInfo) -> Bool { return dragging != nil }
    func dropEntered(info: DropInfo) { hover = key }
    func dropExited(info: DropInfo) { if hover == key { hover = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { return DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        hover = nil
        guard let id = dragging else { return false }
        move(id, name)
        dragging = nil
        active = false
        return true
    }
}

struct CoverView: View {
    @EnvironmentObject var library: LibraryStore
    let entry: ComicEntry
    var onShelf = false        // standing on a plank: crisp comic corners, shadow falls back onto the wall
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
        .clipShape(RoundedRectangle(cornerRadius: onShelf ? 3 : 10, style: .continuous))
        .overlay { if onShelf { RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.black.opacity(0.55), lineWidth: 1) } }
        .shadow(color: .black.opacity(onShelf ? 0.35 : 0.22), radius: onShelf ? 4 : 7, x: onShelf ? 2 : 0, y: onShelf ? -1 : 4)
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
    var ledge = false          // the plank: only inside a shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)          // always exactly cover-shaped, so every plank lines up
                .overlay {
                    GeometryReader { g in
                        CoverView(entry: entry, onShelf: ledge).frame(width: g.size.width, height: g.size.height)
                    }
                }
                .overlay {
                    if organizing && selected {
                        RoundedRectangle(cornerRadius: ledge ? 3 : 10, style: .continuous).strokeBorder(Theme.accent, lineWidth: 3)
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
                .background(alignment: .bottom) {
                    if ledge { ContactShadow().frame(height: 10).padding(.horizontal, 4).offset(y: 4) }
                }
            if ledge { Color.clear.frame(height: shelfLedgeRoom - 8) }   // room for the plank so titles sit below it
            Text(entry.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(entry.format.label) · \(entry.pageCount) pages")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
        }
        .background(alignment: .top) { if ledge { ShelfBackdrop() } }
        .contentShape(Rectangle())
    }
}


/// Reorder, rename and delete shelves in one place.
struct ShelfManagerView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: String?
    @State private var text = ""
    @State private var showRename = false
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(library.shelves, id: \.self) { name in
                    Button {
                        renaming = name; text = name; creating = false; showRename = true
                    } label: {
                        HStack {
                            Text(name).foregroundStyle(.white)
                            Spacer()
                            Text("\(library.comics.filter { $0.shelf == name }.count)").foregroundStyle(Theme.secondary)
                        }
                    }
                    .listRowBackground(Theme.card)
                }
                .onMove { library.moveShelves(from: $0, to: $1) }
                .onDelete { offsets in
                    for i in offsets.sorted(by: >) where i < library.shelves.count { library.deleteShelf(library.shelves[i]) }
                }
                Section {
                    Button { renaming = nil; text = ""; creating = true; showRename = true } label: {
                        Label("New Shelf", systemImage: "plus").foregroundStyle(Theme.accent)
                    }
                    .listRowBackground(Theme.card)
                } footer: {
                    Text("Drag to reorder. Tap a shelf to rename it. Deleting a shelf keeps its comics in the library.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Shelves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert(creating ? "New Shelf" : "Rename Shelf", isPresented: $showRename) {
                TextField("Shelf name", text: $text)
                Button(creating ? "Create" : "Save") {
                    if creating { _ = library.addShelf(text) }
                    else if let old = renaming { library.renameShelf(old, to: text) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
    }
}
