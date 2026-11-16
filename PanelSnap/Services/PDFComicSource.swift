import Foundation
import PDFKit
import UIKit

/// PDF comics. Pages are drawn on demand at the size we ask for.
final class PDFComicSource: ComicSource {
    private let document: PDFDocument
    private let lock = NSLock()

    var pageCount: Int { return document.pageCount }

    init(url: URL) throws {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            throw ComicError.unreadable
        }
        self.document = doc
    }

    func metadataXML() -> Data? { return nil }

    func pageData(at index: Int) throws -> Data {
        throw ComicError.unsupported("PDF pages are drawn directly.")
    }

    func pageImage(at index: Int, maxPixel: CGFloat) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let page = document.page(at: index) else { return nil }
        let box = page.bounds(for: .mediaBox)
        var w = box.width
        var h = box.height
        if page.rotation % 180 != 0 {
            swap(&w, &h)
        }
        if w < 1 || h < 1 { return nil }
        let scale = maxPixel / max(w, h)
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let image = page.thumbnail(of: size, for: .mediaBox)
        return image.cgImage
    }
}
