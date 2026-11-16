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
                    DragGesture(minimumDistance: 24).onEnded { value in
                        handleDrag(value.translation)
                    }
                )
                .simultaneousGesture(
                    MagnificationGesture().onEnded { scale in
                        if scale < 0.85 {
                            model.showOverview()
                        } else if scale > 1.15 && model.panelIndex < 0 {
                            model.toggleOverview()
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
        if f < edge {
            if model.rtl { forward() } else { back() }
            return
        }
        if f > 1 - edge {
            if model.rtl { back() } else { forward() }
            return
        }
        if let img = model.image,
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

    /// Swipe left/right turns the page, swipe up opens the Companion, swipe down closes it.
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
            if showCompanion { showCompanion = false }
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
            try? await Task.sleep(nanoseconds: 2_800_000_000)
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
        }
        .foregroundStyle(.white)
        .padding(.leading, 16)
        .padding(.trailing, Theme.cameraWidth)      // keep clear of the Duo's corner camera
        .padding(.top, 54)
        .padding(.bottom, 22)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.65), Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
        )
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
                        .foregroundStyle(.black)
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
