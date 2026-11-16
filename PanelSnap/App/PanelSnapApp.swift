import SwiftUI

@main
struct PanelSnapApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var settings = AppSettings()

    init() {
        // Make the "PanelSnap" folder show up in Files > On My iPhone, with a Comics folder ready to drop files in.
        let docs = Paths.documents
        _ = Paths.comics
        let note = docs.appendingPathComponent("Put your comics in the Comics folder.txt")
        if !FileManager.default.fileExists(atPath: note.path) {
            try? "Drop CBZ, CBR, CB7, PDF or EPUB files into the Comics folder, or use Add Comics inside PanelSnap.\n"
                .write(to: note, atomically: true, encoding: .utf8)
        }
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
