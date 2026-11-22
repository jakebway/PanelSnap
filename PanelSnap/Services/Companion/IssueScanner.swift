import Foundation
import Vision
import CoreGraphics

/// Where one issue of a collected edition (an omnibus, a trade, a "complete collection") starts inside the file.
struct IssueMark: Codable, Hashable {
    var page: Int          // 0-based page where the issue begins
    var issue: String      // "3"
    var series: String?    // the series name printed on that page, if it could be read ("THE AMAZING SPIDER-MAN")
}

/// Finds the issue boundaries inside a collected edition by reading the printed text on each page: a title or credits
/// page carries the series name, the issue number ("#3") and a list of credits. Everything runs on the device.
enum IssueScanner {

    struct Line {
        var text: String
        var height: CGFloat          // 0...1, how tall the line is compared to the page
    }

    struct Candidate: Hashable {
        var page: Int
        var issue: Int
        var series: String?
        var strong: Bool
    }

    // MARK: Is this worth scanning?

    static func looksLikeCollection(_ id: ComicIdentity, pageCount: Int) -> Bool {
        if pageCount >= 70 { return true }
        let name = ((id.series ?? "") + " " + (id.title ?? "") + " " + (id.volume ?? "")).lowercased()
        return ["omnibus", "collection", "compendium", "treasury", "complete", "epic", "library", "tpb", "vol"].contains { name.contains($0) } && pageCount >= 30
    }

    /// "Amazing Spider-Man Omnibus Vol. 1" -> "Amazing Spider-Man".
    static func baseSeries(_ name: String) -> String {
        let pattern = "\\b(omnibus|complete collection|epic collection|the complete|collection|compendium|treasury|trade paperback|tpb|hardcover|deluxe edition|vol(ume)?\\.?\\s*\\d+|book\\s*\\d+)\\b.*$"
        let s = name.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " -–:,.")).isEmpty ? name : s.trimmingCharacters(in: CharacterSet(charactersIn: " -–:,."))
    }

    // MARK: Reading one page

    private static let creditWords = ["WRITER", "WRITTEN", "STORY", "SCRIPT", "PENCIL", "PENCILS", "PENCILLER", "INKS", "INKER", "COLORS", "COLORIST",
                                      "COLOURS", "LETTERS", "LETTERER", "LETTERING", "EDITOR", "EDITED", "ARTIST", "ART BY", "COVER", "CREATED", "ASSISTANT"]

    /// Decides from the lines of text on one page whether it opens an issue. Pure, so it can be tested without a comic.
    static func candidate(page: Int, lines: [Line]) -> Candidate? {
        let upper = lines.map { $0.text.uppercased() }
        let creditHits = Set(creditWords.filter { w in upper.contains { $0.range(of: "\\b" + w + "\\b", options: .regularExpression) != nil } })
        var best: Candidate?
        for (i, line) in lines.enumerated() {
            let t = line.text
            var number: Int?
            var before = ""
            if let r = t.range(of: "#\\s?(\\d{1,4})\\b", options: .regularExpression) {
                let digits = t[r].filter { $0.isNumber }
                number = Int(digits)
                before = String(t[..<r.lowerBound])
            } else if let r = t.range(of: "\\bISSUE\\s*(?:NO\\.?|#)?\\s*(\\d{1,4})\\b", options: [.regularExpression, .caseInsensitive]) {
                number = Int(t[r].filter { $0.isNumber })
                before = String(t[..<r.lowerBound])
            }
            guard let n = number, n > 0 else { continue }
            let strong = line.height > 0.03
            if !(strong || creditHits.count >= 2) { continue }
            var series = before.trimmingCharacters(in: CharacterSet(charactersIn: " -–:,.|•"))
            if series.filter({ $0.isLetter }).count < 3, i > 0 {
                // The name is often stacked above the number.
                series = lines[i - 1].text.trimmingCharacters(in: CharacterSet(charactersIn: " -–:,.|•"))
            }
            if series.filter({ $0.isLetter }).count < 3 || series.count > 60 { series = "" }
            let cand = Candidate(page: page, issue: n, series: series.isEmpty ? nil : series, strong: strong)
            if best == nil || (cand.strong && !(best?.strong ?? false)) { best = cand }
        }
        return best
    }

    /// Keeps the candidates that form a rising run of issue numbers (the real issue openers) and drops stray "#2" mentions.
    static func choose(_ all: [Candidate]) -> [Candidate] {
        var seq: [Candidate] = []
        for c in all.sorted(by: { $0.page < $1.page }) {
            if let last = seq.last, last.issue == c.issue, c.page - last.page <= 8 { continue }   // cover and title page of the same issue
            seq.append(c)
        }
        guard !seq.isEmpty else { return [] }
        // Longest strictly rising run of issue numbers.
        var length = [Int](repeating: 1, count: seq.count)
        var from = [Int](repeating: -1, count: seq.count)
        for i in 0..<seq.count {
            for j in 0..<i where seq[j].issue < seq[i].issue && length[j] + 1 > length[i] {
                length[i] = length[j] + 1
                from[i] = j
            }
        }
        var bestEnd = 0
        for i in 0..<seq.count where length[i] > length[bestEnd] { bestEnd = i }
        var out: [Candidate] = []
        var k = bestEnd
        while k >= 0 { out.append(seq[k]); k = from[k] }
        return out.reversed()
    }

    static func marks(from candidates: [Candidate]) -> [IssueMark] {
        let chosen = choose(candidates)
        guard chosen.count >= 2 else { return [] }
        // The most common printed series name is used for every issue that did not print a readable one.
        var counts: [String: Int] = [:]
        for c in chosen { if let s = c.series { counts[s, default: 0] += 1 } }
        let common = counts.max(by: { $0.value < $1.value })?.key
        return chosen.map { IssueMark(page: $0.page, issue: String($0.issue), series: $0.series ?? common) }
    }

    // MARK: Scanning a whole file

    private static func recognize(_ image: CGImage) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            return Line(text: top.string, height: obs.boundingBox.height)
        }
    }

    /// Reads every page, one after another, at low priority, reporting what it has found as it goes.
    static func scan(source: ComicSource, progress: @escaping ([IssueMark]) -> Void) async -> [IssueMark] {
        var found: [Candidate] = []
        var log = ""
        defer { try? log.write(to: Paths.companionCache.appendingPathComponent("scan-log.txt"), atomically: true, encoding: .utf8) }
        for p in 0..<source.pageCount {
            if Task.isCancelled { break }
            autoreleasepool {
                if let image = source.pageImage(at: p, maxPixel: 1500) {
                    let lines = recognize(image)
                    let c = candidate(page: p, lines: lines)
                    if let c = c { found.append(c) }
                    log += "page \(p + 1): " + lines.prefix(6).map { "\($0.text)(\(String(format: "%.3f", $0.height)))" }.joined(separator: " | ")
                        + (c.map { "  => issue \($0.issue) series \($0.series ?? "-") strong \($0.strong)" } ?? "") + "\n"
                } else {
                    log += "page \(p + 1): could not be read\n"
                }
            }
            if found.count >= 2, p % 10 == 0 { progress(marks(from: found)) }
            await Task.yield()
        }
        return marks(from: found)
    }

    // MARK: Remembering the result

    private static func file(_ id: UUID) -> URL {
        return Paths.companionCache.appendingPathComponent(id.uuidString + "-issues-v1.json")
    }

    /// nil = never scanned; an empty list = scanned and no issues were found.
    static func read(_ id: UUID) -> [IssueMark]? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder().decode([IssueMark].self, from: data)
    }

    static func write(_ id: UUID, _ marks: [IssueMark]) {
        if let data = try? JSONEncoder().encode(marks) { try? data.write(to: file(id), options: .atomic) }
    }
}
