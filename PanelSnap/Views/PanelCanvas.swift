import SwiftUI
import UIKit

/// Shows one comic page and smoothly "flies" the camera to the current panel.
struct PanelCanvas: View {
    let image: UIImage
    let panels: [CGRect]
    let panelIndex: Int
    let size: CGSize
    let fill: Double

    struct Camera {
        var zoom: CGFloat
        var dx: CGFloat
        var dy: CGFloat
        var width: CGFloat
        var height: CGFloat
    }

    static func camera(image: UIImage, panels: [CGRect], panelIndex: Int, size: CGSize, fill: Double) -> Camera {
        let iw = max(image.size.width, 1)
        let ih = max(image.size.height, 1)
        let fit = min(size.width / iw, size.height / ih)
        let dw = iw * fit
        let dh = ih * fit
        var zoom: CGFloat = 1
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if panelIndex >= 0 && panelIndex < panels.count {
            let p = panels[panelIndex]
            let pw = max(p.width * dw, 1)
            let ph = max(p.height * dh, 1)
            let wanted = min(size.width / pw, size.height / ph) * CGFloat(fill)
            zoom = min(max(wanted, 1), 7)
            dx = -(p.midX - 0.5) * dw * zoom
            dy = -(p.midY - 0.5) * dh * zoom
        }
        return Camera(zoom: zoom, dx: dx, dy: dy, width: dw, height: dh)
    }

    /// Which panel is under a tap? Converts the screen point to page coordinates (0...1) and hit-tests the panels.
    static func panel(at point: CGPoint, image: UIImage, panels: [CGRect], panelIndex: Int, size: CGSize, fill: Double) -> Int? {
        if panels.isEmpty { return nil }
        let cam = camera(image: image, panels: panels, panelIndex: panelIndex, size: size, fill: fill)
        let vx = (point.x - size.width / 2 - cam.dx) / cam.zoom
        let vy = (point.y - size.height / 2 - cam.dy) / cam.zoom
        let nx = 0.5 + vx / max(cam.width, 1)
        let ny = 0.5 + vy / max(cam.height, 1)
        let p = CGPoint(x: nx, y: ny)
        var best: Int?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for (i, r) in panels.enumerated() where r.insetBy(dx: -0.01, dy: -0.01).contains(p) {
            let area = r.width * r.height
            if area < bestArea {
                bestArea = area
                best = i
            }
        }
        return best
    }

    private func camera() -> Camera {
        return PanelCanvas.camera(image: image, panels: panels, panelIndex: panelIndex, size: size, fill: fill)
    }

    var body: some View {
        let cam = camera()
        return Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: cam.width, height: cam.height)
            .scaleEffect(cam.zoom)
            .offset(x: cam.dx, y: cam.dy)
            .animation(.spring(response: 0.46, dampingFraction: 0.9), value: panelIndex)
            .frame(width: size.width, height: size.height)
            .clipped()
    }
}
