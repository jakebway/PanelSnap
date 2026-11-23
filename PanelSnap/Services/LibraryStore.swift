import Foundation
import SwiftUI
import UIKit
import ImageIO

@MainActor
final class LibraryStore: ObservableObject {

    @Published private(set) var comics: [ComicEntry] = []
    /// Shelf names, in the order they are shown. Comics point at a shelf by name.
    @Published private(set) var shelves: [String] = UserDefaults.standard.stringArray(forKey: "shelves") ?? []
    @Published var isImporting = false
    @Published var importStatus: String?
    @Published var errorMessage: String?

    private var saveWork: Task<Void, Never>?

    init() {
        load()
    }

    // MARK: persistence

    private func load() {
        guard let data = try? Data(contentsOf: Paths.libraryFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([ComicEntry].self, from: data) {
            // Drop entries whose file vanished.
            comics = list.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
            // A shelf that comics point at must exist, even if the list of shelves was lost.
            for name in comics.compactMap({ $0.shelf }) where !shelves.contains(name) { shelves.append(name) }
        }
    }

    private func saveShelves() {
        UserDefaults.standard.set(shelves, forKey: "shelves")
    }

    /// Writes the library right now (used when the app goes to the background).
    func flush() {
        saveWork?.cancel()
        saveWork = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(comics) {
            try? data.write(to: Paths.libraryFile, options: .atomic)
        }
    }

    private func save() {
        let snapshot = comics
        saveWork?.cancel()
        saveWork = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: Paths.libraryFile, options: .atomic)
            }
        }
    }

    func fileURL(for entry: ComicEntry) -> URL {
        return Paths.comics.appendingPathComponent(entry.fileName)
    }

    func coverURL(for entry: ComicEntry) -> URL {
        return Paths.covers.appendingPathComponent(entry.id.uuidString + ".jpg")
    }

    func entry(id: UUID) -> ComicEntry? {
        return comics.first(where: { $0.id == id })
    }

    // MARK: import

    nonisolated static let comicExtensions: Set<String> = ["cbz", "cbr", "cb7", "cbt", "zip", "rar", "7z", "pdf", "epub"]

    /// The path of a file relative to the Comics folder, or nil if the file lives somewhere else.
    nonisolated static func relativeName(_ url: URL) -> String? {
        let base = Paths.comics.resolvingSymlinksInPath().path + "/"
        let p = url.resolvingSymlinksInPath().path
        return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : nil
    }

    private var failedScan = Set<String>()

    /// Forgets comics whose file was deleted from Files behind our back.
    func pruneMissing() {
        let before = comics.count
        comics.removeAll { !FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
        if comics.count != before {
            Console.log("library: removed \(before - comics.count) comic(s) whose file is gone")
            save()
        }
    }

    /// Finds comics that were dropped straight into Files > PanelSnap > Comics and adds them in place (no copy).
    func scanFolder() async {
        if isImporting { return }
        pruneMissing()
        let known = Set(comics.map { $0.fileName })
        let skip = failedScan
        let folder = Paths.comics
        let found: [URL] = await Task.detached(priority: .utility) {
            var out: [URL] = []
            let fm = FileManager.default
            guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return out }
            while let u = en.nextObject() as? URL {
                guard LibraryStore.comicExtensions.contains(u.pathExtension.lowercased()),
                      let rel = LibraryStore.relativeName(u),
                      !known.contains(rel), !skip.contains(rel) else { continue }
                out.append(u)
            }
            return out
        }.value
        Console.log("scan Comics folder: \(found.count) new file(s)")
        if found.isEmpty { await optimizeAll(); return }
        await importFiles(found)
    }

    /// Adds every comic found inside a folder the person picked (including sub-folders).
    func importFolder(_ folder: URL, shelf: String? = nil) async {
        let scoped = folder.startAccessingSecurityScopedResource()
        Console.log("import: folder \(folder.lastPathComponent) scoped=\(scoped)")
        var found: [URL] = []
        if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let u as URL in walker where LibraryStore.comicExtensions.contains(u.pathExtension.lowercased()) {
                found.append(u)
            }
        }
        found.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        Console.log("import: found \(found.count) comic(s) in the folder")
        if found.isEmpty {
            errorMessage = "No comics (CBZ, CBR, CB7, PDF or EPUB) were found in that folder."
        } else {
            await importFiles(found, shelf: shelf)
        }
        if scoped { folder.stopAccessingSecurityScopedResource() }
    }

    @discardableResult
    func importFiles(_ urls: [URL], shelf: String? = nil) async -> Int64 {
        if urls.isEmpty { return 0 }
        isImporting = true
        var added = 0
        var failed: [String] = []
        Console.log("import: \(urls.count) file(s) requested")
        for (i, url) in urls.enumerated() {
            importStatus = "Adding \(i + 1) of \(urls.count)…"
            let rel = LibraryStore.relativeName(url)
            if let rel = rel, comics.contains(where: { $0.fileName == rel }) {
                Console.log("import: \(url.lastPathComponent) is already in the library")
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            // Same name and same size as something already in the library: it is the same comic, skip it.
            if rel == nil, isDuplicate(url) {
                Console.log("import: \(url.lastPathComponent) is already in the library (same name and size)")
                if scoped { url.stopAccessingSecurityScopedResource() }
                continue
            }
            Console.log("import: \(url.lastPathComponent) scoped=\(scoped) inPlace=\(rel != nil)")
            let result = await Task.detached(priority: .userInitiated) {
                return LibraryStore.importOne(url: url, inPlaceName: rel)
            }.value
            if scoped { url.stopAccessingSecurityScopedResource() }
            switch result {
            case .success(var entry):
                entry.shelf = shelf
                comics.insert(entry, at: 0)
                added += 1
                Console.log("import: added \(entry.title) (\(entry.pageCount) pages)")
            case .failure(let err):
                failed.append("\(url.lastPathComponent): \(err.localizedDescription)")
                if let rel = rel { failedScan.insert(rel) }
                Console.log("import: ERROR \(url.lastPathComponent): \(err)")
            }
        }
        save()
        isImporting = false
        importStatus = nil
        Console.log("import: done, added \(added), failed \(failed.count)")
        if !failed.isEmpty {
            errorMessage = failed.joined(separator: "\n")
        }
        return await optimizeAll()
    }

    private func fileSize(_ url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey])
        return v?.fileSize.map { Int64($0) }
    }

    private func isDuplicate(_ url: URL) -> Bool {
        guard let size = fileSize(url) else { return false }
        for c in comics where c.originalName == url.lastPathComponent {
            if fileSize(fileURL(for: c)) == size { return true }
        }
        return false
    }

    nonisolated private static func uniqueDestination(for name: String) -> URL {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = Paths.comics.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = Paths.comics.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }

    /// Runs off the main thread: copies the file (unless it is already in Comics), reads page count, makes a cover, reads the ComicInfo.
    nonisolated private static func importOne(url: URL, inPlaceName: String?) -> Result<ComicEntry, Error> {
        let fm = FileManager.default
        let t0 = Date()
        let id = UUID()
        let storedName: String
        let dest: URL
        var copied = false
        if let name = inPlaceName {
            storedName = name
            dest = url
        } else {
            dest = uniqueDestination(for: url.lastPathComponent)
            storedName = dest.lastPathComponent
            do {
                // The picker hands us a private temporary copy, so just move it into place (instant, no double copy).
                if url.path.hasPrefix(NSTemporaryDirectory()) || url.path.contains("/tmp/") || url.path.contains("/Inbox/") {
                    do { try fm.moveItem(at: url, to: dest) } catch { try fm.copyItem(at: url, to: dest) }
                } else {
                    try fm.copyItem(at: url, to: dest)
                }
                copied = true
                Console.log("import: copied \(url.lastPathComponent) to Comics in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            } catch {
                return .failure(error)
            }
        }

        let source: ComicSource
        do {
            source = try ComicOpener.open(url: dest)
        } catch {
            if copied { try? fm.removeItem(at: dest) }
            return .failure(error)
        }

        // Identity: embedded info first, then the file name.
        var identity = FilenameParser.parse(url.lastPathComponent)
        if let xml = source.metadataXML(), let info = ComicInfoParser.parse(xml) {
            if let s = info.series, !s.isEmpty { identity.series = s }
            if let n = info.issue, !n.isEmpty { identity.issue = n }
            if let t = info.title, !t.isEmpty { identity.title = t }
            identity.isManga = info.isManga
        }

        // Cover
        if let cover = source.pageImage(at: 0, maxPixel: 560) {
            let ui = UIImage(cgImage: cover)
            if let jpeg = ui.jpegData(compressionQuality: 0.82) {
                let coverURL = Paths.covers.appendingPathComponent(id.uuidString + ".jpg")
                try? jpeg.write(to: coverURL, options: .atomic)
            }
        }

        var title = identity.series ?? (url.deletingPathExtension().lastPathComponent)
        if let n = identity.issue, !n.isEmpty { title += " #" + n }

        let entry = ComicEntry(
            id: id,
            fileName: storedName,
            originalName: url.lastPathComponent,
            title: title,
            series: identity.series,
            issue: identity.issue,
            format: ComicOpener.detectFormat(url: dest),
            pageCount: source.pageCount,
            addedAt: Date(),
            lastOpenedAt: nil,
            lastPage: 0,
            lastPanel: 0,
            finished: false,
            isManga: identity.isManga
        )
        return .success(entry)
    }

    // MARK: optimize

    private var optimizing = false
    private var optimizeFailed = Set<UUID>()

    /// Converts every comic that isn't in the library format yet (HEIC pages at screen size), deleting the old file as it goes.
    /// Returns the bytes saved.
    @discardableResult
    func optimizeAll() async -> Int64 {
        guard ComicCompressor.enabled, !optimizing else { return 0 }
        optimizing = true
        defer { optimizing = false }
        var saved: Int64 = 0
        while ComicCompressor.enabled, let e = comics.first(where: { $0.optimized != true && !optimizeFailed.contains($0.id) }) {
            if let s = await optimize(e) { saved += s } else { optimizeFailed.insert(e.id) }
        }
        return saved
    }

    private func optimize(_ entry: ComicEntry) async -> Int64? {
        let src = fileURL(for: entry)
        let name = entry.title
        let target = ComicCompressor.targetPixel
        isImporting = true
        importStatus = "Optimizing \(name)…"
        defer { isImporting = false }
        let result: Result<ComicCompressor.Outcome, Error> = await Task.detached(priority: .utility) {
            do {
                return .success(try ComicCompressor.compress(src, maxPixel: target) { fraction in
                    Task { @MainActor [weak self] in self?.importStatus = "Optimizing \(name)… \(Int(fraction * 100))%" }
                })
            } catch { return .failure(error) }
        }.value
        switch result {
        case .failure(let error):
            importStatus = nil
            Console.log("optimize: ERROR \(name): \(error)")
            return nil
        case .success(let outcome):
            guard outcome.worthIt else {
                markOptimized(entry.id)        // already small; don't try again
                importStatus = nil
                return 0
            }
            let fm = FileManager.default
            do {
                let folder = src.deletingLastPathComponent()
                let base = src.deletingPathExtension().lastPathComponent
                var finalURL = folder.appendingPathComponent(base + ".cbz")
                if src.pathExtension.lowercased() == "cbz" {
                    _ = try fm.replaceItemAt(src, withItemAt: outcome.url)
                    finalURL = src
                } else {
                    var n = 2
                    while fm.fileExists(atPath: finalURL.path) { finalURL = folder.appendingPathComponent("\(base) \(n).cbz"); n += 1 }
                    try fm.moveItem(at: outcome.url, to: finalURL)
                    try? fm.removeItem(at: src)
                }
                if let i = comics.firstIndex(where: { $0.id == entry.id }), let rel = LibraryStore.relativeName(finalURL) {
                    comics[i].fileName = rel
                    comics[i].format = .cbz
                    comics[i].pageCount = outcome.pageCount
                    comics[i].optimized = true
                    save()
                }
                try? fm.removeItem(at: PanelCache.fileURL(for: entry.id))
                importStatus = nil
                Console.log("optimize: \(name) \(outcome.before) -> \(outcome.after)")
                return outcome.before - outcome.after
            } catch {
                try? fm.removeItem(at: outcome.url)
                importStatus = nil
                Console.log("optimize: replace failed \(name): \(error)")
                return nil
            }
        }
    }

    private func markOptimized(_ id: UUID) {
        if let i = comics.firstIndex(where: { $0.id == id }) { comics[i].optimized = true; save() }
    }

    // MARK: edits

    func recordProgress(id: UUID, page: Int, panel: Int, finished: Bool) {
        guard let i = comics.firstIndex(where: { $0.id == id }) else { return }
        comics[i].lastPage = page
        comics[i].lastPanel = panel
        comics[i].finished = finished
        comics[i].lastOpenedAt = Date()
        save()
    }

    func setManga(id: UUID, _ value: Bool) {
        guard let i = comics.firstIndex(where: { $0.id == id }) else { return }
        comics[i].isManga = value
        save()
    }

    func markRead(id: UUID, _ read: Bool) {
        guard let i = comics.firstIndex(where: { $0.id == id }) else { return }
        comics[i].finished = read
        if !read {
            comics[i].lastPage = 0
            comics[i].lastPanel = 0
        }
        save()
    }

    func markRead(ids: Set<UUID>, _ read: Bool) {
        for i in comics.indices where ids.contains(comics[i].id) {
            comics[i].finished = read
            if !read {
                comics[i].lastPage = 0
                comics[i].lastPanel = 0
            }
        }
        save()
    }

    func delete(_ entry: ComicEntry) {
        delete(ids: [entry.id])
    }

    func delete(ids: Set<UUID>) {
        let fm = FileManager.default
        for entry in comics where ids.contains(entry.id) {
            try? fm.removeItem(at: fileURL(for: entry))
            try? fm.removeItem(at: coverURL(for: entry))
            try? fm.removeItem(at: PanelCache.fileURL(for: entry.id))
            try? fm.removeItem(at: CompanionCache.fileURL(for: entry.id))
        }
        comics.removeAll(where: { ids.contains($0.id) })
        save()
    }

    // MARK: organising

    func rename(id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = comics.firstIndex(where: { $0.id == id }) else { return }
        comics[i].title = t
        save()
    }

    /// Creates a shelf (names are unique, ignoring case). Returns the name actually used.
    @discardableResult
    func addShelf(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return nil }
        if let existing = shelves.first(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { return existing }
        shelves.append(n)
        saveShelves()
        return n
    }

    func renameShelf(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = shelves.firstIndex(of: old) else { return }
        if n != old, shelves.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { return }
        shelves[i] = n
        for j in comics.indices where comics[j].shelf == old { comics[j].shelf = n }
        saveShelves()
        save()
    }

    /// Removes the shelf only; its comics stay in the library, just off any shelf.
    func deleteShelf(_ name: String) {
        shelves.removeAll { $0 == name }
        for j in comics.indices where comics[j].shelf == name { comics[j].shelf = nil }
        saveShelves()
        save()
    }

    func move(_ ids: Set<UUID>, toShelf name: String?) {
        for i in comics.indices where ids.contains(comics[i].id) { comics[i].shelf = name }
        save()
    }

    /// Makes the stored order match `ids` (used the first time someone drags a comic while another sort is active).
    func applyOrder(_ ids: [UUID]) {
        let byID = Dictionary(uniqueKeysWithValues: comics.map { ($0.id, $0) })
        let ordered = ids.compactMap { byID[$0] }
        if ordered.count == comics.count {
            comics = ordered
            save()
        }
    }

    /// Drag and drop: put `id` where `target` is (the "My order" sort).
    func moveComic(_ id: UUID, onto target: UUID) {
        guard id != target,
              let from = comics.firstIndex(where: { $0.id == id }),
              let to = comics.firstIndex(where: { $0.id == target }) else { return }
        let item = comics.remove(at: from)
        let dest = comics.firstIndex(where: { $0.id == target }) ?? to
        comics.insert(item, at: from < to ? dest + 1 : dest)
        save()
    }
}

/// Cover thumbnails: decoded off the main thread, shrunk, and kept in a size-limited memory cache.
final class CoverCache {
    static let shared = CoverCache()
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    /// Instant lookup: only what is already in memory.
    func cached(_ url: URL) -> UIImage? {
        return cache.object(forKey: url.path as NSString)
    }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        let img: UIImage? = await Task.detached(priority: .utility) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 520
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let img = img {
            cache.setObject(img, forKey: url.path as NSString, cost: Int(img.size.width * img.size.height * 4))
        }
        return img
    }

    /// Synchronous version for one-off places (the Companion header).
    func image(for url: URL) -> UIImage? {
        if let hit = cached(url) { return hit }
        guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: url.path as NSString, cost: Int(img.size.width * img.size.height * 4))
        return img
    }
}
