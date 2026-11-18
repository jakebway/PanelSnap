import Foundation

/// Downloads one file over several connections at once (like a download manager). Sites that throttle every
/// connection separately hand out the file several times faster this way. Each connection has its own URLSession so
/// they are real, separate connections even on HTTP/2.
final class SegmentedDownloader {
    struct RangeUnsupported: Error {}

    private struct Chunk { var start: Int64; var end: Int64; var done: Int64 = 0; var tries = 0
        var length: Int64 { return end - start + 1 } }

    private let url: URL
    private let headers: [String: String]
    private let total: Int64
    private let dest: URL
    private let connections: Int

    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var queue: [Int] = []
    private var finishedChunks = 0
    private var received: Int64 = 0
    private var handle: FileHandle?
    private var workers: [Worker] = []
    private var ended = false
    private var lastReport = Date.distantPast
    private var active = 0                       // connections currently working
    private var scaler: DispatchSourceTimer?
    private var scaleBytes: Int64 = 0
    private var scaleSpeed: Double = 0
    private var ceiling = 16                     // never more connections than this

    /// Called a few times a second with the bytes received so far.
    var onProgress: ((Int64) -> Void)?
    /// Called once: nil on success.
    var onFinish: ((Error?) -> Void)?

    init(url: URL, headers: [String: String], total: Int64, dest: URL, connections: Int = 8) {
        self.url = url
        self.headers = headers
        self.total = total
        self.dest = dest
        self.connections = connections
    }

    func start() {
        // Small pieces: the last ones to finish are short, so there is no long slow tail.
        let size = max(Int64(512_000), min(Int64(2_000_000), total / 64))
        var offset: Int64 = 0
        while offset < total {
            let end = min(offset + size - 1, total - 1)
            chunks.append(Chunk(start: offset, end: end))
            queue.append(chunks.count - 1)
            offset = end + 1
        }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            handle = try FileHandle(forWritingTo: dest)
            try handle?.truncate(atOffset: UInt64(total))
        } catch {
            finish(error)
            return
        }
        for _ in 0..<min(connections, chunks.count) { addWorker() }
        startScaling()
    }

    private func addWorker() {
        let w = Worker(owner: self)
        lock.lock()
        workers.append(w)
        active += 1
        lock.unlock()
        w.next()
    }

    /// Some sites hand out far more speed to more connections, others stop caring after a few. Every few seconds,
    /// if the last batch of new connections raised the total speed, add more (up to a limit); if not, stop adding.
    private func startScaling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 4, repeating: 4)
        scaleBytes = 0
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let done = self.ended || self.queue.isEmpty
            let now = self.received
            let current = self.active
            self.lock.unlock()
            if done { self.scaler?.cancel(); self.scaler = nil; return }
            let speed = Double(now - self.scaleBytes) / 4
            self.scaleBytes = now
            let gained = self.scaleSpeed == 0 || speed > self.scaleSpeed * 1.25
            self.scaleSpeed = speed
            if gained && current < self.ceiling {
                for _ in 0..<2 { self.addWorker() }
            } else if !gained {
                self.scaler?.cancel(); self.scaler = nil      // more connections stopped helping
            }
        }
        scaler = timer
        timer.resume()
    }

    func cancel() {
        lock.lock()
        let wasEnded = ended
        ended = true
        lock.unlock()
        if wasEnded { return }
        scaler?.cancel(); scaler = nil
        workers.forEach { $0.stop() }
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: dest)
    }

    // MARK: Shared state (always called with care for the lock)

    fileprivate func take() -> Int? {
        lock.lock(); defer { lock.unlock() }
        if ended || queue.isEmpty { return nil }
        return queue.removeFirst()
    }

    fileprivate func request(for index: Int) -> URLRequest {
        lock.lock()
        let c = chunks[index]
        lock.unlock()
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 30
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=\(c.start + c.done)-\(c.end)", forHTTPHeaderField: "Range")
        return req
    }

    fileprivate func write(_ data: Data, chunk index: Int) {
        lock.lock()
        if ended { lock.unlock(); return }
        let at = chunks[index].start + chunks[index].done
        do {
            try handle?.seek(toOffset: UInt64(at))
            try handle?.write(contentsOf: data)
        } catch {
            lock.unlock()
            finish(error)
            return
        }
        chunks[index].done += Int64(data.count)
        chunks[index].tries = 0                       // it is moving, so earlier hiccups don't count
        received += Int64(data.count)
        let now = Date()
        let report = now.timeIntervalSince(lastReport) > 0.25
        if report { lastReport = now }
        let bytes = received
        lock.unlock()
        if report { onProgress?(bytes) }
    }

    /// A connection ended. Returns true if it should carry on with the next chunk.
    fileprivate func chunkEnded(_ index: Int, error: Error?) -> Bool {
        lock.lock()
        if ended { lock.unlock(); return false }
        if chunks[index].done >= chunks[index].length {
            finishedChunks += 1
            let all = finishedChunks == chunks.count
            lock.unlock()
            if all { finish(nil) }
            return !all
        }
        // Stopped early. A connection beyond the first few that gets refused is simply retired: the site has had
        // enough, and the rest of the file carries on over the others.
        if active > 4, error != nil {
            active -= 1
            ceiling = max(4, active)                  // this is as many as the site will take
            queue.insert(index, at: 0)
            scaler?.cancel(); scaler = nil
            lock.unlock()
            return false
        }
        // Put the rest in the queue and try again.
        chunks[index].tries += 1
        let tries = chunks[index].tries
        if tries <= 6 { queue.insert(index, at: 0) }
        lock.unlock()
        if tries > 6 {
            let failure: Error = error ?? URLError(.networkConnectionLost)
            finish(failure)
            return false
        }
        return true
    }

    fileprivate func finish(_ error: Error?) {
        lock.lock()
        if ended { lock.unlock(); return }
        ended = true
        lock.unlock()
        scaler?.cancel(); scaler = nil
        workers.forEach { $0.stop() }
        try? handle?.close()
        handle = nil
        if error != nil { try? FileManager.default.removeItem(at: dest) }
        else { onProgress?(total) }
        onFinish?(error)
    }

    // MARK: One connection

    private final class Worker: NSObject, URLSessionDataDelegate {
        private weak var owner: SegmentedDownloader?
        private var session: URLSession!
        private var chunk = -1
        private var stopped = false
        private var task: URLSessionDataTask?
        private var got: Int64 = 0                 // bytes this connection has received
        private var lastGot: Int64 = 0
        private var slowTicks = 0
        private var stalls: [Int: Int] = [:]       // how many times each piece was restarted for being slow
        private var watchdog: DispatchSourceTimer?

        init(owner: SegmentedDownloader) {
            self.owner = owner
            super.init()
            let cfg = URLSessionConfiguration.default
            cfg.httpMaximumConnectionsPerHost = 1
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.urlCache = nil
            session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            // A connection that has crawled for a few seconds is dropped and the piece restarts on a fresh one,
            // which is usually fast again. This is what rescues the slow end of a download.
            let t = DispatchSource.makeTimerSource(queue: .global())
            t.schedule(deadline: .now() + 2, repeating: 2)
            t.setEventHandler { [weak self] in self?.checkSpeed() }
            t.resume()
            watchdog = t
        }

        private func checkSpeed() {
            guard !stopped, let task = task, chunk >= 0 else { return }
            let rate = got - lastGot
            lastGot = got
            if rate < 40_000 {          // under about 20 KB/s
                slowTicks += 1
            } else {
                slowTicks = 0
            }
            if slowTicks >= 2, (stalls[chunk] ?? 0) < 4 {
                slowTicks = 0
                stalls[chunk, default: 0] += 1
                task.cancel()
            }
        }

        func next() {
            guard !stopped, let owner = owner, let index = owner.take() else {
                watchdog?.cancel()
                session.finishTasksAndInvalidate()
                return
            }
            chunk = index
            slowTicks = 0
            lastGot = got
            let t = session.dataTask(with: owner.request(for: index))
            task = t
            t.resume()
        }

        func stop() {
            stopped = true
            watchdog?.cancel()
            session.invalidateAndCancel()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if (response as? HTTPURLResponse)?.statusCode == 206 {
                completionHandler(.allow)
            } else {
                completionHandler(.cancel)
                owner?.finish(RangeUnsupported())
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            got += Int64(data.count)
            owner?.write(data, chunk: chunk)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard !stopped, let owner = owner else { return }
            if owner.chunkEnded(chunk, error: error) {
                // a short pause after a failure, none after a success
                if error != nil {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.next() }
                } else {
                    next()
                }
            }
        }
    }
}
