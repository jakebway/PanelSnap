import SwiftUI
import UIKit

/// Keeps each page's shape once it is known, so the scroll doesn't jump while pages load.
final class VerticalLayoutCache: ObservableObject {
    var ratios: [Int: CGFloat] = [:]          // height / width
}

private struct PageFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The whole comic as one continuous scroll, each page fit to the width of the screen.
struct VerticalReader: View {
    @ObservedObject var model: ReaderModel
    let size: CGSize
    @Binding var scrollTarget: Int?
    let onTap: () -> Void

    @StateObject private var layout = VerticalLayoutCache()
    @State private var settled = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<model.pageCount, id: \.self) { page in
                        VerticalPage(model: model, page: page, width: size.width, layout: layout)
                            .id(page)
                    }
                    Color.clear.frame(height: 120)
                }
            }
            .coordinateSpace(name: "vscroll")
            .onPreferenceChange(PageFramesKey.self) { frames in
                guard settled else { return }
                let probe = size.height * 0.35
                if let hit = frames.first(where: { $0.value.minY <= probe && $0.value.maxY > probe })?.key {
                    model.setVisiblePage(hit)
                }
            }
            .onTapGesture { onTap() }
            .onAppear {
                let start = model.pageIndex
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    proxy.scrollTo(start, anchor: .top)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { settled = true }
                }
            }
            .onChange(of: scrollTarget) { _, target in
                guard let t = target else { return }
                proxy.scrollTo(t, anchor: .top)
                scrollTarget = nil
            }
        }
    }
}

private struct VerticalPage: View {
    @ObservedObject var model: ReaderModel
    let page: Int
    let width: CGFloat
    let layout: VerticalLayoutCache
    @State private var image: UIImage?

    var body: some View {
        let ratio = layout.ratios[page] ?? 1.5
        ZStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Color(white: 0.06)
                ProgressView().tint(.white.opacity(0.5))
            }
        }
        .frame(width: width, height: width * ratio)
        .background(
            GeometryReader { g in
                Color.clear.preference(key: PageFramesKey.self, value: [page: g.frame(in: .named("vscroll"))])
            }
        )
        .task(id: page) {
            if image == nil {
                // A tall page needs more pixels than a normal one to stay sharp at screen width.
                let loaded = await model.verticalImage(page: page, width: width)
                if let loaded = loaded {
                    layout.ratios[page] = loaded.size.height / max(loaded.size.width, 1)
                    image = loaded
                }
            }
        }
        .onDisappear { image = nil }
    }
}
