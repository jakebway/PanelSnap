import SwiftUI
import WebKit

struct BrowserDownload: Identifiable {
    enum State { case downloading, adding, done(String), failed(String) }
    var id = UUID()
    var name: String
    var progress: Double = 0
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

    private weak var library: LibraryStore?
    private var observers: [NSKeyValueObservation] = []
    private var downloadIDs: [ObjectIdentifier: UUID] = [:]
    private var destinations: [UUID: URL] = [:]
    private var progressObservers: [UUID: NSKeyValueObservation] = [:]
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
        if webView == nil { build() }
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
            DispatchQueue.main.async { self?.update(id) { $0.progress = p.fractionCompleted } }
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
            update(id) { $0.name = name; $0.state = .failed("Not a comic file, so it was not downloaded.") }
            completionHandler(nil)          // passing nil cancels the download
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PanelSnapDownload-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        destinations[id] = dest
        update(id) { $0.name = name }
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let id = downloadIDs[key], var dest = destinations[id] else { return }
        downloadIDs[key] = nil
        progressObservers[id] = nil
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
                update(id) { $0.state = .failed("That file is not a comic.") }
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
                else if library.errorMessage != nil { $0.state = .failed("Downloaded, but it could not be opened.") }
                else { $0.state = .done("Already in your library") }
            }
            Console.log("browser: downloaded \(name), library +\(gained)")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        guard let id = downloadIDs[key] else { return }
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
