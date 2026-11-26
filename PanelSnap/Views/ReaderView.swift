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
                snap: entry.snapPanels ?? settings.snapToPanels,
                pageFirst: false
            )
            let companion = CompanionModel(entry: entry, identity: pair.1, settings: settings, coverURL: library.coverURL(for: entry))
            companion.attach(source: pair.0, page: model.pageIndex)
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
    @State private var zoom = ZoomState()          // not observed here: zooming redraws the page only
    @State private var lastTap: (time: Date, point: CGPoint)?
    @State private var pendingTap: Task<Void, Never>?
    @State private var scrub: Double = 0
    @State private var scrubbing = false
    @Environment(\.scenePhase) private var scenePhase

    /// Puts the slider back on the page that is really showing (after returning to the app, or an interrupted drag).
    private func syncSlider() {
        scrubbing = false
        scrub = Double(model.pageIndex)
    }
    @State private var hideTask: Task<Void, Never>?
    @State private var started = false
    @State private var scrollTarget: Int?

    // This comic's own reading choices (the Settings value is only the starting point for a comic that has none yet).
    private var current: ComicEntry? { library.comics.first { $0.id == entry.id } }
    private var vertical: Bool { current?.verticalScroll ?? false }
    private var snap: Bool { current?.snapPanels ?? settings.snapToPanels }
    private var verticalBinding: Binding<Bool> {
        Binding(get: { vertical }, set: { library.setReading(id: entry.id, vertical: $0) })
    }
    private var snapBinding: Binding<Bool> {
        Binding(get: { snap }, set: { library.setReading(id: entry.id, snap: $0) })
    }

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
            syncSlider()
            scheduleHide()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            companion.stopScanning()
            saveProgress()
            model.finish()
        }
        .onChange(of: model.panelIndex) { _, _ in
            haptic.impactOccurred(intensity: 0.5)
            saveProgress()
        }
        .onChange(of: model.pageIndex) { _, newValue in
            if !scrubbing { scrub = Double(newValue) }
            companion.pageChanged(newValue)
            saveProgress()
        }
        .onChange(of: model.pageCount) { _, _ in syncSlider() }
        .onChange(of: chromeVisible) { _, shown in if shown { syncSlider() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { syncSlider() } }
        .onChange(of: model.pageIndex) { _, _ in resetZoom() }
        .onChange(of: model.panelIndex) { _, _ in if !zoom.converting { resetZoom() } }
        .onChange(of: vertical) { _, on in
            if on { hideChrome() } else { model.reloadCurrent() }
        }
        .onChange(of: snap) { _, _ in
            model.updateSettings(snap: snap, pageFirst: false)
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

            if vertical {
                VerticalReader(model: model, size: size, scrollTarget: $scrollTarget, onTap: {
                    chromeVisible.toggle()
                    if chromeVisible { scheduleHide() }
                })
            } else if let img = model.image {
                ZoomedContent(zoom: zoom) {
                    PanelCanvas(
                        image: img,
                        panels: model.panels,
                        panelIndex: model.panelIndex,
                        size: size,
                        fill: 0.96,
                        animated: !zoom.converting
                    )
                    .id(model.pageIndex)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: model.pageIndex)
                }
            }

            if !vertical && model.isLoading && model.image == nil {
                ProgressView().tint(.white).scaleEffect(1.3)
            }

            if let err = model.loadError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // Gesture layer (page mode only; the vertical scroller handles its own touches)
            if !vertical {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        handleTap(at: value.location, size: size)
                    }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            // Zoomed in, or just pinched: the drag belongs to the zoom, so it must not turn the page.
                            if zoom.isZoomed || Date().timeIntervalSince(zoom.lastPinch) < 0.45 { return }
                            handleDrag(value.translation)
                        }
                )

            ZoomGestures(zoom: zoom, enabled: !showCompanion && !scrubbing && !model.reachedEnd,
                         blockedBottom: chromeVisible ? 130 : 0,
                         panelFocused: model.panelIndex >= 0,
                         onFlick: { handleDrag($0) },
                         onPinchedOut: { model.showOverview() },
                         onZoomedOut: { model.forgetPlace() },
                         onLeavePanel: { leavePanel(size: size) },
                         onEdgeSwipe: { swipedLeft in
                             hideChrome()
                             model.step(forward: model.rtl ? !swipedLeft : swipedLeft)
                         })
                .allowsHitTesting(false)
            }

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
    ///  - the outer edges (like a swipe) turn the page on a whole page and step panels when you are on a panel,
    ///  - a tap on a panel inside the middle area jumps straight to that panel,
    ///  - anywhere else in the middle shows or hides the controls.
    private func handleTap(at point: CGPoint, size: CGSize) {
        let width = max(size.width, 1)
        let f = point.x / width
        let edge: CGFloat = model.panelIndex < 0 ? 0.095 : 0.25    // whole page: slim edges so panels near them stay tappable
        // The edges stay instant. Only the middle waits a moment, to see whether a second tap is coming.
        if f < edge {
            hideChrome()
            model.step(forward: model.rtl)
            return
        }
        if f > 1 - edge {
            hideChrome()
            model.step(forward: !model.rtl)
            return
        }
        if chromeVisible {
            // The menu and page bar are up: the first tap in the middle only puts them away, straight away.
            pendingTap?.cancel()
            lastTap = nil
            hideChrome()
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
        if let img = model.image {
            // Undo any zoom or nudge the reader has applied, so the tap lands on the panel that is really under the finger.
            let z = max(zoom.zoom, 0.01)
            let base = CGPoint(x: size.width / 2 + (point.x - size.width / 2 - zoom.offset.width) / z,
                               y: size.height / 2 + (point.y - size.height / 2 - zoom.offset.height) / z)
            if let hit = PanelCanvas.panel(at: base, image: img, panels: model.panels,
                                           panelIndex: model.panelIndex, size: size, fill: 0.96) {
                if hit == model.panelIndex && chromeVisible {
                    hideChrome()          // menu and page bar are up: the first tap just puts them away
                    return
                }
                hideChrome()
                if hit != model.panelIndex {
                    // Zoom back and fly to the panel as one movement (same spring as the camera), so it does not skip.
                    withAnimation(.spring(response: 0.46, dampingFraction: 0.9)) {
                        zoom.set(zoom: 1, offset: .zero)
                        model.focus(panel: hit)
                    }
                } else {
                    // A single tap on the panel you are already on: back out to the whole page.
                    withAnimation(.spring(response: 0.46, dampingFraction: 0.9)) {
                        zoom.set(zoom: 1, offset: .zero)
                        model.showOverview()
                    }
                }
                return
            }
        }
        if isZoomed { return }
        chromeVisible.toggle()
        if chromeVisible { scheduleHide() }
    }

    private func resetZoomInstantly() {
        zoom.set(zoom: 1, offset: .zero)
    }

    // MARK: Manual zoom

    private var isZoomed: Bool { return zoom.isZoomed }

    private func resetZoom() { zoom.reset() }

    /// Pinching while a panel is focused: show the whole page, keeping exactly what is on screen, so the page can be explored.
    private func leavePanel(size: CGSize) {
        guard model.panelIndex >= 0, let img = model.image else { return }
        let cam = PanelCanvas.camera(image: img, panels: model.panels, panelIndex: model.panelIndex, size: size, fill: 0.96)
        let z = zoom.zoom
        let newZoom = z * cam.zoom
        let newOffset = CGSize(width: z * cam.dx + zoom.offset.width, height: z * cam.dy + zoom.offset.height)
        zoom.converting = true
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            model.showOverview(keepingPlace: true)
            zoom.set(zoom: newZoom, offset: newOffset)    // no clamp: the screen must look exactly as it did
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { zoom.converting = false }
    }

    /// Double-tap: zoom in on the spot you tapped, or zoom back out.
    private func doubleTap(at point: CGPoint, size: CGSize) {
        if isZoomed { resetZoom(); return }
        let z: CGFloat = 2.5
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let off = CGSize(width: (point.x - c.x) * (1 - z), height: (point.y - c.y) * (1 - z))
        hideChrome()
        withAnimation(.easeOut(duration: 0.25)) {
            zoom.set(zoom: z, offset: zoom.clamp(off, zoom: z, size: size))
        }
    }

    /// Swipe left/right turns the page, swipe up opens the Companion, swipe down shows the menu (or closes the Companion).
    private func handleDrag(_ t: CGSize) {
        let dx = t.width
        let dy = t.height
        if abs(dx) > 50 && abs(dx) > abs(dy) * 1.3 {
            let swipedLeft = dx < 0
            hideChrome()
            // Swiping left goes forward (right-to-left comics swipe the other way): the next page when the whole page
            // is showing, the next panel when you are on a panel.
            model.step(forward: model.rtl ? !swipedLeft : swipedLeft)
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
            if Task.isCancelled || scrubbing { return }          // never hide the bar while it is being used
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
            Toggle(isOn: verticalBinding) { Label("Vertical Scrolling", systemImage: "arrow.up.and.down.text.horizontal") }
            if !vertical {
                Toggle(isOn: snapBinding) { Label("Snap Panel to Panel", systemImage: "rectangle.split.2x2") }
            }
            Divider()
            if !model.panels.isEmpty && !vertical {
                Button { model.toggleOverview() } label: {
                    Label(model.panelIndex < 0 ? "Zoom to first panel" : "Show whole page", systemImage: "viewfinder")
                }
            }
            Button { toggleCompanion() } label: { Label("Companion", systemImage: "sparkles") }
            Button { model.reachedEnd = true; close() } label: { Label("Mark as Read and Close", systemImage: "checkmark.circle") }
            Divider()
            Button { close() } label: { Label("Back to Library", systemImage: "chevron.down") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private var positionText: String {
        var s = "Page \(model.pageIndex + 1) of \(model.pageCount)"
        if !vertical && model.panelIndex >= 0 && !model.panels.isEmpty {
            s += "  ·  Panel \(model.panelIndex + 1)/\(model.panels.count)"
        }
        return s
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                if !vertical {
                    Button(action: { model.toggleOverview() }) {
                        Image(systemName: model.panelIndex < 0 ? "viewfinder" : "rectangle.expand.vertical")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                if model.pageCount > 1 {
                    PageScrubber(
                        value: $scrub,
                        pageCount: model.pageCount,
                        thumbnail: { page in await model.thumbnail(page: page) },
                        onActive: { active in
                            scrubbing = active
                            if active { hideTask?.cancel() } else { scheduleHide() }
                        },
                        onJump: { page in
                            if vertical { scrollTarget = page; model.setVisiblePage(page) } else { model.jump(toPage: page) }
                        }
                    )
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
                .accessibilityIdentifier("companion-button")
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
            Text("The End")
                .font(.title3.weight(.bold))
            Text(entry.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 10) {
                Button("Keep Reading") { model.reachedEnd = false }
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
