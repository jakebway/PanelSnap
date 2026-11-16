import Foundation
import ZIPFoundation

/// CBZ (and EPUB comics): a ZIP full of page images.
final class ZipComicSource: ComicSource {
    private let archive: Archive
    private let pages: [Entry]
    private let infoEntry: Entry?
    private let lock = NSLock()

    var pageCount: Int { return pages.count }

    init(url: URL) throws {
        let a: Archive
        do {
            a = try Archive(url: url, accessMode: .read)
        } catch {
            throw ComicError.unreadable
        }
        var images: [Entry] = []
        var info: Entry?
        for entry in a {
            if entry.type != .file { continue }
            let path = entry.path
            if ArchiveNames.isComicInfo(path) {
                info = entry
            } else if ArchiveNames.isPage(path) {
                images.append(entry)
            }
        }
        images.sort { ArchiveNames.sortKey($0.path, $1.path) }
        if images.isEmpty { throw ComicError.noPages }
        self.archive = a
        self.pages = images
        self.infoEntry = info
    }

    func metadataXML() -> Data? {
        guard let e = infoEntry else { return nil }
        return try? read(e)
    }

    func pageData(at index: Int) throws -> Data {
        guard index >= 0 && index < pages.count else { throw ComicError.noPages }
        return try read(pages[index])
    }

    private func read(_ entry: Entry) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        var data = Data()
        _ = try archive.extract(entry, skipCRC32: true) { chunk in
            data.append(chunk)
        }
        return data
    }
}
