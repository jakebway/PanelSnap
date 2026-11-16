import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading") {
                    Toggle("Snap panel to panel", isOn: $settings.snapToPanels)
                    Toggle("Show the whole page first", isOn: $settings.showFullPageFirst)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Panel zoom")
                            Spacer()
                            Text(settings.panelFill > 0.97 ? "Tight" : (settings.panelFill < 0.9 ? "Roomy" : "Balanced"))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.panelFill, in: 0.78...1.0)
                            .tint(Theme.accent)
                    }
                    Toggle("Haptic feedback", isOn: $settings.haptics)
                    Toggle("Keep screen awake", isOn: $settings.keepAwake)
                }

                Section(header: Text("Companion"),
                        footer: Text("Without a key you still get Wikipedia info and anything stored inside your comic files. A Comic Vine key adds characters, creators, story arcs and issue summaries for most Marvel, DC, Image and indie comics.")) {
                    Toggle("Look up comics online", isOn: $settings.onlineLookup)
                    Toggle("Spoiler shield", isOn: $settings.spoilerShield)
                    SecureField("Comic Vine API key (optional)", text: $settings.comicVineKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let url = URL(string: "https://comicvine.gamespot.com/api/") {
                        Link("Get a free Comic Vine key", destination: url)
                    }
                }

                Section("Storage") {
                    Button("Clear downloaded info & panel cache") {
                        try? FileManager.default.removeItem(at: Paths.companionCache)
                        try? FileManager.default.removeItem(at: Paths.panelCache)
                        cleared = true
                    }
                    if cleared {
                        Text("Done. Panels and info will be rebuilt as you read.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("About") {
                    HStack {
                        Text("PanelSnap")
                        Spacer()
                        Text("1.0").foregroundStyle(.secondary)
                    }
                    Text("Panel detection runs entirely on your iPhone. Your comics never leave your device; only the series name and issue number are used for lookups.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
