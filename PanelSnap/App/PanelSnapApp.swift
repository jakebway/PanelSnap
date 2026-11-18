import SwiftUI

@main
struct PanelSnapApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var settings = AppSettings()

    init() {
        // Make the "PanelSnap" folder show up in Files > On My iPhone, with a Comics folder ready to drop files in.
        let docs = Paths.documents
        _ = Paths.comics
        Console.log("PanelSnap launched")
        MLPanelDetector.warmUp()
        // An older version left a second note beside this one; one is enough.
        try? FileManager.default.removeItem(at: docs.appendingPathComponent("Put your comics in the Comics folder.txt"))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(settings)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
                .background(Theme.bg.ignoresSafeArea())
                .onOpenURL { url in
                    Task { await library.importFiles([url]) }
                }
        }
    }
}
