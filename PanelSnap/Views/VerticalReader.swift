import SwiftUI
import UIKit
import ImageIO

/// The whole comic as one continuous scroll, each page fit to the width of the screen. It is a real UIKit scroll view,
/// so pinch zoom, panning, momentum and edge bounce are the system's own, exactly like Photos.
struct VerticalReader: UIViewRepresentable {
    @ObservedObject var model: ReaderModel
    let size: CGSize
    @Binding var scrollTarget: Int?
    let onTap: () -> Void

    func makeCoordinator() -> VerticalScroller { VerticalScroller(model: model, onTap: onTap) }

    func makeUIView(context: Context) -> UIScrollView {
        let c = context.coordinator
        let sv = UIScrollView()
        sv.backgroundColor = .black
        sv.delegate = c
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 4
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.bouncesZoom = true
        sv.contentInsetAdjustmentBehavior = .never
        sv.addSubview(c.container)
        c.scroll = sv

        let double = UITapGestureRecognizer(target: c, action: #selector(VerticalScroller.doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: c, action: #selector(VerticalScroller.tapped(_:)))
        single.require(toFail: double)
        sv.addGestureRecognizer(double)
        sv.addGestureRecognizer(single)
        c.start(width: size.width, height: size.height)
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        let c = context.coordinator
        c.onTap = onTap
        c.resize(width: size.width, height: size.height)
        if let t = scrollTarget {
            c.scroll(toPage: t)
            DispatchQueue.main.async { scrollTarget = nil }
        }
    }
}

final class VerticalScroller: NSObject, UIScrollViewDelegate {
    let model: ReaderModel
    var onTap: () -> Void
    let container = UIView()
    weak var scroll: UIScrollView?

    private var width: CGFloat = 0
    private var height: CGFloat = 0
    private var ratios: [CGFloat] = []          // each page's height / width
    private var tops: [CGFloat] = []
    private var total: CGFloat = 0
    private var views: [Int: UIImageView] = [:]
    private var loading = Set<Int>()
    private var pendingRelayout = false
    private var settled = false
    private var sizing: Task<Void, Never>?

    init(model: ReaderModel, onTap: @escaping () -> Void) {
        self.model = model
        self.onTap = onTap
        super.init()
        ratios = Array(repeating: 1.5, count: model.pageCount)
        container.backgroundColor = .black
    }

    deinit { sizing?.cancel() }

    // MARK: Setup and layout

    func start(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
        relayout()
        let first = model.pageIndex
        DispatchQueue.main.async { [weak self] in
            self?.scroll(toPage: first, animated: false)
            self?.settled = true
            self?.refreshVisible()
        }
        // Learn every page's real shape without decoding it, so the scroll doesn't jump while pages load.
        sizing = Task { [weak self] in
            guard let self = self else { return }
            var batch: [Int: CGFloat] = [:]
            for p in 0..<self.model.pageCount {
                if Task.isCancelled { return }
                if let r = await self.model.pageRatio(page: p) { batch[p] = r }
                if batch.count >= 8 || p == self.model.pageCount - 1 {
                    let done = batch
                    batch = [:]
                    await MainActor.run { self.apply(ratios: done) }
                }
            }
        }
    }

    func resize(width w: CGFloat, height h: CGFloat) {
        guard abs(w - width) > 0.5 || abs(h - height) > 0.5 else { return }
        let page = model.pageIndex
        width = w
        height = h
        scroll?.setZoomScale(1, animated: false)
        relayout()
        scroll(toPage: page, animated: false)
        refreshVisible()
    }

    private func relayout() {
        var y: CGFloat = 0
        tops = []
        for r in ratios { tops.append(y); y += width * r }
        total = y + 120
        container.frame = CGRect(x: 0, y: 0, width: width, height: total)
        scroll?.contentSize = container.frame.size
        for (p, v) in views { v.frame = frame(of: p) }
    }

    private func frame(of p: Int) -> CGRect {
        return CGRect(x: 0, y: tops[p], width: width, height: width * ratios[p])
    }

    /// New page shapes: applied while the scroll is at 1x (a zoomed scroll view must not be resized under the finger),
    /// keeping the page you are looking at where it is.
    private func apply(ratios new: [Int: CGFloat]) {
        guard let sv = scroll else { return }
        var changed = false
        for (p, r) in new where p < ratios.count && abs(ratios[p] - r) > 0.005 { ratios[p] = r; changed = true }
        guard changed else { return }
        if sv.zoomScale > 1.01 || sv.isDragging || sv.isDecelerating { pendingRelayout = true; return }
        let anchor = topPage(at: sv.contentOffset.y)
        let oldTop = tops[anchor]
        let within = sv.contentOffset.y - oldTop
        relayout()
        sv.contentOffset.y = tops[anchor] + within
    }

    private func topPage(at y: CGFloat) -> Int {
        var lo = 0, hi = tops.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if tops[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        return max(0, min(lo, tops.count - 1))
    }

    func scroll(toPage p: Int, animated: Bool = true) {
        guard let sv = scroll, p >= 0, p < tops.count else { return }
        let z = sv.zoomScale
        let maxY = max(0, sv.contentSize.height * z - sv.bounds.height)
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: min(tops[p] * z, maxY)), animated: animated)
    }

    // MARK: Pages in and out of memory

    private func refreshVisible() {
        guard let sv = scroll, !tops.isEmpty else { return }
        let z = max(sv.zoomScale, 0.01)
        let y0 = sv.contentOffset.y / z
        let y1 = (sv.contentOffset.y + sv.bounds.height) / z
        let first = topPage(at: max(0, y0 - sv.bounds.height / z))
        var last = topPage(at: y1 + sv.bounds.height / z)
        last = min(last, tops.count - 1)
        let keep = first...max(first, last)
        for p in Array(views.keys) where !keep.contains(p) {
            views[p]?.removeFromSuperview()
            views[p] = nil
        }
        for p in keep where views[p] == nil { show(p) }
        if settled {
            let probe = (sv.contentOffset.y + sv.bounds.height * 0.35) / z
            model.setVisiblePage(topPage(at: probe))
        }
    }

    private func show(_ p: Int) {
        let v = UIImageView(frame: frame(of: p))
        v.contentMode = .scaleAspectFit
        v.backgroundColor = UIColor(white: 0.06, alpha: 1)
        container.addSubview(v)
        views[p] = v
        guard loading.insert(p).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let img = await self.model.verticalImage(page: p, width: self.width)
            self.loading.remove(p)
            guard let img = img else { return }
            self.views[p]?.image = img
            self.apply(ratios: [p: img.size.height / max(img.size.width, 1)])
        }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { return container }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { refreshVisible() }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Keep the page centred sideways while it is narrower than the screen (zooming out past 1x springs back).
        let w = container.frame.width
        let inset = max(0, (scrollView.bounds.width - w) / 2)
        scrollView.contentInset.left = inset
        scrollView.contentInset.right = inset
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        refreshVisible()
        flushPending()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { flushPending() }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { flushPending() }
    }

    private func flushPending() {
        guard pendingRelayout, let sv = scroll, sv.zoomScale <= 1.01 else { return }
        pendingRelayout = false
        let anchor = topPage(at: sv.contentOffset.y)
        let within = sv.contentOffset.y - tops[anchor]
        relayout()
        sv.contentOffset.y = tops[anchor] + within
    }

    // MARK: Taps

    /// Left and right edges page up and down; anywhere else shows or hides the controls.
    @objc func tapped(_ g: UITapGestureRecognizer) {
        guard let sv = scroll else { return }
        let x = g.location(in: sv).x - sv.contentOffset.x
        let f = x / max(sv.bounds.width, 1)
        if f < 0.1 || f > 0.9 {
            let step = sv.bounds.height * 0.85 * (f < 0.1 ? -1 : 1)
            let maxY = max(0, sv.contentSize.height * sv.zoomScale - sv.bounds.height)
            let y = min(max(0, sv.contentOffset.y + step), maxY)
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: y), animated: true)
        } else {
            onTap()
        }
    }

    /// Double-tap: zoom in on the spot, or back out.
    @objc func doubleTapped(_ g: UITapGestureRecognizer) {
        guard let sv = scroll else { return }
        if sv.zoomScale > 1.01 {
            sv.setZoomScale(1, animated: true)
            return
        }
        let target: CGFloat = 2.5
        let p = g.location(in: container)
        let w = sv.bounds.width / target
        let h = sv.bounds.height / target
        sv.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
    }
}
