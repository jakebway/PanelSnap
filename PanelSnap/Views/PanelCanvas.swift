import SwiftUI
import UIKit

/// Shows one comic page and smoothly "flies" the camera to the current panel.
struct PanelCanvas: View {
    let image: UIImage
    let panels: [CGRect]
    let panelIndex: Int
    let size: CGSize
    let fill: Double

    private struct Camera {
        var zoom: CGFloat
        var dx: CGFloat
        var dy: CGFloat
        var width: CGFloat
        var height: CGFloat
    }

    private func camera() -> Camera {
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
