import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

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
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
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
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}
