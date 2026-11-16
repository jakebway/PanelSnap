#if canImport(Unrar)
import Foundation
import Unrar

/// CBR: a RAR full of page images.
final class RarComicSource: ComicSource {
    private let archive: Archive
    private let pages: [Entry]
    private let infoEntry: Entry?
    private let lock = NSLock()

    var pageCount: Int { return pages.count }

    init(url: URL) throws {
        let a: Archive
        let all: [Entry]
        do {
            a = try Archive(fileURL: url)
            all = try a.entries()
        } catch {
            throw ComicError.unreadable
        }
        var images: [Entry] = []
        var info: Entry?
        for e in all {
            if e.directory { continue }
            if ArchiveNames.isComicInfo(e.fileName) {
                info = e
            } else if ArchiveNames.isPage(e.fileName) {
                images.append(e)
            }
        }
        images.sort { ArchiveNames.sortKey($0.fileName, $1.fileName) }
        if images.isEmpty { throw ComicError.noPages }
        self.archive = a
        self.pages = images
        self.infoEntry = info
    }

    func metadataXML() -> Data? {
        guard let e = infoEntry else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return try? archive.extract(e)
    }

    func pageData(at index: Int) throws -> Data {
        guard index >= 0 && index < pages.count else { throw ComicError.noPages }
        lock.lock()
        defer { lock.unlock() }
        return try archive.extract(pages[index])
    }
}
#endif
