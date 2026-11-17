import SwiftUI
import WebKit

struct BrowserDownload: Identifiable {
    enum State { case downloading, adding, done(String), failed(String) }
    var id = UUID()
    var name: String
    var progress: Double = 0
    var bytes: Int64 = 0
    var total: Int64 = 0
    var speed: Double = 0              // bytes per second
    var fast = false                   // using several connections at once
    var state: State = .downloading
}

struct BrowserNotice: Identifiable {
    let id = UUID()
    var text: String
    var openURL: URL? = nil
}

/// The in-app browser. Ads are blocked by `BrowserShield`, pop-ups never open on their own, and any comic file
/// that gets downloaded goes straight into the library.
@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let shared = BrowserModel()

    @Published var webView: WKWebView?
    @Published var hasPage = false
    @Published var addressText = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var downloads: [BrowserDownload] = []
    @Published var notice: BrowserNotice?
    @Published var blockedCount = 0
    /// The page the browser opens on and the house button returns to. Empty means none is set.
    @Published var homeURL: String = UserDefaults.standard.string(forKey: "browserHome") ?? "" {
        didSet { UserDefaults.standard.set(homeURL, forKey: "browserHome") }
    }

    private weak var library: LibraryStore?
    private var observers: [NSKeyValueObservation] = []
    private var downloadIDs: [ObjectIdentifier: UUID] = [:]
    private var destinations: [UUID: URL] = [:]
    private var progressObservers: [UUID: NSKeyValueObservation] = [:]
    private var samples: [UUID: (time: Date, bytes: Int64)] = [:]
    private var fastDownloads: [UUID: SegmentedDownloader] = [:]
    private var noFast = Set<String>()                  // URLs that must use a single connection
    private(set) var isEditing = false

    private static let comicMIME: Set<String> = [
        "application/x-cbz", "application/x-cbr", "application/x-cb7", "application/vnd.comicbook+zip",
        "application/vnd.comicbook-rar", "application/epub+zip", "application/x-7z-compressed",
        "application/x-rar-compressed", "application/vnd.rar", "application/zip", "application/x-zip-compressed",
    ]
    private static let sniffExtensions: Set<String> = ["", "php", "aspx", "html", "htm", "bin", "download", "tmp", "file"]

    func attach(_ library: LibraryStore) { self.library = library }

    func prepare() async {
        await BrowserShield.shared.prepare()
        if webView == nil {
            build()
            if !homeURL.isEmpty { go(homeURL) }
        }
    }

    func goHome() { if !homeURL.isEmpty { go(homeURL) } }

    func setHome(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { homeURL = ""; return }
        homeURL = text.contains("://") ? text : "https://" + text
    }

    func setHomeToCurrentPage() {
        if let url = webView?.url, url.scheme?.hasPrefix("http") == true { homeURL = url.absoluteString }
    }

    private func build() {
        let cfg = WKWebViewConfiguration()
        for list in BrowserShield.shared.lists { cfg.userContentController.add(list) }
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false      // no pop-ups without a real tap
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = .all                // no autoplaying video ads
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.backgroundColor = .black
        observers = [
            wv.observe(\.estimatedProgress) { [weak self] w, _ in DispatchQueue.main.async { self?.progress = w.estimatedProgress } },
            wv.observe(\.isLoading) { [weak self] w, _ in DispatchQueue.main.async { self?.isLoading = w.isLoading } },
            wv.observe(\.canGoBack) { [weak self] w, _ in DispatchQueue.main.async { self?.canGoBack = w.canGoBack } },
            wv.observe(\.canGoForward) { [weak self] w, _ in DispatchQueue.main.async { self?.canGoForward = w.canGoForward } },
            wv.observe(\.url) { [weak self] w, _ in DispatchQueue.main.async { self?.urlChanged(w.url) } },
        ]
        webView = wv
    }

    private func urlChanged(_ url: URL?) {
        guard let url = url else { return }
        hasPage = true
        if !isEditing { addressText = Self.display(url) }
    }

    static func display(_ url: URL) -> String {
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func beginEditing() {
        isEditing = true
        if let url = webView?.url { addressText = url.absoluteString }
    }

    func endEditing() {
        isEditing = false
        if let url = webView?.url { addressText = Self.display(url) } else { addressText = "" }
    }

    // MARK: Navigation

    func go(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let wv = webView else { return }
        var url: URL?
        if text.contains("://"), let u = URL(string: text) {
            url = u
        } else if !text.contains(" "), text.contains("."), let u = URL(string: "https://" + text) {
            url = u
        }
        if url == nil {
            var c = URLComponents(string: "https://duckduckgo.com/")
            c?.queryItems = [URLQueryItem(name: "q", value: text)]
            url = c?.url
        }
        if let url = url { wv.load(URLRequest(url: url)) }
    }

    func reloadOrStop() {
        guard let wv = webView else { return }
        if wv.isLoading { wv.stopLoading() } else if wv.url != nil { wv.reload() }
    }

    private func show(_ text: String, open: URL? = nil) {
        let n = BrowserNotice(text: text, openURL: open)
        notice = n
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if notice?.id == n.id { notice = nil }
        }
    }

    // MARK: Which responses are comics

    private static func isComicURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext != "" && LibraryStore.comicExtensions.contains(ext)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        // App-store hops, intent:// links and other non-web jumps are never followed.
        guard ["http", "https", "about", "blob", "data"].contains(scheme) else {
            blockedCount += 1
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload || (scheme != "about" && Self.isComicURL(url)) {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        let mime = (response.mimeType ?? "").lowercased()
        var attachment = false
        if let http = response as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(), cd.contains("attachment") {
            attachment = true
        }
        let isFile = response.url.map { Self.isComicURL($0) } ?? false
        if navigationResponse.isForMainFrame,
           !navigationResponse.canShowMIMEType || attachment || isFile || Self.comicMIME.contains(mime) {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        track(download)
    }

    // MARK: Pop-ups: a real tap on a link from the same site opens here; everything else is held back

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if navigationAction.navigationType == .linkActivated {
            let here = webView.url?.host?.replacingOccurrences(of: "www.", with: "")
            let there = url.host?.replacingOccurrences(of: "www.", with: "")
            if here != nil, here == there || (there ?? "").hasSuffix("." + (here ?? "-")) {
                webView.load(URLRequest(url: url))
            } else {
                blockedCount += 1
                show("Held back a new tab to \(Self.display(url)).", open: url)
            }
        } else {
            blockedCount += 1
        }
        return nil
    }

    // MARK: Downloads

    private func track(_ download: WKDownload) {
        download.delegate = self
        let id = UUID()
        downloadIDs[ObjectIdentifier(download)] = id
        downloads.insert(BrowserDownload(id: id, name: "Starting download…"), at: 0)
        progressObservers[id] = download.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let done = p.completedUnitCount, all = p.totalUnitCount
            DispatchQueue.main.async { self?.report(id, bytes: done, total: all) }
        }
    }

    /// Records progress and works out the speed (smoothed over the last second or so).
    private func report(_ id: UUID, bytes: Int64, total: Int64) {
        let now = Date()
        var speed: Double? = nil
        if let last = samples[id] {
            let dt = now.timeIntervalSince(last.time)
            if dt >= 0.8 {
                speed = Double(bytes - last.bytes) / dt
                samples[id] = (now, bytes)
            }
        } else {
            samples[id] = (now, bytes)
        }
        update(id) {
            $0.bytes = bytes
            if total > 0 { $0.total = total; $0.progress = min(1, Double(bytes) / Double(total)) }
            if let s = speed { $0.speed = $0.speed == 0 ? s : ($0.speed * 0.5 + s * 0.5) }
        }
    }

    private func update(_ id: UUID, _ change: (inout BrowserDownload) -> Void) {
        if let i = downloads.firstIndex(where: { $0.id == id }) { change(&downloads[i]) }
    }

    func dismissDownload(_ id: UUID) {
        downloads.removeAll { $0.id == id }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        guard let id = downloadIDs[ObjectIdentifier(download)] else { completionHandler(nil); return }
        var name = suggestedFilename.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "download" }
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, !LibraryStore.comicExtensions.contains(ext), !Self.sniffExtensions.contains(ext) {
            update(id) { $0.name = name; $0.state = .failed("Not a comic file. Download canceled.") }
            completionHandler(nil)          // passing nil cancels the download
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PanelSnapDownload-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        destinations[id] = dest
        update(id) { $0.name = name }
        completionHandler(dest)
        if let url = response.url, response.expectedContentLength >= 3_000_000, !noFast.contains(url.absoluteString) {
            accelerate(id: id, download: download, url: url, length: response.expectedContentLength, name: name)
        }
    }

    // MARK: Fast downloads: the same file over several connections

    private func requestHeaders(for url: URL) async -> [String: String] {
        var h: [String: String] = ["Accept-Encoding": "identity"]
        if let wv = webView {
            if let ua = try? await wv.evaluateJavaScript("navigator.userAgent") as? String { h["User-Agent"] = ua }
            if let page = wv.url { h["Referer"] = page.absoluteString }
            let host = url.host ?? ""
            let cookies = await wv.configuration.websiteDataStore.httpCookieStore.allCookies().filter {
                let d = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
                return host == d || host.hasSuffix("." + d)
            }
            for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) { h[k] = v }
        }
        return h
    }

    /// Asks the server for the first byte only. If it answers with a proper partial response, the file is split up.
    private func probe(_ url: URL, headers: [String: String], length: Int64) async -> Bool {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 206,
              let range = http.value(forHTTPHeaderField: "Content-Range"),
              range.hasSuffix("/\(length)") else { return false }
        return true
    }

    private func accelerate(id: UUID, download: WKDownload, url: URL, length: Int64, name: String) {
        Task {
            let headers = await requestHeaders(for: url)
            guard await probe(url, headers: headers, length: length) else {
                Console.log("browser: \(name) stays on one connection")
                return
            }
            // The server supports ranges: stop the single-connection download and fetch it in pieces instead.
            if let old = destinations[id] { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
            fastDownloads[id] = nil
            progressObservers[id] = nil
            downloadIDs[ObjectIdentifier(download)] = nil
            download.cancel { _ in }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PanelSnapDownload-\(UUID().uuidString)")
            let dest = dir.appendingPathComponent(name)
            destinations[id] = dest
            update(id) { $0.fast = true; $0.total = length }
            Console.log("browser: \(name) downloading over 8 connections")
            let fast = SegmentedDownloader(url: url, headers: headers, total: length, dest: dest, connections: 8)
            fast.onProgress = { [weak self] bytes in
                DispatchQueue.main.async { self?.report(id, bytes: bytes, total: length) }
            }
            fast.onFinish = { [weak self] error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.fastDownloads[id] = nil
                    if error == nil {
                        self.completed(id: id, dest: dest)
                    } else {
                        Console.log("browser: fast download failed (\(error?.localizedDescription ?? "")), retrying on one connection")
                        self.fallBack(id: id, url: url)
                    }
                }
            }
            fastDownloads[id] = fast
            fast.start()
        }
    }

    /// The pieces would not come through: run the whole download again the ordinary way.
    private func fallBack(id: UUID, url: URL) {
        noFast.insert(url.absoluteString)
        dismissDownload(id)
        guard let wv = webView else { return }
        var req = URLRequest(url: url)
        if let page = wv.url { req.setValue(page.absoluteString, forHTTPHeaderField: "Referer") }
        wv.startDownload(using: req) { [weak self] dl in self?.track(dl) }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let id = downloadIDs[key], let dest = destinations[id] else { return }
        downloadIDs[key] = nil
        progressObservers[id] = nil
        completed(id: id, dest: dest)
    }

    private func completed(id: UUID, dest destination: URL) {
        var dest = destination
        var ext = dest.pathExtension.lowercased()
        if !LibraryStore.comicExtensions.contains(ext) {
            // No usable extension: look inside the file to see what it is.
            if let sniffed = Self.sniff(dest) {
                let renamed = dest.deletingPathExtension().appendingPathExtension(sniffed)
                try? FileManager.default.moveItem(at: dest, to: renamed)
                dest = renamed
                ext = sniffed
            } else {
                try? FileManager.default.removeItem(at: dest.deletingLastPathComponent())
                update(id) { $0.state = .failed("This file isn't a comic.") }
                return
            }
        }
        update(id) { $0.progress = 1; $0.state = .adding }
        guard let library = library else { return }
        let before = library.comics.count
        Task {
            await library.importFiles([dest], shelf: nil)
            let gained = library.comics.count - before
            let name = dest.lastPathComponent
            update(id) {
                if gained > 0 { $0.state = .done("Added to your library") }
                else if library.errorMessage != nil { $0.state = .failed("Downloaded, but couldn't be opened.") }
                else { $0.state = .done("Already in your library") }
            }
            Console.log("browser: downloaded \(name), library +\(gained)")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        guard let id = downloadIDs[key] else { return }          // one we replaced with a faster download
        downloadIDs[key] = nil
        progressObservers[id] = nil
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        if cancelled, case .failed = downloads.first(where: { $0.id == id })?.state ?? .downloading { return }
        update(id) { $0.state = .failed("Download failed.") }
        Console.log("browser: download failed: \(error.localizedDescription)")
    }

    private static func sniff(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let b = [UInt8]((try? h.read(upToCount: 8)) ?? Data())
        if b.starts(with: [0x50, 0x4B]) { return "cbz" }
        if b.starts(with: [0x52, 0x61, 0x72, 0x21]) { return "cbr" }
        if b.starts(with: [0x37, 0x7A, 0xBC, 0xAF]) { return "cb7" }
        if b.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
        return nil
    }
}
