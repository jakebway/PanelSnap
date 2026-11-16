import SwiftUI

@main
struct PanelSnapApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(settings)
                .tint(Theme.accent)
                .onOpenURL { url in
                    Task { await library.importFiles([url]) }
                }
        }
    }
}
