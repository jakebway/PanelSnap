import SwiftUI
import WebKit

struct WebHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// A small, ad-free browser. Download a comic file anywhere and it lands in the library.
struct BrowserView: View {
    @ObservedObject private var model = BrowserModel.shared
    @ObservedObject private var shield = BrowserShield.shared
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var topInset: CGFloat = 0
    @State private var landscape = false
    @State private var text = ""
    @FocusState private var focused: Bool

    /// Keep the address bar clear of the Duo's corner status widget (it sits in the status bar when held upright).
    private var barTrailing: CGFloat { return (topInset > 20 && !landscape) ? 0 : Theme.cameraWidth }
    private var barTop: CGFloat { return topInset > 20 ? (landscape ? 22 : 8) : 30 }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            FullWidthCentered {
                VStack(spacing: 0) {
                    topBar
                    content
                    downloadsStrip
                    bottomBar
                }
            }
        }
        .readSafeTop($topInset)
        .readLandscape($landscape)
        .task {
            model.attach(library)
            await model.prepare()
        }
        .onChange(of: model.addressText) { _, new in if !focused { text = new } }
        .onChange(of: focused) { _, now in
            if now { model.beginEditing(); text = model.addressText } else { model.endEditing(); text = model.addressText }
        }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: { CircleIcon(systemName: "xmark") }
                .accessibilityLabel("Close Browser")
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(shield.isReady ? Theme.accent : Theme.secondary)
                TextField("Search or type a web address", text: $text)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .foregroundStyle(.white)
                    .onSubmit {
                        model.go(text)
                        focused = false
                    }
                if focused && !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Theme.card2, in: Capsule())
        }
        .padding(.leading, 20)
        .padding(.trailing, 20 + barTrailing)
        .padding(.top, barTop)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if let wv = model.webView {
                WebHost(webView: wv)
                    .opacity(model.hasPage ? 1 : 0)
            }
            if !model.hasPage { startPage }
            if model.isLoading && model.hasPage {
                VStack {
                    ProgressView(value: model.progress)
                        .tint(Theme.accent)
                    Spacer()
                }
            }
            if let n = model.notice {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Text(n.text)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white)
                        if let url = n.openURL {
                            Button("Open") {
                                model.webView?.load(URLRequest(url: url))
                                model.notice = nil
                            }
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.card2, in: Capsule())
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                    .padding(.bottom, 12)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: model.notice?.id)
    }

    private var startPage: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Theme.card)
                    .frame(width: 96, height: 96)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 42))
                    .foregroundStyle(Theme.accent)
            }
            Text(shield.isReady ? "Ad-Free Browsing" : shield.status.isEmpty ? "Getting ready…" : shield.status)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if !shield.isReady {
                ProgressView().tint(Theme.accent)
                Text("This only happens the first time.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            } else {
                Text("Ads, trackers and pop-ups are blocked. Download a comic file from any site and it is added to your library automatically.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 28)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var downloadsStrip: some View {
        VStack(spacing: 8) {
            ForEach(model.downloads.prefix(3)) { item in
                downloadRow(item)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, model.downloads.isEmpty ? 0 : 8)
        .animation(.easeInOut(duration: 0.2), value: model.downloads.count)
    }

    private func downloadRow(_ item: BrowserDownload) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: item.state))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint(for: item.state))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch item.state {
                case .downloading:
                    ProgressView(value: item.progress).tint(Theme.accent)
                    Text(detail(item)).font(.caption2).foregroundStyle(Theme.secondary)
                case .adding:
                    Text("Adding to your library…").font(.caption).foregroundStyle(Theme.secondary)
                case .done(let s):
                    Text(s).font(.caption).foregroundStyle(Theme.secondary)
                case .failed(let s):
                    Text(s).font(.caption).foregroundStyle(Theme.red)
                }
            }
            Spacer(minLength: 0)
            if case .downloading = item.state {} else if case .adding = item.state {} else {
                Button { model.dismissDownload(item.id) } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func detail(_ d: BrowserDownload) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        var parts: [String] = []
        if d.total > 0 { parts.append("\(f.string(fromByteCount: d.bytes)) of \(f.string(fromByteCount: d.total))") }
        if d.speed > 1000 { parts.append("\(f.string(fromByteCount: Int64(d.speed)))/s") }
        if d.fast { parts.append("fast mode") }
        return parts.joined(separator: " · ")
    }

    private func icon(for s: BrowserDownload.State) -> String {
        switch s {
        case .downloading: return "arrow.down.circle.fill"
        case .adding: return "books.vertical.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func tint(for s: BrowserDownload.State) -> Color {
        switch s {
        case .failed: return Theme.red
        default: return Theme.accent
        }
    }

    private var bottomBar: some View {
        HStack {
            barButton("chevron.left", enabled: model.canGoBack) { model.webView?.goBack() }
            Spacer()
            barButton("chevron.right", enabled: model.canGoForward) { model.webView?.goForward() }
            Spacer()
            barButton(model.isLoading ? "xmark" : "arrow.clockwise", enabled: model.hasPage) { model.reloadOrStop() }
        }
        .padding(.horizontal, 40)
        .frame(height: 50)
        .background(Theme.card)
    }

    private func barButton(_ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(enabled ? Color.white : Theme.secondary.opacity(0.45))
                .frame(width: 54, height: 44)
        }
        .disabled(!enabled)
    }
}
