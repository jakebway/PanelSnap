#if canImport(SevenZip)
import Foundation
import SevenZip

/// CB7: a 7-Zip archive full of page images.
final class SevenZipComicSource: ComicSource {
    private let archive: Archive
    private let pages: [Entry]
    private let infoEntry: Entry?
    private let lock = NSLock()

    var pageCount: Int { return pages.count }

    init(url: URL) throws {
        let a: Archive
        do {
            a = try Archive(fileURL: url)
        } catch {
            throw ComicError.unreadable
        }
        var images: [Entry] = []
        var info: Entry?
        for e in a.entries {
            if e.directory { continue }
            if ArchiveNames.isComicInfo(e.path) {
                info = e
            } else if ArchiveNames.isPage(e.path) {
                images.append(e)
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
        lock.lock()
        defer { lock.unlock() }
        return try? archive.extract(entry: e)
    }

    func pageData(at index: Int) throws -> Data {
        guard index >= 0 && index < pages.count else { throw ComicError.noPages }
        lock.lock()
        defer { lock.unlock() }
        return try archive.extract(entry: pages[index])
    }
}
#endif
