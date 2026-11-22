import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One issue a collected edition says it contains.
struct PlannedIssue: Codable, Hashable {
    var series: String
    var year: Int?
    var issue: Int
}

/// Collected editions usually say what is inside: "Collects Giant-Size Avengers (1974) #4, Vision and the Scarlet Witch
/// (1982) #1-4 ...". Reading that first tells the page scan exactly which issues to look for, in which order.
enum IssuePlan {

    /// Plain text parsing. Works everywhere and needs no model.
    static func parse(_ text: String) -> [PlannedIssue] {
        let pattern = "([A-Z0-9][^#,;()\\n]*?)\\s*(?:\\((\\d{4})\\))?\\s*(?:issues?\\s*)?#\\s?(\\d{1,4})(?:\\s*[-–—]\\s*#?(\\d{1,4}))?"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [PlannedIssue] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var name = ns.substring(with: m.range(at: 1))
            if let r = name.range(of: ". ", options: .backwards) { name = String(name[r.upperBound...]) }   // drop a sentence before the list
            name = cleanName(name)
            guard name.filter({ $0.isLetter }).count >= 3, name.count <= 70 else { continue }
            let year = m.range(at: 2).location != NSNotFound ? Int(ns.substring(with: m.range(at: 2))) : nil
            guard let first = Int(ns.substring(with: m.range(at: 3))), first > 0 else { continue }
            var last = first
            if m.range(at: 4).location != NSNotFound, let b = Int(ns.substring(with: m.range(at: 4))), b > first, b - first <= 300 { last = b }
            for n in first...last { out.append(PlannedIssue(series: name, year: year, issue: n)) }
            if out.count > 600 { break }
        }
        return out
    }

    private static func cleanName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " :-–—\n\t"))
        let lead = "^(?:collects?|collecting|collected|includes?|including|reprints?|reprinting|contains?|containing|material from|featuring|from|and|&)\\b[:\\s]*"
        while let r = s.range(of: lead, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: " :-–—\n\t"))
        }
        return s
    }

    /// Uses the on-device language model when the text lists issues without "#" numbers ("issues one through twelve").
    /// Returns nothing when the model isn't available.
    static func askModel(_ text: String) async -> [PlannedIssue] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return [] }
            do {
                let session = LanguageModelSession(instructions: "You read the description of a collected edition of comics and list the original issues it reprints. Only list issues the text states. Do not guess.")
                let r = try await session.respond(to: "Description:\n" + String(text.prefix(2500)), generating: PlanList.self)
                var out: [PlannedIssue] = []
                for item in r.content.items where item.first > 0 && item.last >= item.first && item.last - item.first <= 300 {
                    let name = item.series.trimmingCharacters(in: .whitespaces)
                    if name.count < 3 { continue }
                    for n in item.first...item.last { out.append(PlannedIssue(series: name, year: item.year > 1900 ? item.year : nil, issue: n)) }
                }
                return out
            } catch { return [] }
        }
        #endif
        return []
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct PlanItem {
    @Guide(description: "The series title of the original comic, for example \"Vision and the Scarlet Witch\"")
    var series: String
    @Guide(description: "The year that series started, or 0 if the text does not say")
    var year: Int
    @Guide(description: "The first issue number reprinted from this series")
    var first: Int
    @Guide(description: "The last issue number reprinted from this series; the same as first when only one issue")
    var last: Int
}

@available(iOS 26.0, *)
@Generable
struct PlanList {
    @Guide(description: "Every series run reprinted in the collection, in the order the text lists them")
    var items: [PlanItem]
}
#endif
