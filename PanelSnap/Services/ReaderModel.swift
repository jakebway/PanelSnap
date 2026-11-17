import Foundation
import SwiftUI
import UIKit

/// Drives the reader: loads pages, finds panels and decides where the "camera" points.
@MainActor
final class ReaderModel: ObservableObject {

    enum Target {
        case first
        case last
        case overview
        case index(Int)
    }

    @Published private(set) var pageIndex: Int = 0
    @Published private(set) var panelIndex: Int = 0          // -1 = whole page
    @Published private(set) var image: UIImage?
    @Published private(set) var panels: [CGRect] = []
    @Published private(set) var isLoading = true
    @Published private(set) var loadError: String?
    @Published var reachedEnd = false

    let entry: ComicEntry
    let rtl: Bool
    let pageCount: Int
    private(set) var identity: ComicIdentity

    private let source: ComicSource
    private let panelCache: PanelCache
    private var loadToken = 0
    private var imageCache: [Int: UIImage] = [:]
    private var panelMemo: [Int: [CGRect]] = [:]
    private var snap: Bool
    private var pageFirst: Bool
    private var observers: [NSObjectProtocol] = []

    init(entry: ComicEntry, source: ComicSource, identity: ComicIdentity, snap: Bool, pageFirst: Bool) {
        self.entry = entry
        self.source = source
        self.identity = identity
        self.pageCount = source.pageCount
        self.rtl = entry.isManga || identity.rtl
        self.panelCache = PanelCache(comicID: entry.id, rtl: entry.isManga || identity.rtl)
        self.snap = snap
        self.pageFirst = pageFirst

        var startPage = entry.lastPage
        var startPanel = entry.lastPanel
        if entry.finished || startPage >= source.pageCount {
            startPage = 0
            startPanel = 0
        }
        self.pageIndex = max(0, min(startPage, source.pageCount - 1))
        self.panelIndex = startPanel

        // Save detected panels if iOS is about to close the app, and shed memory when it asks us to.
        let cache = panelCache
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            cache.flush()
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dropFarPages(keeping: self?.pageIndex ?? 0, window: 0) }
        })
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// Forget decoded pages that are more than `window` pages away from `page`.
    private func dropFarPages(keeping page: Int, window: Int) {
        for key in Array(imageCache.keys) where abs(key - page) > window {
            imageCache.removeValue(forKey: key)
            panelMemo.removeValue(forKey: key)
        }
    }

    func updateSettings(snap: Bool, pageFirst: Bool) {
        let turnedOn = snap && !self.snap
        self.snap = snap
        self.pageFirst = pageFirst
        if !snap { panelIndex = -1 }
        if turnedOn {
            // Pages read in regular mode were never scanned: forget them so they get scanned now.
            panelMemo.removeAll()
            load(page: pageIndex, target: .overview)
        }
    }

    // MARK: Loading

    func start() {
        // A comic you have never opened starts on the whole first page; otherwise resume where you stopped.
        load(page: pageIndex, target: entry.hasStarted ? .index(panelIndex) : .first)
    }

    func finish() {
        panelCache.flush()
    }

    private func load(page: Int, target: Target) {
        loadToken += 1
        let token = loadToken
        let maxPixel: CGFloat = 2600
        let src = source
        let cache = panelCache
        let isRTL = rtl
        let scan = snap            // regular viewer mode never scans for panels

        if let cached = imageCache[page], let memo = panelMemo[page] {
            apply(page: page, image: cached, panels: memo, target: target)
            prefetch(around: page)
            return
        }
        isLoading = true
        loadError = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let cg = src.pageImage(at: page, maxPixel: maxPixel) else {
                await MainActor.run {
                    guard let self = self, token == self.loadToken else { return }
                    self.isLoading = false
                    self.loadError = "Page \(page + 1) couldn't be read."
                }
                return
            }
            var found = cache.panels(for: page)
            if found == nil && scan {
                let detected = PanelDetector.detect(image: cg, rtl: isRTL)
                cache.store(detected, for: page)
                found = detected
            }
            let rects = found ?? []
            let ui = UIImage(cgImage: cg)
            await MainActor.run {
                guard let self = self else { return }
                self.imageCache[page] = ui
                self.panelMemo[page] = rects
                if token == self.loadToken {
                    self.apply(page: page, image: ui, panels: rects, target: target)
                    self.prefetch(around: page)
                }
            }
        }
    }

    private func apply(page: Int, image: UIImage, panels: [CGRect], target: Target) {
        // Covers, credits and splash pages have nothing to snap to: show them whole instead of guessing.
        let usable = panels.count >= 2 ? panels : []
        pageIndex = page
        self.image = image
        self.panels = usable
        isLoading = false
        loadError = nil
        if !snap || usable.isEmpty {
            panelIndex = -1
            return
        }
        switch target {
        case .first:
            panelIndex = pageFirst ? -1 : 0
        case .last:
            panelIndex = usable.count - 1
        case .overview:
            panelIndex = -1
        case .index(let i):
            panelIndex = max(-1, min(i, usable.count - 1))
        }
    }

    private func prefetch(around page: Int) {
        // Keep only the current page and its two neighbours in memory (each decoded page is tens of MB).
        dropFarPages(keeping: page, window: 1)
        for next in [page + 1, page - 1] where next >= 0 && next < pageCount {
            if imageCache[next] != nil { continue }
            let src = source
            let cache = panelCache
            let isRTL = rtl
            Task.detached(priority: .utility) { [weak self] in
                guard let cg = src.pageImage(at: next, maxPixel: 2600) else { return }
                var found = cache.panels(for: next)
                if found == nil {
                    let detected = PanelDetector.detect(image: cg, rtl: isRTL)
                    cache.store(detected, for: next)
                    found = detected
                }
                let rects = found ?? []
                let ui = UIImage(cgImage: cg)
                await MainActor.run {
                    guard let self = self else { return }
                    if abs(next - self.pageIndex) <= 1 {
                        self.imageCache[next] = ui
                        self.panelMemo[next] = rects
                    }
                }
            }
        }
    }

    // MARK: Navigation

    func goForward() {
        if isLoading { return }
        if panelIndex < 0 {
            if snap && !panels.isEmpty {
                panelIndex = 0
            } else {
                nextPage()
            }
        } else if panelIndex + 1 < panels.count {
            panelIndex += 1
        } else {
            nextPage()
        }
    }

    func goBack() {
        if isLoading { return }
        if panelIndex > 0 {
            panelIndex -= 1
        } else if panelIndex == 0 && pageFirst {
            panelIndex = -1
        } else {
            previousPage()
        }
    }

    /// Swipe: turn the page (like the Kindle / Amazon comics reader). The new page opens whole.
    func turnPage(forward: Bool) {
        if isLoading { return }
        if forward {
            nextPage()
        } else if pageIndex > 0 {
            load(page: pageIndex - 1, target: .first)
        }
    }

    func nextPage() {
        if pageIndex + 1 < pageCount {
            load(page: pageIndex + 1, target: .first)
        } else {
            reachedEnd = true
        }
    }

    func previousPage() {
        if pageIndex > 0 {
            load(page: pageIndex - 1, target: snap ? .last : .overview)
        }
    }

    func jump(toPage page: Int) {
        let p = max(0, min(page, pageCount - 1))
        if p == pageIndex { return }
        load(page: p, target: .first)
    }

    func toggleOverview() {
        if panels.isEmpty { return }
        if panelIndex < 0 {
            panelIndex = 0
        } else {
            panelIndex = -1
        }
    }

    /// Tap on a specific panel: fly straight to it.
    func focus(panel index: Int) {
        if isLoading || index < 0 || index >= panels.count { return }
        panelIndex = index
    }

    func showOverview() {
        if panelIndex >= 0 { panelIndex = -1 }
    }

    func focusPanelNearest(to point: CGPoint) {
        // Used after a pinch-out from the page overview: jump to the panel under the centre.
        if panels.isEmpty { return }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (i, r) in panels.enumerated() {
            let dx = r.midX - point.x
            let dy = r.midY - point.y
            let d = dx * dx + dy * dy
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        panelIndex = best
    }
}
