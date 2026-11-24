import Foundation
import SwiftUI
import UIKit

/// Simple, UserDefaults-backed app settings.
final class AppSettings: ObservableObject {

    private let defaults = UserDefaults.standard

    @Published var snapToPanels: Bool { didSet { defaults.set(snapToPanels, forKey: "snapToPanels") } }
    @Published var compressDownloads: Bool { didSet { defaults.set(compressDownloads, forKey: "compressDownloads") } }
    @Published var onlineLookup: Bool { didSet { defaults.set(onlineLookup, forKey: "onlineLookup") } }
    @Published var showDiscover: Bool { didSet { defaults.set(showDiscover, forKey: "showDiscover") } }
    @Published var spoilerShield: Bool { didSet { defaults.set(spoilerShield, forKey: "spoilerShield") } }
    @Published var librarySort: LibrarySort { didSet { defaults.set(librarySort.rawValue, forKey: "librarySort") } }
    /// Theme colours, stored as hex ("FFD11A"). Changing them updates `Theme` straight away.
    @Published var accentHex: String { didSet { defaults.set(accentHex, forKey: "accentHex"); Theme.apply(accent: accentHex, highlight: highlightHex) } }
    @Published var highlightHex: String { didSet { defaults.set(highlightHex, forKey: "highlightHex"); Theme.apply(accent: accentHex, highlight: highlightHex) } }

    var themeKey: String { return accentHex + highlightHex }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "snapToPanels": true,
            "wholePageFirst": true,
            "onlineLookup": true,
            "spoilerShield": true,
            "showDiscover": true,
            "compressDownloads": true
        ])
        compressDownloads = d.bool(forKey: "compressDownloads")
        snapToPanels = d.bool(forKey: "snapToPanels")
        onlineLookup = d.bool(forKey: "onlineLookup")
        spoilerShield = d.bool(forKey: "spoilerShield")
        showDiscover = d.bool(forKey: "showDiscover")
        librarySort = LibrarySort(rawValue: d.string(forKey: "librarySort") ?? "") ?? .recent
        accentHex = d.string(forKey: "accentHex") ?? ThemePreset.comic.accent
        highlightHex = d.string(forKey: "highlightHex") ?? ThemePreset.comic.highlight
        Theme.apply(accent: accentHex, highlight: highlightHex)
    }
}

/// Ready-made colour pairs: a main colour (buttons, highlights) and a second colour (title bar, glow, progress).
struct ThemePreset: Identifiable {
    let name: String
    let accent: String
    let highlight: String
    var id: String { return name }

    static let comic = ThemePreset(name: "Comic", accent: "FFD11A", highlight: "ED1C24")
    static let all: [ThemePreset] = [
        comic,
        ThemePreset(name: "Sakura", accent: "FF7FB6", highlight: "8E44FF"),
        ThemePreset(name: "Ocean", accent: "3DD6FF", highlight: "2F6BFF"),
        ThemePreset(name: "Toxic", accent: "8CFF4F", highlight: "7A2CFF"),
        ThemePreset(name: "Sunset", accent: "FF9F1C", highlight: "E6007A"),
        ThemePreset(name: "Mono", accent: "F2F2F2", highlight: "7A7A7A")
    ]
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// Black or white, whichever reads better on top of this colour.
    var readableOn: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.58 ? Color.black : Color.white
    }
}

/// How the library grid is ordered.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, added, title, custom
    var id: String { return rawValue }
    var label: String {
        switch self {
        case .recent: return "Recently Read"
        case .added: return "Recently Added"
        case .title: return "Title A–Z"
        case .custom: return "My Order"
        }
    }
    var icon: String {
        switch self {
        case .recent: return "clock"
        case .added: return "plus.circle"
        case .title: return "textformat.abc"
        case .custom: return "hand.draw"
        }
    }
}

enum Theme {
    /// Main colour (comic yellow by default): confirm buttons, progress and highlights. Changeable in Settings.
    static var accent = Color(hex: ThemePreset.comic.accent)
    /// Text / icons that sit on top of the main colour.
    static var onAccent = Color.black

    static func apply(accent a: String, highlight h: String) {
        accent = Color(hex: a)
        onAccent = accent.readableOn
        red = Color(hex: h)
    }
    /// Manga / comic red: the second brand colour, used for headers, shadows and glow.
    static var red = Color(hex: ThemePreset.comic.highlight)
    static let bg = Color.black                    // true OLED black
    static let card = Color(white: 0.10)
    static let card2 = Color(white: 0.16)
    static let stroke = Color(white: 0.22)
    static let secondary = Color(white: 0.62)
    /// The iPhone Duo's corner camera + status widget: keep controls out of this top-right box (points).
    static let cameraWidth: CGFloat = 112
    static let cameraHeight: CGFloat = 164
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
    static var comics: URL {
        // A small note next to the Comics folder: it keeps the app's folder showing up in Files › On My iPhone.
        let note = documents.appendingPathComponent("Put comics in the Comics folder.txt")
        if !FileManager.default.fileExists(atPath: note.path) {
            try? "Drop CBZ, CBR, CB7, PDF or EPUB files into the Comics folder. PanelSnap adds them to your library by itself."
                .write(to: note, atomically: true, encoding: .utf8)
        }
        return ensure(documents.appendingPathComponent("Comics", isDirectory: true))
    }

    /// Opens the Files app on this app's folder.
    static func showInFiles() {
        _ = comics
        if let url = URL(string: "shareddocuments://" + documents.path) { UIApplication.shared.open(url) }
    }
    static var covers: URL { return ensure(support.appendingPathComponent("Covers", isDirectory: true)) }
    static var panelCache: URL { return ensure(support.appendingPathComponent("Panels", isDirectory: true)) }
    static var companionCache: URL { return ensure(caches.appendingPathComponent("Companion", isDirectory: true)) }
    static var libraryFile: URL { return support.appendingPathComponent("library.json") }
}
