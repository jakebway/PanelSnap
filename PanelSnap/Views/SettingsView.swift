import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var topInset: CGFloat = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Form {
                    Section("Reading") {
                        Toggle("Snap panel to panel", isOn: $settings.snapToPanels)
                        Toggle("Show the whole page first", isOn: $settings.showFullPageFirst)
                    }

                    Section(footer: Text("Characters come from a guide built into the app. Turning this on also fetches story summaries from public sites like Wikipedia. No account or key needed.")) {
                        Toggle("Look up comic info online", isOn: $settings.onlineLookup)
                        Toggle("Hide spoilers", isOn: $settings.spoilerShield)
                    }

                    Section(header: Text("Theme"), footer: Text("Pick a ready-made look, or choose your own two colours.")) {
                        presetRow
                        ColorPicker("Main color", selection: colorBinding(\.accentHex), supportsOpacity: false)
                        ColorPicker("Second color", selection: colorBinding(\.highlightHex), supportsOpacity: false)
                        Button("Reset to comic colors") {
                            settings.accentHex = ThemePreset.comic.accent
                            settings.highlightHex = ThemePreset.comic.highlight
                        }
                        .foregroundStyle(Theme.secondary)
                    }

                    Section {
                        NavigationLink {
                            ConsoleView()
                        } label: {
                            Label("Console", systemImage: "terminal")
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .ignoresSafeArea(.container, edges: .top)       // start at the very top, level with the status widget
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .readSafeTop($topInset)
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
        .padding(.top, topInset > 20 ? 22 : 30)
        .padding(.bottom, 12)
    }
}
