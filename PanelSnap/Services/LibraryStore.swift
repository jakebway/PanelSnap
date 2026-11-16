import Foundation
import SwiftUI
import UIKit

@MainActor
final class LibraryStore: ObservableObject {

    @Published private(set) var comics: [ComicEntry] = []
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

    func importFiles(_ urls: [URL]) async {
        if urls.isEmpty { return }
        isImporting = true
        var added = 0
        var failed: [String] = []
        for (i, url) in urls.enumerated() {
            importStatus = "Adding \(i + 1) of \(urls.count)…"
            let scoped = url.startAccessingSecurityScopedResource()
            let result = await Task.detached(priority: .userInitiated) {
                return LibraryStore.importOne(url: url)
            }.value
            if scoped { url.stopAccessingSecurityScopedResource() }
            switch result {
            case .success(let entry):
                comics.insert(entry, at: 0)
                added += 1
            case .failure(let err):
                failed.append("\(url.lastPathComponent): \(err.localizedDescription)")
            }
        }
        save()
        isImporting = false
        importStatus = nil
        if !failed.isEmpty {
            errorMessage = failed.joined(separator: "\n")
        }
    }

    /// Runs off the main thread: copies the file, reads page count, makes a cover, reads the ComicInfo.
    nonisolated private static func importOne(url: URL) -> Result<ComicEntry, Error> {
        let fm = FileManager.default
        let id = UUID()
        let ext = url.pathExtension.isEmpty ? "cbz" : url.pathExtension.lowercased()
        let storedName = id.uuidString + "." + ext
        let dest = Paths.comics.appendingPathComponent(storedName)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
        } catch {
            return .failure(error)
        }

        let source: ComicSource
        do {
            source = try ComicOpener.open(url: dest)
        } catch {
            try? fm.removeItem(at: dest)
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

    func delete(_ entry: ComicEntry) {
        try? FileManager.default.removeItem(at: fileURL(for: entry))
        try? FileManager.default.removeItem(at: coverURL(for: entry))
        try? FileManager.default.removeItem(at: PanelCache.fileURL(for: entry.id))
        try? FileManager.default.removeItem(at: CompanionCache.fileURL(for: entry.id))
        comics.removeAll(where: { $0.id == entry.id })
        save()
    }
}

/// Loads cover thumbnails from disk, with a small memory cache.
final class CoverCache {
    static let shared = CoverCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(for url: URL) -> UIImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}
