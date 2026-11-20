import UIKit
import ImageIO

/// Cover pictures for Discover: kept in memory and on disk, shrunk to thumbnail size, and fetched ahead of time, so a
/// shelf appears already filled in.
@MainActor
final class DiscoverCovers {
    static let shared = DiscoverCovers()

    private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    init() {
        memory.countLimit = 400
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 20_000_000, diskCapacity: 400_000_000)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    func cached(_ url: URL?) -> UIImage? {
        guard let url = url else { return nil }
        return memory.object(forKey: url as NSURL)
    }

    func load(_ url: URL) async -> UIImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if let running = inflight[url] { return await running.value }
        let session = self.session
        let task = Task<UIImage?, Never> {
            guard let (data, resp) = try? await session.data(from: url),
                  (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
            return await Task.detached(priority: .utility) { DiscoverCovers.thumbnail(data) }.value
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image = image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }

    func prefetch(_ urls: [URL]) {
        for u in urls where memory.object(forKey: u as NSURL) == nil && inflight[u] == nil {
            Task { _ = await self.load(u) }
        }
    }

    nonisolated private static func thumbnail(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 420
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
