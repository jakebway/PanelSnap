import UIKit
import ImageIO
import CryptoKit

/// Cover pictures for Discover. Each one is shrunk to thumbnail size once and kept on disk, so after the first time it is
/// read straight from a small local file (no network) and sits in memory before Discover is even opened. Pictures are
/// fetched in the order they are asked for, which is most relevant first.
@MainActor
final class DiscoverCovers {
    static let shared = DiscoverCovers()

    private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private var inflight: [URL: Task<UIImage?, Never>] = [:]
    private var queue: [URL] = []
    private var queued = Set<URL>()
    private var workers = 0
    private static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DiscoverCovers", isDirectory: true)

    init() {
        memory.totalCostLimit = 90_000_000
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        Task.detached(priority: .background) { Self.trimDisk() }
    }

    func cached(_ url: URL?) -> UIImage? {
        guard let url = url else { return nil }
        return memory.object(forKey: url as NSURL)
    }

    /// Memory first, then the file on disk, then the network.
    func load(_ url: URL) async -> UIImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if let running = inflight[url] { return await running.value }
        let session = self.session
        let task = Task<UIImage?, Never> {
            await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let file = Self.path(for: url)
                if let data = try? Data(contentsOf: file), let img = Self.thumbnail(data) { return img }
                guard let (data, resp) = try? await session.data(from: url),
                      (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      let img = Self.thumbnail(data) else { return nil }
                if let jpeg = img.jpegData(compressionQuality: 0.85) { try? jpeg.write(to: file, options: .atomic) }
                return img
            }.value
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image = image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }

    /// Asks for covers to be ready soon. They are fetched in the order given, a few at a time.
    func prefetch(_ urls: [URL]) {
        for u in urls where memory.object(forKey: u as NSURL) == nil && !queued.contains(u) && inflight[u] == nil {
            queue.append(u)
            queued.insert(u)
        }
        pump()
    }

    private func pump() {
        while workers < 4, !queue.isEmpty {
            let u = queue.removeFirst()
            queued.remove(u)
            workers += 1
            Task {
                _ = await self.load(u)
                self.workers -= 1
                self.pump()
            }
        }
    }

    nonisolated private static func path(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash + ".jpg")
    }

    /// Keeps the folder from growing without limit: files not used for two weeks go.
    nonisolated private static func trimDisk() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        for f in files {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff {
                try? fm.removeItem(at: f)
            }
        }
    }

    nonisolated private static func thumbnail(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 360
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
