import SwiftUI
import UIKit

/// The reader's manual zoom (pinch and double-tap). It lives in its own object so that zooming only redraws the page,
/// not the whole reader, which is what keeps it smooth.
final class ZoomState: ObservableObject {
    private(set) var zoom: CGFloat = 1
    private(set) var offset: CGSize = .zero
    var lastPinch = Date.distantPast
    var converting = false          // true while switching from a focused panel to the whole page, so the zoom is not reset

    var isZoomed: Bool { return zoom > 1.02 }

    /// Changes zoom and offset together, so the page is redrawn once per frame instead of twice.
    func set(zoom z: CGFloat, offset o: CGSize) {
        objectWillChange.send()
        zoom = z
        offset = o
    }

    func set(offset o: CGSize) { set(zoom: zoom, offset: o) }

    func reset() {
        withAnimation(.easeOut(duration: 0.22)) { set(zoom: 1, offset: .zero) }
    }

    /// How far the page may be moved either way before its edge shows.
    func limits(zoom z: CGFloat, size: CGSize) -> CGSize {
        return CGSize(width: max(z - 1, 0) * size.width / 2, height: max(z - 1, 0) * size.height / 2)
    }

    /// Keeps a zoomed page from being dragged completely out of view.
    func clamp(_ o: CGSize, zoom z: CGFloat, size: CGSize) -> CGSize {
        let m = limits(zoom: z, size: size)
        return CGSize(width: min(max(o.width, -m.width), m.width), height: min(max(o.height, -m.height), m.height))
    }
}

/// Applies the zoom to the page.
struct ZoomedContent<Content: View>: View {
    @ObservedObject var zoom: ZoomState
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .scaleEffect(zoom.zoom)
            .offset(zoom.offset)
    }
}

/// Pinch-to-zoom around the point between your two fingers, with the page following your fingers as they move,
/// plus one-finger dragging while zoomed in (with a little glide when you let go). The recognisers sit on the window,
/// so the reader's own taps and swipes keep working exactly as they did.
struct ZoomGestures: UIViewRepresentable {
    let zoom: ZoomState
    var enabled: Bool
    var panelFocused: Bool                 // on a snapped panel: one finger nudges it, a quick flick still swipes
    var onFlick: (CGSize) -> Void          // a quick flick on a snapped panel: the same as a swipe
    var onPinchedOut: () -> Void           // pinching in on a page that is not zoomed: show the whole page
    var onLeavePanel: () -> Void           // pinching on a focused panel: switch to free zooming on the whole page
    var onEdgeSwipe: (Bool) -> Void        // zoomed in and pushed past the side of the page: true = swiped left

    func makeCoordinator() -> Coordinator { Coordinator(zoom: zoom) }

    func makeUIView(context: Context) -> HookView {
        let v = HookView()
        v.isUserInteractionEnabled = false
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ uiView: HookView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.panelFocused = panelFocused
        context.coordinator.onFlick = onFlick
        context.coordinator.onPinchedOut = onPinchedOut
        context.coordinator.onLeavePanel = onLeavePanel
        context.coordinator.onEdgeSwipe = onEdgeSwipe
    }

    final class HookView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window = window { coordinator?.attach(to: window, stage: self) } else { coordinator?.detach() }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let zoom: ZoomState
        var enabled = true
        var panelFocused = false
        var onFlick: (CGSize) -> Void = { _ in }
        var onPinchedOut: () -> Void = {}
        var onLeavePanel: () -> Void = {}
        var onEdgeSwipe: (Bool) -> Void = { _ in }
        private var startedAtLeftEdge = false, startedAtRightEdge = false
        private var left = false
        private var baseScale: CGFloat = 1       // the recogniser's scale when the current two-finger hold began
        private var touches = 2
        private weak var stage: UIView?
        private weak var window: UIWindow?
        private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        private var start: (zoom: CGFloat, offset: CGSize, point: CGPoint)?
        private var panBase: CGSize = .zero
        private var panTouches = 1               // fingers on the pan last frame; a change means the drag must start afresh
        private var pinchSeen = false            // a pinch ran during this drag, so it is not a swipe
        private var link: CADisplayLink?
        private var glideV = CGPoint.zero        // points per second
        private var glideStamp: CFTimeInterval = 0
        private var glideSize = CGSize.zero

        init(zoom: ZoomState) { self.zoom = zoom }

        func attach(to window: UIWindow, stage: UIView) {
            detach()
            self.window = window
            self.stage = stage
            pan.maximumNumberOfTouches = 2
            for r in [pinch, pan] as [UIGestureRecognizer] {
                r.delegate = self
                r.cancelsTouchesInView = false
                r.delaysTouchesBegan = false
                r.delaysTouchesEnded = false
                window.addGestureRecognizer(r)
            }
        }

        func detach() {
            stopGlide()
            window?.removeGestureRecognizer(pinch)
            window?.removeGestureRecognizer(pan)
            window = nil
        }

        // MARK: Delegate

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard enabled, let stage = stage, stage.window != nil else { return false }
            if !stage.bounds.contains(g.location(in: stage)) { return false }
            if g === pan { return zoom.isZoomed || panelFocused }   // one finger moves the page when zoomed in, or nudges a snapped panel
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if touch.phase == .began { stopGlide() }    // putting a finger down catches a gliding page where it is
            return !(touch.view is UIControl)           // leave sliders and buttons alone
        }

        // MARK: Pinch

        @objc private func pinched(_ g: UIPinchGestureRecognizer) {
            guard let stage = stage else { return }
            let size = stage.bounds.size
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            switch g.state {
            case .began:
                stopGlide()
                left = false
                baseScale = 1
                touches = g.numberOfTouches
                start = (zoom.zoom, zoom.offset, g.location(in: stage))
                zoom.lastPinch = Date()
            case .changed:
                guard var s = start else { return }
                // With fewer than two fingers down, iOS reports the position of the one left, which would yank the page
                // toward it. Ignore those frames, and start afresh from the current state when the second finger returns.
                if g.numberOfTouches < 2 { touches = g.numberOfTouches; return }
                if touches != g.numberOfTouches {
                    touches = g.numberOfTouches
                    s = (zoom.zoom, zoom.offset, g.location(in: stage))
                    start = s
                    baseScale = g.scale
                    return
                }
                if !left && abs(g.scale / baseScale - 1) > 0.015 {
                    // Pinching on a focused panel: go to the whole page at the same apparent zoom, so you can roam it freely.
                    left = true
                    onLeavePanel()
                    s = (zoom.zoom, zoom.offset, s.point)
                    start = s
                }
                // The spot of the page that was between your fingers when you started stays between them,
                // wherever they move, so the page zooms and follows you at the same time.
                let z = min(max(s.zoom * g.scale / baseScale, 0.8), 12)
                let now = g.location(in: stage)
                let ratio = z / s.zoom
                let off = CGSize(width: (now.x - c.x) - ratio * (s.point.x - c.x - s.offset.width),
                                 height: (now.y - c.y) - ratio * (s.point.y - c.y - s.offset.height))
                zoom.set(zoom: z, offset: zoom.clamp(off, zoom: z, size: size))
                zoom.lastPinch = Date()
            case .ended, .cancelled, .failed:
                guard let s = start else { return }
                start = nil
                zoom.lastPinch = Date()
                if zoom.zoom < 1.05 || (left && g.scale < 0.7) {
                    let showWholePage = s.zoom <= 1.02 && g.scale < 0.85
                    zoom.reset()
                    if showWholePage { onPinchedOut() }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        zoom.set(offset: zoom.clamp(zoom.offset, zoom: zoom.zoom, size: size))
                    }
                }
            default:
                break
            }
        }

        // MARK: Gliding (momentum after a drag, and the spring back from an edge)

        private func stopGlide() {
            link?.invalidate()
            link = nil
        }

        private func startGlide(velocity: CGPoint, size: CGSize) {
            stopGlide()
            glideV = velocity
            glideSize = size
            glideStamp = 0
            let l = CADisplayLink(target: self, selector: #selector(glideStep(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }

        /// One frame of momentum. It moves the real offset (not a pending animation), so a touch can catch it exactly,
        /// and a page dragged past its edge eases back while the rest of the movement carries on.
        @objc private func glideStep(_ l: CADisplayLink) {
            guard zoom.isZoomed else { stopGlide(); return }
            let dt = glideStamp == 0 ? l.duration : min(l.timestamp - glideStamp, 1.0 / 20)
            glideStamp = l.timestamp
            let m = zoom.limits(zoom: zoom.zoom, size: glideSize)
            let x = Coordinator.advance(zoom.offset.width, limit: m.width, v: &glideV.x, dt: dt)
            let y = Coordinator.advance(zoom.offset.height, limit: m.height, v: &glideV.y, dt: dt)
            zoom.set(offset: CGSize(width: x.pos, height: y.pos))
            if !x.moving && !y.moving { stopGlide() }
        }

        private static func advance(_ p: CGFloat, limit: CGFloat, v: inout CGFloat, dt: Double) -> (pos: CGFloat, moving: Bool) {
            if p < -limit || p > limit {                       // past the edge: ease back to it
                let target = p < 0 ? -limit : limit
                v = 0
                let np = p + (target - p) * CGFloat(1 - exp(-dt * 16))
                return abs(target - np) < 0.5 ? (target, false) : (np, true)
            }
            v *= CGFloat(pow(0.998, dt * 1000))                 // the same deceleration as a scroll view
            var np = p + v * CGFloat(dt)
            if np < -limit || np > limit {                      // reached the edge: stop there
                np = min(max(np, -limit), limit)
                v = 0
            }
            return (np, abs(v) > 20)
        }

        // MARK: Pan (zoomed in)

        @objc private func panned(_ g: UIPanGestureRecognizer) {
            guard let stage = stage else { return }
            if pinch.state == .began || pinch.state == .changed { pinchSeen = true; return }
            let size = stage.bounds.size
            if !zoom.isZoomed && !converted {
                nudge(g, size: size)
                return
            }
            switch g.state {
            case .began:
                rebase(g, size: size)
            case .changed:
                // After a pinch, or when a finger is added or lifted, carry on from where the page is now
                // rather than from where the drag first began (which would make the page jump).
                if pinchSeen || g.numberOfTouches != panTouches { rebase(g, size: size); return }
                let t = g.translation(in: stage)
                let raw = CGSize(width: panBase.width + t.x, height: panBase.height + t.y)
                let held = zoom.clamp(raw, zoom: zoom.zoom, size: size)
                // Past the edge the page stretches a little and resists, so you can feel that the edge was reached.
                zoom.set(offset: CGSize(width: held.width + (raw.width - held.width) * 0.3,
                                        height: held.height + (raw.height - held.height) * 0.3))
            case .ended:
                converted = false
                let v = g.velocity(in: stage)
                let t = g.translation(in: stage)
                let raw = CGSize(width: panBase.width + t.x, height: panBase.height + t.y)
                let held = zoom.clamp(raw, zoom: zoom.zoom, size: size)
                let pushed = raw.width - held.width          // > 0: dragged right past the left edge; < 0: past the right edge
                let horizontal = abs(t.x) > abs(t.y) * 1.3
                let toNext = startedAtRightEdge && pushed < -40 || startedAtRightEdge && pushed < -8 && v.x < -700
                let toPrevious = startedAtLeftEdge && pushed > 40 || startedAtLeftEdge && pushed > 8 && v.x > 700
                if !pinchSeen && horizontal && (toNext || toPrevious) {
                    withAnimation(.easeOut(duration: 0.2)) { zoom.set(offset: held) }
                    onEdgeSwipe(toNext)
                } else {
                    startGlide(velocity: v, size: size)
                }
            case .cancelled:
                converted = false
                startGlide(velocity: .zero, size: size)
            default:
                break
            }
        }

        /// Starts (or restarts) a drag from the page's current position.
        private func rebase(_ g: UIPanGestureRecognizer, size: CGSize) {
            stopGlide()
            pinchSeen = false
            panTouches = g.numberOfTouches
            g.setTranslation(.zero, in: stage)
            panBase = zoom.offset
            // Only a drag that starts against a side of the page can carry on into a swipe to the next one.
            let maxX = zoom.limits(zoom: zoom.zoom, size: size).width
            startedAtLeftEdge = zoom.offset.width >= maxX - 2
            startedAtRightEdge = zoom.offset.width <= -maxX + 2
        }

        // MARK: Nudging a snapped panel

        private var nudgeBase: CGSize = .zero
        private var converted = false     // this drag has turned into free panning of the whole page

        /// On a snapped panel a quick flick is a swipe. A slower drag lets go of the panel and moves around the
        /// whole page, at the same zoom, so you can look anywhere (the same hand-over a pinch makes).
        private func nudge(_ g: UIPanGestureRecognizer, size: CGSize) {
            switch g.state {
            case .began:
                converted = false
                pinchSeen = false
                g.setTranslation(.zero, in: stage)
            case .changed:
                let t = g.translation(in: stage), v = g.velocity(in: stage)
                zoom.lastPinch = Date()             // keeps the reader's own swipe from also firing
                if hypot(t.x, t.y) > 6 && hypot(v.x, v.y) < 450 {
                    converted = true
                    onLeavePanel()
                    rebase(g, size: size)
                }
            case .ended:
                let v = g.velocity(in: stage), t = g.translation(in: stage)
                zoom.lastPinch = Date()
                let ax = abs(v.x), ay = abs(v.y)
                if !pinchSeen && max(ax, ay) > 700 && max(ax, ay) > 1.3 * min(ax, ay) {
                    onFlick(CGSize(width: t.x, height: t.y))
                }
            default:
                break
            }
        }
    }
}
