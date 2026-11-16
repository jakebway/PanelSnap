import Foundation

/// Reads the ComicInfo.xml that most comic tools (ComicTagger, Mylar, Kavita, ...) embed in CBZ/CBR files.
final class ComicInfoParser: NSObject, XMLParserDelegate {

    private var values: [String: String] = [:]
    private var current = ""
    private var buffer = ""

    static func parse(_ data: Data) -> ComicIdentity? {
        let p = ComicInfoParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        if !xml.parse() && p.values.isEmpty { return nil }
        if p.values.isEmpty { return nil }
        return p.makeIdentity()
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        current = elementName
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && elementName != "ComicInfo" && elementName != "Pages" && elementName != "Page" {
            values[elementName.lowercased()] = text
        }
        buffer = ""
    }

    // MARK: Build

    private func list(_ key: String) -> [String] {
        guard let raw = values[key] else { return [] }
        return raw
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func makeIdentity() -> ComicIdentity {
        var id = ComicIdentity()
        id.series = values["series"]
        id.issue = values["number"]
        id.title = values["title"]
        id.volume = values["volume"]
        if let y = values["year"] { id.year = Int(y) }
        id.publisher = values["publisher"]
        id.imprint = values["imprint"]
        id.summary = values["summary"]
        id.writers = list("writer")
        id.pencillers = list("penciller")
        id.inkers = list("inker")
        id.colorists = list("colorist")
        id.letterers = list("letterer")
        id.coverArtists = list("coverartist")
        id.editors = list("editor")
        id.genres = list("genre")
        id.characters = list("characters")
        id.teams = list("teams")
        id.locations = list("locations")
        id.storyArc = list("storyarc").first
        id.seriesGroup = values["seriesgroup"]
        id.web = values["web"]
        id.ageRating = values["agerating"]
        id.languageISO = values["languageiso"]
        if let m = values["manga"]?.lowercased() {
            id.isManga = m.hasPrefix("yes")
            id.rtl = m.contains("righttoleft")
        }
        return id
    }
}
