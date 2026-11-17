import SwiftUI
import UIKit

/// The reader's manual zoom (pinch and double-tap). It lives in its own object so that zooming only redraws the page,
/// not the whole reader, which is what keeps it smooth.
final class ZoomState: ObservableObject {
    @Published var zoom: CGFloat = 1
    @Published var offset: CGSize = .zero
    var lastPinch = Date.distantPast

    var isZoomed: Bool { return zoom > 1.02 }

    func reset() {
        withAnimation(.easeOut(duration: 0.22)) {
            zoom = 1
            offset = .zero
        }
    }

    /// Keeps a zoomed page from being dragged completely out of view.
    func clamp(_ o: CGSize, zoom z: CGFloat, size: CGSize) -> CGSize {
        let maxX = max(z - 1, 0) * size.width / 2
        let maxY = max(z - 1, 0) * size.height / 2
        return CGSize(width: min(max(o.width, -maxX), maxX), height: min(max(o.height, -maxY), maxY))
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
    var onPinchedOut: () -> Void           // pinching in on a page that is not zoomed: show the whole page

    func makeCoordinator() -> Coordinator { Coordinator(zoom: zoom) }

    func makeUIView(context: Context) -> HookView {
        let v = HookView()
        v.isUserInteractionEnabled = false
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ uiView: HookView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.onPinchedOut = onPinchedOut
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
        var onPinchedOut: () -> Void = {}
        private weak var stage: UIView?
        private weak var window: UIWindow?
        private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        private var start: (zoom: CGFloat, offset: CGSize, point: CGPoint)?
        private var panBase: CGSize = .zero

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
            window?.removeGestureRecognizer(pinch)
            window?.removeGestureRecognizer(pan)
            window = nil
        }

        // MARK: Delegate

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard enabled, let stage = stage, stage.window != nil else { return false }
            if !stage.bounds.contains(g.location(in: stage)) { return false }
            if g === pan { return zoom.isZoomed }        // one finger only moves the page when it is zoomed in
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            return !(touch.view is UIControl)           // leave sliders and buttons alone
        }

        // MARK: Pinch

        @objc private func pinched(_ g: UIPinchGestureRecognizer) {
            guard let stage = stage else { return }
            let size = stage.bounds.size
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            switch g.state {
            case .began:
                start = (zoom.zoom, zoom.offset, g.location(in: stage))
                zoom.lastPinch = Date()
            case .changed:
                guard let s = start else { return }
                // The spot of the page that was between your fingers when you started stays between them,
                // wherever they move, so the page zooms and follows you at the same time.
                let z = min(max(s.zoom * g.scale, 0.8), 6)
                let now = g.location(in: stage)
                let ratio = z / s.zoom
                let off = CGSize(width: (now.x - c.x) - ratio * (s.point.x - c.x - s.offset.width),
                                 height: (now.y - c.y) - ratio * (s.point.y - c.y - s.offset.height))
                zoom.zoom = z
                zoom.offset = zoom.clamp(off, zoom: z, size: size)
                zoom.lastPinch = Date()
            case .ended, .cancelled, .failed:
                guard let s = start else { return }
                start = nil
                zoom.lastPinch = Date()
                if zoom.zoom < 1.05 {
                    let showWholePage = s.zoom <= 1.02 && g.scale < 0.85
                    zoom.reset()
                    if showWholePage { onPinchedOut() }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        zoom.offset = zoom.clamp(zoom.offset, zoom: zoom.zoom, size: size)
                    }
                }
            default:
                break
            }
        }

        // MARK: Pan (zoomed in)

        @objc private func panned(_ g: UIPanGestureRecognizer) {
            guard let stage = stage else { return }
            if pinch.state == .began || pinch.state == .changed { return }
            let size = stage.bounds.size
            switch g.state {
            case .began:
                g.setTranslation(.zero, in: stage)
                panBase = zoom.offset
            case .changed:
                let t = g.translation(in: stage)
                zoom.offset = zoom.clamp(CGSize(width: panBase.width + t.x, height: panBase.height + t.y),
                                         zoom: zoom.zoom, size: size)
            case .ended:
                let v = g.velocity(in: stage)
                let glide = zoom.clamp(CGSize(width: zoom.offset.width + v.x * 0.18, height: zoom.offset.height + v.y * 0.18),
                                       zoom: zoom.zoom, size: size)
                withAnimation(.easeOut(duration: 0.45)) { zoom.offset = glide }
            default:
                break
            }
        }
    }
}
