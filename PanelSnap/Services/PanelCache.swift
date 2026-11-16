import Foundation
import CoreGraphics

/// Remembers detected panels so a page is only analysed once.
final class PanelCache {
    private struct Stored: Codable {
        var version: Int
        var pages: [String: [[Double]]]
        var rtl: Bool
    }

    private var stored: Stored
    private let url: URL
    private var dirty = false
    private let lock = NSLock()

    static func fileURL(for id: UUID) -> URL {
        return Paths.panelCache.appendingPathComponent(id.uuidString + ".json")
    }

    init(comicID: UUID, rtl: Bool) {
        url = PanelCache.fileURL(for: comicID)
        if let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode(Stored.self, from: data),
           s.version == PanelDetector.version, s.rtl == rtl {
            stored = s
        } else {
            stored = Stored(version: PanelDetector.version, pages: [:], rtl: rtl)
        }
    }

    func panels(for page: Int) -> [CGRect]? {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = stored.pages[String(page)] else { return nil }
        return raw.compactMap { a in
            a.count == 4 ? CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) : nil
        }
    }

    func store(_ rects: [CGRect], for page: Int) {
        lock.lock()
        stored.pages[String(page)] = rects.map { [Double($0.origin.x), Double($0.origin.y), Double($0.size.width), Double($0.size.height)] }
        dirty = true
        lock.unlock()
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if !dirty { return }
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: url, options: .atomic)
        }
        dirty = false
    }
}
