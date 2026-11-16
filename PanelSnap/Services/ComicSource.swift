import Foundation
import CoreGraphics
import ImageIO

/// A comic file we can read pages from (CBZ, CBR, CB7, PDF, EPUB ...).
protocol ComicSource: AnyObject {
    var pageCount: Int { get }
    /// The embedded ComicInfo.xml, if any.
    func metadataXML() -> Data?
    /// Raw bytes of one page image (archives only).
    func pageData(at index: Int) throws -> Data
    /// A decoded page, shrunk so its longest side is at most `maxPixel`.
    func pageImage(at index: Int, maxPixel: CGFloat) -> CGImage?
}

extension ComicSource {
    func pageImage(at index: Int, maxPixel: CGFloat) -> CGImage? {
        guard let data = try? pageData(at: index) else { return nil }
        return ImageDecoder.decode(data, maxPixel: maxPixel)
    }
}

enum ComicError: LocalizedError {
    case unreadable
    case noPages
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "This file could not be opened."
        case .noPages: return "No pages were found inside this file."
        case .unsupported(let what): return what
        }
    }
}

enum ImageDecoder {
    static func decode(_ data: Data, maxPixel: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var longest: CGFloat = maxPixel
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue {
            longest = min(maxPixel, CGFloat(max(w, h)))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longest
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}

/// Helpers shared by the archive-based sources.
enum ArchiveNames {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "tif", "tiff", "heic", "heif", "avif", "jp2"]

    static func isPage(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("__macosx/") { return false }
        let last = (lower as NSString).lastPathComponent
        if last.hasPrefix(".") || last.hasPrefix("._") { return false }
        let ext = (last as NSString).pathExtension
        return imageExtensions.contains(ext)
    }

    static func isComicInfo(_ path: String) -> Bool {
        let last = ((path as NSString).lastPathComponent).lowercased()
        return last == "comicinfo.xml"
    }

    /// Natural ordering: page2 comes before page10.
    static func sortKey(_ a: String, _ b: String) -> Bool {
        return a.localizedStandardCompare(b) == .orderedAscending
    }
}

/// Figures out what a file really is by peeking at its first bytes (so a mislabelled .cbz still opens).
enum ComicOpener {

    static func detectFormat(url: URL) -> ComicFormat {
        let ext = ComicFormat.from(fileExtension: url.pathExtension)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ext }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8)) ?? Data()
        let bytes = [UInt8](head)
        if bytes.count >= 4 {
            if bytes[0] == 0x50 && bytes[1] == 0x4B {   // "PK"
                return ext == .epub ? .epub : .cbz
            }
            if bytes[0] == 0x52 && bytes[1] == 0x61 && bytes[2] == 0x72 && bytes[3] == 0x21 {   // "Rar!"
                return .cbr
            }
            if bytes[0] == 0x37 && bytes[1] == 0x7A && bytes[2] == 0xBC && bytes[3] == 0xAF {   // "7z"
                return .cb7
            }
            if bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46 {   // "%PDF"
                return .pdf
            }
        }
        return ext
    }

    static func open(url: URL) throws -> ComicSource {
        let format = detectFormat(url: url)
        switch format {
        case .cbz, .epub:
            return try ZipComicSource(url: url)
        case .cbr:
            #if canImport(Unrar)
            return try RarComicSource(url: url)
            #else
            throw ComicError.unsupported("CBR/RAR files need the full build of PanelSnap. Convert it to CBZ, or run the build again.")
            #endif
        case .cb7:
            #if canImport(SevenZip)
            return try SevenZipComicSource(url: url)
            #else
            throw ComicError.unsupported("CB7/7z files need the full build of PanelSnap. Convert it to CBZ, or run the build again.")
            #endif
        case .pdf:
            return try PDFComicSource(url: url)
        case .other:
            throw ComicError.unsupported("PanelSnap can't read this kind of file. Try CBZ, CBR, CB7, PDF or EPUB.")
        }
    }
}
