import Foundation

enum IdentityBuilder {
    /// Combines what the file name says with what the file's own ComicInfo.xml says (the latter wins).
    static func make(originalName: String, source: ComicSource?) -> ComicIdentity {
        var id = FilenameParser.parse(originalName)
        guard let xml = source?.metadataXML(), let info = ComicInfoParser.parse(xml) else {
            return id
        }
        if let v = info.series, !v.isEmpty { id.series = v }
        if let v = info.issue, !v.isEmpty { id.issue = v }
        if let v = info.title, !v.isEmpty { id.title = v }
        if let v = info.volume, !v.isEmpty { id.volume = v }
        if let v = info.year { id.year = v }
        id.publisher = info.publisher ?? id.publisher
        id.imprint = info.imprint
        id.summary = info.summary
        id.writers = info.writers
        id.pencillers = info.pencillers
        id.inkers = info.inkers
        id.colorists = info.colorists
        id.letterers = info.letterers
        id.coverArtists = info.coverArtists
        id.editors = info.editors
        id.genres = info.genres
        id.characters = info.characters
        id.teams = info.teams
        id.locations = info.locations
        id.storyArc = info.storyArc
        id.seriesGroup = info.seriesGroup
        id.web = info.web
        id.isManga = info.isManga
        id.rtl = info.rtl
        id.ageRating = info.ageRating
        id.languageISO = info.languageISO
        return id
    }
}
