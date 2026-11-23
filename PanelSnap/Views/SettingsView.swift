import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var topInset: CGFloat = 0
    @State private var landscape = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Form {
                    Section(header: Text("Reading"),
                            footer: Text(settings.snapToPanels
                                         ? "Zooms in on one panel at a time. Tap or swipe to move to the next."
                                         : "Shows whole pages. Swipe to turn the page and pinch to zoom. Panels are not detected.")) {
                        Picker("Reading Mode", selection: $settings.snapToPanels) {
                            Text("Panel by Panel").tag(true)
                            Text("Regular Pages").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }

                    Section(header: Text("Companion"), footer: Text("Character info comes from a guide built into the app. With lookups on, PanelSnap also fetches story summaries from public sources such as Wikipedia. No account or key is needed.")) {
                        Toggle("Look Up Comic Info Online", isOn: $settings.onlineLookup)
                        Toggle("Hide Spoilers", isOn: $settings.spoilerShield)
                    }

                    Section(header: Text("Theme"), footer: Text("Choose a preset, or pick your own two colors.")) {
                        presetRow
                        ColorPicker("Main Color", selection: colorBinding(\.accentHex), supportsOpacity: false)
                        ColorPicker("Second Color", selection: colorBinding(\.highlightHex), supportsOpacity: false)
                        Button("Reset to Comic Colors") {
                            settings.accentHex = ThemePreset.comic.accent
                            settings.highlightHex = ThemePreset.comic.highlight
                        }
                        .foregroundStyle(Theme.secondary)
                    }

                    Section(header: Text("Discover"), footer: Text("A browsable comic catalogue from League of Comic Geeks: search, new releases, and suggestions based on your library, with a button to search your Home website for any of them. Its button sits at the end of the shelf row on the library.")) {
                        Toggle("Show Discover", isOn: $settings.showDiscover)
                    }

                    Section(header: Text("Library"), footer: Text("Your comics are stored in Files › On My iPhone › PanelSnap › Comics.")) {
                        Button { Paths.showInFiles() } label: {
                            Label("Show Comics Folder in Files", systemImage: "folder")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .ignoresSafeArea(.container, edges: landscape ? .top : [])       // wide: start at the very top, level with the status widget
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .readSafeTop($topInset)
        .readLandscape($landscape)
    }

    private func colorBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, String>) -> Binding<Color> {
        return Binding(
            get: { Color(hex: settings[keyPath: keyPath]) },
            set: { settings[keyPath: keyPath] = $0.hexString }
        )
    }

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(ThemePreset.all) { preset in
                    let selected = settings.accentHex == preset.accent && settings.highlightHex == preset.highlight
                    Button {
                        settings.accentHex = preset.accent
                        settings.highlightHex = preset.highlight
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(LinearGradient(stops: [
                                    .init(color: Color(hex: preset.accent), location: 0.5),
                                    .init(color: Color(hex: preset.highlight), location: 0.5)
                                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 46, height: 46)
                                .overlay(Circle().strokeBorder(Color.white, lineWidth: selected ? 3 : 0))
                            Text(preset.name)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(selected ? Color.white : Theme.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Our own header, so iOS can't wrap the button in a glass bubble and clip it.
    private var header: some View {
        ZStack {
            ComicTitle(text: "Settings")
            HStack {
                Button("Done") { dismiss() }
                    .buttonStyle(YellowButtonStyle(compact: true))
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, topInset > 20 ? (landscape ? 22 : 8) : 30)
        .padding(.bottom, 12)
        // Span the whole screen, so the title sits in the true centre (the Duo's status-widget inset would
        // otherwise push it left of centre).
        .ignoresSafeArea(.container, edges: .horizontal)
    }
}
