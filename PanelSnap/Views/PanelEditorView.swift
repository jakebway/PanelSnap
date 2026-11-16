import SwiftUI
import UIKit

/// Lets the reader fix the panels on one page by hand: draw a box around a missed panel, tap a box to select it and
/// delete it. The result is remembered for that page.
struct PanelEditorView: View {
    @ObservedObject var model: ReaderModel
    @Environment(\.dismiss) private var dismiss

    @State private var rects: [CGRect] = []
    @State private var selected: Int?
    @State private var drawing: CGRect?            // the box being dragged out, in page coordinates (0...1)
    @State private var dragStart: CGPoint?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                GeometryReader { geo in
                    if let image = model.image {
                        editor(image: image, area: geo.size)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                controls
            }
        }
        .onAppear { rects = model.panels }
    }

    private func fitted(_ image: UIImage, in area: CGSize) -> CGRect {
        let scale = min(area.width / max(image.size.width, 1), area.height / max(image.size.height, 1))
        let w = image.size.width * scale, h = image.size.height * scale
        return CGRect(x: (area.width - w) / 2, y: (area.height - h) / 2, width: w, height: h)
    }

    private func editor(image: UIImage, area: CGSize) -> some View {
        let page = fitted(image, in: area)
        return ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: page.width, height: page.height)
                .position(x: page.midX, y: page.midY)

            ForEach(Array(rects.enumerated()), id: \.offset) { i, r in
                let box = CGRect(x: page.minX + r.minX * page.width, y: page.minY + r.minY * page.height,
                                 width: r.width * page.width, height: r.height * page.height)
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill((selected == i ? Theme.red : Theme.accent).opacity(selected == i ? 0.28 : 0.14))
                    Rectangle()
                        .stroke(selected == i ? Theme.red : Theme.accent, lineWidth: selected == i ? 4 : 3)
                    Text("\(i + 1)")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 26, height: 26)
                        .background(selected == i ? Theme.red : Theme.accent, in: Circle())
                        .padding(6)
                }
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
                .allowsHitTesting(false)
            }

            if let d = drawing {
                let box = CGRect(x: page.minX + d.minX * page.width, y: page.minY + d.minY * page.height,
                                 width: d.width * page.width, height: d.height * page.height)
                Rectangle()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.white.opacity(0.12))
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: area.width, height: area.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let a = normalised(v.startLocation, in: page)
                    let b = normalised(v.location, in: page)
                    if dragStart == nil { dragStart = a }
                    let moved = hypot(v.translation.width, v.translation.height)
                    if moved > 10 {
                        drawing = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    }
                }
                .onEnded { v in
                    let moved = hypot(v.translation.width, v.translation.height)
                    if moved <= 10 {
                        selectBox(at: normalised(v.location, in: page))     // a tap
                    } else if let d = drawing, d.width > 0.04, d.height > 0.03 {
                        rects.append(d)
                        selected = rects.count - 1
                    }
                    drawing = nil
                    dragStart = nil
                }
        )
    }

    private func normalised(_ p: CGPoint, in page: CGRect) -> CGPoint {
        return CGPoint(x: min(max((p.x - page.minX) / max(page.width, 1), 0), 1),
                       y: min(max((p.y - page.minY) / max(page.height, 1), 0), 1))
    }

    /// Tap: select the smallest box under the finger, or clear the selection.
    private func selectBox(at p: CGPoint) {
        var best: Int?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for (i, r) in rects.enumerated() where r.contains(p) {
            let area = r.width * r.height
            if area < bestArea { bestArea = area; best = i }
        }
        selected = best
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Text(hint)
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 8) {
                Button { dismiss() } label: { pill("Cancel", fill: Theme.card2, text: .white) }
                Button {
                    if let i = selected, rects.indices.contains(i) {
                        rects.remove(at: i)
                        selected = nil
                    }
                } label: { pill("Delete", fill: Theme.card2, text: .white) }
                    .disabled(selected == nil)
                    .opacity(selected == nil ? 0.4 : 1)
                Menu {
                    Button {
                        rects = []
                        selected = nil
                    } label: { Label("Clear all boxes", systemImage: "xmark.rectangle") }
                    Button {
                        model.resetPanels()
                        dismiss()
                    } label: { Label("Detect again", systemImage: "arrow.counterclockwise") }
                } label: { CircleIcon(systemName: "ellipsis") }
                Spacer(minLength: 0)
                Button {
                    model.savePanels(rects)
                    dismiss()
                } label: { pill("Save", fill: Theme.accent, text: Theme.onAccent) }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private func pill(_ title: String, fill: Color, text: Color) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(text)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(fill, in: Capsule())
    }

    private var hint: String {
        if rects.isEmpty { return "No panels on this page yet. Drag a box around each panel, in reading order." }
        if selected != nil { return "Panel \((selected ?? 0) + 1) selected. Delete it, or drag to draw another." }
        return "Drag to draw a box around a missed panel. Tap a box to select it."
    }
}
