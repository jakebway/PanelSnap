import SwiftUI
import UIKit

/// Everything the reader needs once a comic is open.
final class ReaderSession: ObservableObject {
    let model: ReaderModel
    let companion: CompanionModel
    init(model: ReaderModel, companion: CompanionModel) {
        self.model = model
        self.companion = companion
    }
}

/// Opens the comic file (showing a spinner), then shows the reader.
struct ReaderHost: View {
    let entry: ComicEntry
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var session: ReaderSession?
    @State private var failure: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let s = session {
                ReaderView(entry: entry, model: s.model, companion: s.companion)
            } else if let message = failure {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.accent)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                    Button("Close") { dismiss() }
                        .buttonStyle(YellowButtonStyle())
                }
            } else {
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.3)
                    Text("Opening…")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .task {
            await open()
        }
    }

    private func open() async {
        let url = library.fileURL(for: entry)
        let name = entry.originalName
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(ComicSource, ComicIdentity), Error> in
            do {
                let source = try ComicOpener.open(url: url)
                let identity = IdentityBuilder.make(originalName: name, source: source)
                return .success((source, identity))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let pair):
            let model = ReaderModel(
                entry: entry,
                source: pair.0,
                identity: pair.1,
                snap: settings.snapToPanels,
                pageFirst: settings.showFullPageFirst
            )
            let companion = CompanionModel(entry: entry, identity: pair.1, settings: settings, coverURL: library.coverURL(for: entry))
            session = ReaderSession(model: model, companion: companion)
        case .failure(let error):
            failure = error.localizedDescription
        }
    }
}

struct ReaderView: View {
    let entry: ComicEntry
    @ObservedObject var model: ReaderModel
    @ObservedObject var companion: CompanionModel

    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var chromeVisible = true
    @State private var showCompanion = false
    // Manual zoom (pinch or double-tap). 1 = off, so everything behaves exactly as before until you zoom.
    @State private var userZoom: CGFloat = 1
    @State private var userOffset: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var pinchStart: (zoom: CGFloat, offset: CGSize)?
    @State private var lastTap: (time: Date, point: CGPoint)?
    @State private var pendingTap: Task<Void, Never>?
    @State private var scrub: Double = 0
    @State private var scrubbing = false
    @State private var hideTask: Task<Void, Never>?
    @State private var started = false

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 640
            HStack(spacing: 0) {
                stage(size: stageSize(geo.size, wide: wide))
                if wide && showCompanion {
                    Divider()
                    CompanionView(model: companion, onClose: { toggleCompanion() })
                        .frame(width: min(420, geo.size.width * 0.4))
                        .background(Theme.bg)
                        .transition(.move(edge: .trailing))
                }
            }
            .background(Color.black)
            .sheet(isPresented: Binding(
                get: { showCompanion && !wide },
                set: { newValue in if !newValue { showCompanion = false } }
            )) {
                CompanionView(model: companion, onClose: { showCompanion = false })
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
        .onAppear {
            if !started {
                started = true
                model.start()
                companion.load()
            }
            UIApplication.shared.isIdleTimerDisabled = true
            haptic.prepare()
            scheduleHide()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            saveProgress()
            model.finish()
        }
        .onChange(of: model.panelIndex) { _, _ in
            haptic.impactOccurred(intensity: 0.5)
            saveProgress()
        }
        .onChange(of: model.pageIndex) { _, newValue in
            if !scrubbing { scrub = Double(newValue) }
            saveProgress()
        }
        .onChange(of: model.pageIndex) { _, _ in resetZoom() }
        .onChange(of: model.panelIndex) { _, _ in resetZoom() }
        .onChange(of: settings.snapToPanels) { _, _ in
            model.updateSettings(snap: settings.snapToPanels, pageFirst: settings.showFullPageFirst)
        }
        .onChange(of: settings.showFullPageFirst) { _, _ in
            model.updateSettings(snap: settings.snapToPanels, pageFirst: settings.showFullPageFirst)
        }
    }

    private func stageSize(_ total: CGSize, wide: Bool) -> CGSize {
        if wide && showCompanion {
            return CGSize(width: total.width - min(420, total.width * 0.4) - 1, height: total.height)
        }
        return total
    }

    // MARK: Stage

    private func stage(size: CGSize) -> some View {
        ZStack {
            Color.black

            if let img = model.image {
                PanelCanvas(
                    image: img,
                    panels: model.panels,
                    panelIndex: model.panelIndex,
                    size: size,
                    fill: 0.96
                )
                .id(model.pageIndex)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: model.pageIndex)
                .scaleEffect(userZoom)
                .offset(userOffset)
            }

            if model.isLoading && model.image == nil {
                ProgressView().tint(.white).scaleEffect(1.3)
            }

            if let err = model.loadError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // Gesture layer
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        handleTap(at: value.location, size: size)
                    }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onChanged { value in
                            if isZoomed { pan(value.translation, size: size) }
                        }
                        .onEnded { value in
                            if isZoomed {
                                panBase = userOffset            // zoomed in: dragging moves the page, it does not turn it
                            } else {
                                handleDrag(value.translation)
                            }
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if pinchStart == nil { pinchStart = (userZoom, userOffset) }
                            pinch(value, size: size)
                        }
                        .onEnded { value in
                            let wasZoomed = (pinchStart?.zoom ?? 1) > 1.02
                            pinch(value, size: size)
                            pinchStart = nil
                            if userZoom < 1.05 {
                                resetZoom()
                                // pinching in on an un-zoomed page still shows the whole page, as before
                                if !wasZoomed && value.magnification < 0.85 { model.showOverview() }
                            } else {
                                panBase = userOffset
                            }
                        }
                )

            // Chrome
            VStack(spacing: 0) {
                if chromeVisible { topBar(size: size).transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer()
                if chromeVisible { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .animation(.easeInOut(duration: 0.22), value: chromeVisible)

            if model.reachedEnd {
                endCard
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    // MARK: Gestures

    /// Tap rules:
    ///  - the outer edges step to the previous / next panel (and onto the next page),
    ///  - a tap on a panel inside the middle area jumps straight to that panel,
    ///  - anywhere else in the middle shows or hides the controls.
    private func handleTap(at point: CGPoint, size: CGSize) {
        let width = max(size.width, 1)
        let f = point.x / width
        let edge: CGFloat = model.panelIndex < 0 ? 0.12 : 0.25    // whole page: slim edges so panels near them stay tappable
        // The edges stay instant. Only the middle waits a moment, to see whether a second tap is coming.
        if f < edge {
            if model.rtl { forward() } else { back() }
            return
        }
        if f > 1 - edge {
            if model.rtl { back() } else { forward() }
            return
        }
        if let last = lastTap, Date().timeIntervalSince(last.time) < 0.3,
           hypot(point.x - last.point.x, point.y - last.point.y) < 60 {
            pendingTap?.cancel()
            lastTap = nil
            doubleTap(at: point, size: size)
            return
        }
        lastTap = (Date(), point)
        pendingTap?.cancel()
        pendingTap = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            lastTap = nil
            middleTap(at: point, size: size)
        }
    }

    private func middleTap(at point: CGPoint, size: CGSize) {
        if !isZoomed, let img = model.image,
           let hit = PanelCanvas.panel(at: point, image: img, panels: model.panels,
                                       panelIndex: model.panelIndex, size: size, fill: 0.96),
           hit != model.panelIndex {
            hideChrome()
            model.focus(panel: hit)
            return
        }
        chromeVisible.toggle()
        if chromeVisible { scheduleHide() }
    }

    // MARK: Manual zoom

    private var isZoomed: Bool { return userZoom > 1.02 }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            userZoom = 1
            userOffset = .zero
        }
        panBase = .zero
    }

    /// Keeps the zoomed page from being dragged completely out of view.
    private func clamp(_ offset: CGSize, zoom: CGFloat, size: CGSize) -> CGSize {
        let maxX = (zoom - 1) * size.width / 2
        let maxY = (zoom - 1) * size.height / 2
        return CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
    }

    private func pan(_ translation: CGSize, size: CGSize) {
        userOffset = clamp(CGSize(width: panBase.width + translation.width, height: panBase.height + translation.height),
                           zoom: userZoom, size: size)
    }

    /// Pinch: the spot between your fingers stays under them while the page grows or shrinks.
    private func pinch(_ value: MagnifyGesture.Value, size: CGSize) {
        guard let start = pinchStart else { return }
        let z1 = min(max(start.zoom * value.magnification, 1), 6)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let p = CGPoint(x: value.startAnchor.x * size.width, y: value.startAnchor.y * size.height)
        let ratio = z1 / start.zoom
        let off = CGSize(width: (p.x - c.x) - ratio * ((p.x - c.x) - start.offset.width),
                         height: (p.y - c.y) - ratio * ((p.y - c.y) - start.offset.height))
        userZoom = z1
        userOffset = clamp(off, zoom: z1, size: size)
    }

    /// Double-tap: zoom in on the spot you tapped, or zoom back out.
    private func doubleTap(at point: CGPoint, size: CGSize) {
        if isZoomed { resetZoom(); return }
        let z: CGFloat = 2.5
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let off = CGSize(width: (point.x - c.x) * (1 - z), height: (point.y - c.y) * (1 - z))
        hideChrome()
        withAnimation(.easeOut(duration: 0.22)) {
            userZoom = z
            userOffset = clamp(off, zoom: z, size: size)
        }
        panBase = userOffset
    }

    /// Swipe left/right turns the page, swipe up opens the Companion, swipe down shows the menu (or closes the Companion).
    private func handleDrag(_ t: CGSize) {
        let dx = t.width
        let dy = t.height
        if abs(dx) > 50 && abs(dx) > abs(dy) * 1.3 {
            let swipedLeft = dx < 0
            hideChrome()
            // Swiping left brings the next page (right-to-left comics swipe the other way).
            model.turnPage(forward: model.rtl ? !swipedLeft : swipedLeft)
        } else if dy < -80 && abs(dx) < 70 {
            if !showCompanion { toggleCompanion() }
        } else if dy > 90 && abs(dx) < 70 {
            if showCompanion {
                showCompanion = false
            } else {
                chromeVisible = true          // swipe down = bring up the menu
                scheduleHide()
            }
        }
    }

    private func forward() {
        hideChrome()
        model.goForward()
    }

    private func back() {
        hideChrome()
        model.goBack()
    }

    private func hideChrome() {
        if chromeVisible { chromeVisible = false }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            chromeVisible = false
        }
    }

    private func toggleCompanion() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showCompanion.toggle()
        }
        if showCompanion { companion.load() }
    }

    private func saveProgress() {
        library.recordProgress(
            id: entry.id,
            page: model.pageIndex,
            panel: model.panelIndex,
            finished: model.reachedEnd
        )
    }

    private func close() {
        saveProgress()
        model.finish()
        dismiss()
    }

    // MARK: Chrome

    private func topBar(size: CGSize) -> some View {
        HStack(spacing: 12) {
            Button(action: { close() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(positionText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
            readerMenu
        }
        .foregroundStyle(.white)
        .padding(.leading, 16)
        .padding(.trailing, Theme.cameraWidth + 30)      // keep the menu button clear of the Duo status widget
        .padding(.top, 54)
        .padding(.bottom, 22)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.65), Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
        )
    }

    /// Everything you might want while reading, in one place.
    private var readerMenu: some View {
        Menu {
            Toggle(isOn: $settings.snapToPanels) { Label("Snap panel to panel", systemImage: "rectangle.split.2x2") }
            Toggle(isOn: $settings.showFullPageFirst) { Label("Whole page first", systemImage: "doc") }
            Divider()
            if !model.panels.isEmpty {
                Button { model.toggleOverview() } label: {
                    Label(model.panelIndex < 0 ? "Zoom to first panel" : "Show whole page", systemImage: "viewfinder")
                }
            }
            Button { toggleCompanion() } label: { Label("Companion", systemImage: "sparkles") }
            Button { model.reachedEnd = true; close() } label: { Label("Mark as read and close", systemImage: "checkmark.circle") }
            Divider()
            Button { close() } label: { Label("Back to library", systemImage: "chevron.down") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private var positionText: String {
        var s = "Page \(model.pageIndex + 1) of \(model.pageCount)"
        if model.panelIndex >= 0 && !model.panels.isEmpty {
            s += "  ·  Panel \(model.panelIndex + 1)/\(model.panels.count)"
        }
        return s
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Button(action: { model.toggleOverview() }) {
                    Image(systemName: model.panelIndex < 0 ? "viewfinder" : "rectangle.expand.vertical")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                if model.pageCount > 1 {
                    Slider(
                        value: $scrub,
                        in: 0...Double(max(1, model.pageCount - 1)),
                        step: 1,
                        onEditingChanged: { editing in
                            scrubbing = editing
                            if !editing { model.jump(toPage: Int(scrub)) }
                        }
                    )
                    .tint(Theme.accent)
                } else {
                    Spacer()
                }
                Button(action: { toggleCompanion() }) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 40, height: 40)
                        .background(Theme.accent, in: Circle())
                }
            }
            HStack {
                Text("\(Int(scrub) + 1)")
                Spacer()
                Text("\(model.pageCount)")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, 62)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 26)
        .background(
            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        )
    }

    private var endCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("That's the end!")
                .font(.title3.weight(.bold))
            Text(entry.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 10) {
                Button("Keep reading") { model.reachedEnd = false }
                    .buttonStyle(GreyButtonStyle())
                Button("Done") { close() }
                    .buttonStyle(YellowButtonStyle())
            }
        }
        .padding(26)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(40)
    }
}
