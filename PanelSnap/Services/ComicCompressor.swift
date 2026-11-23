import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

/// The library format: every comic is kept as a CBZ of HEIC pages sized for the unfolded screen.
enum ComicCompressor {
    static let quality: CGFloat = 0.62
    static var enabled: Bool {
        return UserDefaults.standard.object(forKey: "compressDownloads") as? Bool ?? true
    }
    /// Longest side of a stored page, in pixels: this device's screen. A foldable counts its biggest (unfolded) screen,
    /// remembered in case the app is opened while it is folded.
    @MainActor static var targetPixel: CGFloat {
        let b = UIScreen.main.nativeBounds
        let d = UserDefaults.standard
        let biggest = max(max(b.width, b.height), CGFloat(d.double(forKey: "largestScreenPixel")))
        d.set(Double(biggest), forKey: "largestScreenPixel")
        return min(3200, max(1600, biggest))
    }

    struct Outcome {
        var url: URL
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

    private static func heic(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// True when the file is already in the library format (marker entry, or HEIC pages), so it is never converted twice.
    static func isOptimized(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "cbz", let archive = try? Archive(url: url, accessMode: .read) else { return false }
        var checked = 0
        for entry in archive where entry.type == .file {
            let name = entry.path.lowercased()
            if name == "panelsnap.json" { return true }
            let ext = (name as NSString).pathExtension
            if ArchiveNames.imageExtensions.contains(ext) {
                if ext == "heic" || ext == "heif" { return true }
                checked += 1
                if checked >= 3 { return false }
            }
        }
        return false
    }

    static func fileSize(_ url: URL) -> Int64 {
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// Writes the smaller copy to a temporary file and reports the sizes. The caller decides whether to swap it in.
    static func compress(_ url: URL, maxPixel: CGFloat, progress: @escaping (Double) -> Void) throws -> Outcome {
        let source = try ComicOpener.open(url: url)
        let count = source.pageCount
        guard count > 0 else { throw ComicError.noPages }
        let tmp = Paths.caches.appendingPathComponent("compress-" + UUID().uuidString + ".cbz")
        try? FileManager.default.removeItem(at: tmp)
        do {
            let archive = try Archive(url: tmp, accessMode: .create)
            let marker = Data("{\"format\":\"heic\",\"version\":1}".utf8)
            try archive.addEntry(with: "PanelSnap.json", type: .file, uncompressedSize: Int64(marker.count), compressionMethod: .none,
                                 provider: { position, size in marker.subdata(in: Int(position)..<Int(position) + size) })
            if let xml = source.metadataXML() {
                try archive.addEntry(with: "ComicInfo.xml", type: .file, uncompressedSize: Int64(xml.count), compressionMethod: .deflate,
                                     provider: { position, size in xml.subdata(in: Int(position)..<Int(position) + size) })
            }
            for i in 0..<count {
                try Task.checkCancellation()
                try autoreleasepool {
                    let original = try? source.pageData(at: i)
                    var out: Data?
                    var name = "heic"
                    if let cg = source.pageImage(at: i, maxPixel: maxPixel), let j = heic(cg) { out = j }
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
