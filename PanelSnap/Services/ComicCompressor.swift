import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

/// How hard to squeeze: the longest side of each page and the JPEG quality.
enum CompressionLevel: String, CaseIterable, Identifiable {
    case balanced, small
    var id: String { return rawValue }
    var label: String { return self == .balanced ? "Balanced" : "Smaller" }
    var detail: String { return self == .balanced ? "Looks the same on a phone; usually 50–70% smaller" : "Slightly softer; usually 65–80% smaller" }
    var maxPixel: CGFloat { return self == .balanced ? 2200 : 1700 }
    var quality: CGFloat { return self == .balanced ? 0.72 : 0.6 }

    static var current: CompressionLevel {
        return CompressionLevel(rawValue: UserDefaults.standard.string(forKey: "compressionLevel") ?? "") ?? .balanced
    }
    static var autoDownloads: Bool {
        return UserDefaults.standard.object(forKey: "compressDownloads") as? Bool ?? true
    }
}

/// Re-saves a comic's pages as smaller JPEGs inside a fresh CBZ. Works for any format the app can open (CBZ, CBR, CB7, PDF, EPUB).
enum ComicCompressor {
    struct Outcome {
        var url: URL            // the new file (a temporary file next to nothing yet); nil savings means it was deleted
        var before: Int64
        var after: Int64
        var pageCount: Int
        var worthIt: Bool { return after < before - before / 20 }      // at least 5% smaller
    }

    private static func ext(of data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8 { return "jpg" }
        if b.count >= 4, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b.count >= 3, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "gif" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[8] == 0x57, b[9] == 0x45 { return "webp" }
        return "jpg"
    }

    private static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func fileSize(_ url: URL) -> Int64 {
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// Writes the smaller copy to a temporary file and reports the sizes. The caller decides whether to swap it in.
    static func compress(_ url: URL, level: CompressionLevel, progress: @escaping (Double) -> Void) throws -> Outcome {
        let source = try ComicOpener.open(url: url)
        let count = source.pageCount
        guard count > 0 else { throw ComicError.noPages }
        let tmp = Paths.caches.appendingPathComponent("compress-" + UUID().uuidString + ".cbz")
        try? FileManager.default.removeItem(at: tmp)
        do {
            let archive = try Archive(url: tmp, accessMode: .create)
            if let xml = source.metadataXML() {
                try archive.addEntry(with: "ComicInfo.xml", type: .file, uncompressedSize: Int64(xml.count), compressionMethod: .deflate,
                                     provider: { position, size in xml.subdata(in: Int(position)..<Int(position) + size) })
            }
            for i in 0..<count {
                try Task.checkCancellation()
                try autoreleasepool {
                    let original = try? source.pageData(at: i)
                    var out: Data?
                    var name = "jpg"
                    if let cg = source.pageImage(at: i, maxPixel: level.maxPixel), let j = jpeg(cg, quality: level.quality) { out = j }
                    // Never make a page bigger: if the original is already smaller, keep it as it is.
                    if let o = original, out == nil || o.count <= out!.count { out = o; name = ext(of: o) }
                    guard let data = out else { throw ComicError.unreadable }
                    let entryName = String(format: "%05d.%@", i + 1, name)
                    try archive.addEntry(with: entryName, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none,
                                         provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) })
                }
                progress(Double(i + 1) / Double(count))
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        let outcome = Outcome(url: tmp, before: fileSize(url), after: fileSize(tmp), pageCount: count)
        if !outcome.worthIt { try? FileManager.default.removeItem(at: tmp) }
        return outcome
    }
}
