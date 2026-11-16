import Foundation
import CoreGraphics

/// Remembers detected panels so a page is only analysed once.
final class PanelCache {
    private struct Stored: Codable {
        var version: Int
        var pages: [String: [[Double]]]
        var rtl: Bool
        var manual: [String: [[Double]]]? = nil      // panels the reader drew by hand: they outlive detector updates
    }

    private var stored: Stored
    private let url: URL
    private var dirty = false
    private let lock = NSLock()

    static func fileURL(for id: UUID) -> URL {
        return Paths.panelCache.appendingPathComponent(id.uuidString + "-d3.json")
    }

    init(comicID: UUID, rtl: Bool) {
        url = PanelCache.fileURL(for: comicID)
        let old = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        if let s = old, s.version == PanelDetector.version, s.rtl == rtl {
            stored = s
        } else {
            stored = Stored(version: PanelDetector.version, pages: [:], rtl: rtl, manual: old?.manual)
        }
    }

    func panels(for page: Int) -> [CGRect]? {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = stored.manual?[String(page)] ?? stored.pages[String(page)] else { return nil }
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

    /// Panels drawn by hand for a page (an empty list means "no panels, show the whole page").
    func setManual(_ rects: [CGRect], for page: Int) {
        lock.lock()
        var m = stored.manual ?? [:]
        m[String(page)] = rects.map { [Double($0.origin.x), Double($0.origin.y), Double($0.size.width), Double($0.size.height)] }
        stored.manual = m
        dirty = true
        lock.unlock()
    }

    /// Goes back to automatic detection for a page.
    func clearManual(for page: Int) {
        lock.lock()
        stored.manual?.removeValue(forKey: String(page))
        stored.pages.removeValue(forKey: String(page))
        dirty = true
        lock.unlock()
        flush()
    }

    func hasManual(for page: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored.manual?[String(page)] != nil
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
