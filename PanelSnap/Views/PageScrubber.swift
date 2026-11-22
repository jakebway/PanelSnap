import SwiftUI
import UIKit

/// The bar at the bottom of the reader for moving through the pages. Drag the knob, or tap anywhere on the bar.
/// The page changes while you drag (after a short pause on a page, so a fast scrub stays smooth) and once more
/// when you let go. It is built from a plain drag gesture instead of the system slider, because the system slider
/// loses its "finished" signal if the controls hide or another gesture takes the touch, and then never jumps.
struct PageScrubber: View {
    @Binding var value: Double                 // 0-based page shown on the knob
    var pageCount: Int
    var onActive: (Bool) -> Void               // true while a finger is down
    var onJump: (Int) -> Void                  // go to this page

    @State private var dragging = false
    @State private var pending: Task<Void, Never>?
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
                            schedule(Int(page), after: 0.18)
                        }
                    }
                    .onEnded { _ in
                        dragging = false
                        pending?.cancel()
                        onJump(Int(value))
                        onActive(false)
                    }
            )
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
            if dragging { pending?.cancel(); onJump(Int(value)); onActive(false); dragging = false }
        }
    }

    private func schedule(_ page: Int, after seconds: Double) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            onJump(page)
        }
    }
}
