import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading") {
                    Toggle("Snap panel to panel", isOn: $settings.snapToPanels)
                    Toggle("Show the whole page first", isOn: $settings.showFullPageFirst)
                }

                Section(footer: Text("A free Comic Vine key adds characters and story arcs.")) {
                    Toggle("Look up comic info online", isOn: $settings.onlineLookup)
                    Toggle("Hide spoilers", isOn: $settings.spoilerShield)
                    if settings.onlineLookup {
                        SecureField("Comic Vine key (optional)", text: $settings.comicVineKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
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
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .buttonStyle(YellowButtonStyle(compact: true))
                }
            }
        }
    }
}
