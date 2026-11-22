import SwiftUI
import UIKit

/// The bar at the bottom of the reader for moving through the pages, in the style of Kindle: the page you are on stays
/// put while you drag, a small preview of the page under your finger floats above the bar, and the reader goes there
/// when you let go. Tapping the bar jumps to that spot. It is a plain drag gesture rather than the system slider, because
/// the system slider loses its "finished" signal if the controls hide or another gesture takes the touch.
struct PageScrubber: View {
    @Binding var value: Double                 // 0-based page shown on the knob
    var pageCount: Int
    var thumbnail: (Int) async -> UIImage?     // a small picture of a page, for the preview
    var onActive: (Bool) -> Void               // true while a finger is down
    var onJump: (Int) -> Void                  // go to this page

    @State private var dragging = false
    private let tick = UISelectionFeedbackGenerator()

    private var maxValue: Double { return Double(max(1, pageCount - 1)) }

    var body: some View {
        GeometryReader { g in
            let knob: CGFloat = 28
            let span = max(1, g.size.width - knob)
            let fraction = CGFloat(min(max(value / maxValue, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(height: 5)
                Capsule().fill(Theme.accent).frame(width: knob / 2 + span * fraction, height: 5)
                Circle()
                    .fill(Color.white)
                    .frame(width: dragging ? knob + 6 : knob, height: dragging ? knob + 6 : knob)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .offset(x: span * fraction - (dragging ? 3 : 0))
                    .animation(.easeOut(duration: 0.12), value: dragging)
            }
            .frame(width: g.size.width, height: g.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging {
                            dragging = true
                            onActive(true)
                            tick.prepare()
                        }
                        let f = min(max(Double((drag.location.x - knob / 2) / span), 0), 1)
                        let page = (f * maxValue).rounded()
                        if page != value {
                            value = page
                            tick.selectionChanged()
                        }
                    }
                    .onEnded { _ in
                        dragging = false
                        onJump(Int(value))
                        onActive(false)
                    }
            )
            .overlay(alignment: .topLeading) {
                if dragging {
                    let w: CGFloat = 130
                    ScrubPreview(page: Int(value), total: pageCount, load: thumbnail)
                        .frame(width: w)
                        .offset(x: min(max(knob / 2 + span * fraction - w / 2, 0), max(0, g.size.width - w)), y: -(w * 1.55 + 46))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .frame(height: 40)
        .accessibilityElement()
        .accessibilityIdentifier("page-scrubber")
        .accessibilityLabel("Page")
        .accessibilityValue("\(Int(value) + 1) of \(pageCount)")
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 1 : -1
            let page = min(max(value + step, 0), maxValue)
            value = page
            onJump(Int(page))
        }
        .onDisappear {
            // If the controls go away mid-drag, still go where the knob was.
            if dragging { onJump(Int(value)); onActive(false); dragging = false }
        }
    }
}

/// The floating picture of the page under your finger. The last picture stays until the next one is ready, so it never flashes.
private struct ScrubPreview: View {
    let page: Int
    let total: Int
    let load: (Int) async -> UIImage?
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Rectangle().fill(Color.black.opacity(0.55))
                if let image = image {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            }
            .frame(width: 112, height: 168)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("Page \(page + 1) of \(total)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: page) {
            try? await Task.sleep(nanoseconds: 50_000_000)       // skip pages you are only passing over
            if Task.isCancelled { return }
            if let img = await load(page), !Task.isCancelled { image = img }
        }
    }
}
