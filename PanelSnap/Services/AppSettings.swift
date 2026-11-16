import Foundation
import SwiftUI

/// Simple, UserDefaults-backed app settings.
final class AppSettings: ObservableObject {

    private let defaults = UserDefaults.standard

    @Published var snapToPanels: Bool { didSet { defaults.set(snapToPanels, forKey: "snapToPanels") } }
    @Published var showFullPageFirst: Bool { didSet { defaults.set(showFullPageFirst, forKey: "showFullPageFirst") } }
    @Published var panelFill: Double { didSet { defaults.set(panelFill, forKey: "panelFill") } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    @Published var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: "keepAwake") } }
    @Published var onlineLookup: Bool { didSet { defaults.set(onlineLookup, forKey: "onlineLookup") } }
    @Published var spoilerShield: Bool { didSet { defaults.set(spoilerShield, forKey: "spoilerShield") } }
    @Published var comicVineKey: String { didSet { defaults.set(comicVineKey, forKey: "comicVineKey") } }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "snapToPanels": true,
            "showFullPageFirst": false,
            "panelFill": 0.96,
            "haptics": true,
            "keepAwake": true,
            "onlineLookup": true,
            "spoilerShield": true,
            "comicVineKey": ""
        ])
        snapToPanels = d.bool(forKey: "snapToPanels")
        showFullPageFirst = d.bool(forKey: "showFullPageFirst")
        panelFill = d.double(forKey: "panelFill")
        haptics = d.bool(forKey: "haptics")
        keepAwake = d.bool(forKey: "keepAwake")
        onlineLookup = d.bool(forKey: "onlineLookup")
        spoilerShield = d.bool(forKey: "spoilerShield")
        comicVineKey = d.string(forKey: "comicVineKey") ?? ""
    }
}

enum Theme {
    /// Comic-book yellow: used for confirm buttons, progress and highlights.
    static let accent = Color(red: 1.0, green: 0.82, blue: 0.10)
    static let bg = Color.black                    // true OLED black
    static let card = Color(white: 0.10)
    static let card2 = Color(white: 0.16)
    static let stroke = Color(white: 0.22)
    static let secondary = Color(white: 0.62)
}

enum Paths {
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var documents: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("PanelSnap", isDirectory: true))
    }
    static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("PanelSnap", isDirectory: true))
    }
    static var comics: URL { return ensure(documents.appendingPathComponent("Comics", isDirectory: true)) }
    static var covers: URL { return ensure(support.appendingPathComponent("Covers", isDirectory: true)) }
    static var panelCache: URL { return ensure(support.appendingPathComponent("Panels", isDirectory: true)) }
    static var companionCache: URL { return ensure(caches.appendingPathComponent("Companion", isDirectory: true)) }
    static var libraryFile: URL { return support.appendingPathComponent("library.json") }
}
