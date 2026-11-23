import Foundation

enum ComicFormat: String, Codable, Hashable {
    case cbz, cbr, cb7, pdf, epub, other

    var label: String {
        switch self {
        case .cbz: return "CBZ"
        case .cbr: return "CBR"
        case .cb7: return "CB7"
        case .pdf: return "PDF"
        case .epub: return "EPUB"
        case .other: return "COMIC"
        }
    }

    static func from(fileExtension ext: String) -> ComicFormat {
        switch ext.lowercased() {
        case "cbz", "zip": return .cbz
        case "cbr", "rar": return .cbr
        case "cb7", "7z": return .cb7
        case "pdf": return .pdf
        case "epub": return .epub
        default: return .other
        }
    }
}

/// One comic in the library.
struct ComicEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var fileName: String          // name of the stored copy inside the Comics folder
    var originalName: String
    var title: String
    var series: String?
    var issue: String?
    var format: ComicFormat
    var pageCount: Int
    var addedAt: Date
    var lastOpenedAt: Date?
    var lastPage: Int
    var lastPanel: Int            // -1 = whole-page view
    var finished: Bool
    var isManga: Bool
    var shelf: String? = nil      // name of the shelf this comic sits on, if any
    var optimized: Bool? = nil    // true once stored as HEIC pages at screen size

    var progress: Double {
        if finished { return 1 }
        if pageCount <= 1 { return 0 }
        return min(1, max(0, Double(lastPage) / Double(pageCount - 1)))
    }

    var hasStarted: Bool { return lastPage > 0 || lastPanel > 0 || finished }
}

/// What we learn about a comic from its own files + file name (works offline).
struct ComicIdentity: Codable, Hashable {
    var series: String?
    var issue: String?
    var title: String?
    var volume: String?
    var year: Int?
    var publisher: String?
    var imprint: String?
    var summary: String?
    var writers: [String] = []
    var pencillers: [String] = []
    var inkers: [String] = []
    var colorists: [String] = []
    var letterers: [String] = []
    var coverArtists: [String] = []
    var editors: [String] = []
    var genres: [String] = []
    var characters: [String] = []
    var teams: [String] = []
    var locations: [String] = []
    var storyArc: String?
    var seriesGroup: String?
    var web: String?
    var isManga: Bool = false
    var rtl: Bool = false
    var ageRating: String?
    var languageISO: String?

    var displayTitle: String {
        var s = series ?? title ?? "Untitled"
        if let n = issue, !n.isEmpty { s += " #" + n }
        return s
    }
}
