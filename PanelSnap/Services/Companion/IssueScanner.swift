import Foundation
import Vision
import CoreGraphics

/// Where one issue of a collected edition (an omnibus, a trade, a "complete collection") starts inside the file.
struct IssueMark: Codable, Hashable {
    var page: Int          // 0-based page where the issue begins
    var issue: String      // "3"
    var series: String?    // the series name printed on that page, if it could be read ("THE AMAZING SPIDER-MAN")
    var year: Int? = nil   // the year of that run, when the collection's description says
}

/// What the page scan has read so far. Saved as it goes, so closing the comic never loses the work.
struct ScanState: Codable {
    var done: Set<Int> = []
    var candidates: [IssueScanner.Candidate] = []
    var finished = false
}

/// Finds the issue boundaries inside a collected edition by reading the printed text on each page: a title or credits
/// page carries the series name, the issue number ("#3") and a list of credits. Everything runs on the device.
enum IssueScanner {

    struct Line {
        var text: String
        var height: CGFloat          // 0...1, how tall the line is compared to the page
    }

    struct Candidate: Hashable, Codable {
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

    /// Drops the second sighting of an issue (cover and title page of the same issue sit close together), and any
    /// stray mention that is neither the next number up nor a restart at #1-#3 (a new series inside the collection).
    static func choose(_ all: [Candidate]) -> [Candidate] {
        var seq: [Candidate] = []
        for c in all.sorted(by: { $0.page < $1.page }) {
            if let last = seq.last {
                if last.issue == c.issue, c.page - last.page <= 8 { continue }
                if !(c.issue > last.issue || c.issue <= 3) { continue }
            }
            seq.append(c)
        }
        return seq
    }

    /// Lines the sightings up with the issues the description promised, in order. Numbers can repeat (#1-4 then #1-12),
    /// so this matches the two lists as sequences instead of trusting numbers alone.
    static func align(_ all: [Candidate], plan: [PlannedIssue]) -> [IssueMark] {
        var cands: [Candidate] = []
        for c in all.sorted(by: { $0.page < $1.page }) {
            if let last = cands.last, last.issue == c.issue, c.page - last.page <= 8 { continue }
            cands.append(c)
        }
        let n = cands.count, m = plan.count
        guard n > 0, m > 0 else { return [] }
        var dp = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                var best = max(dp[i - 1][j], dp[i][j - 1])
                if cands[i - 1].issue == plan[j - 1].issue {
                    let bonus = similar(cands[i - 1].series, plan[j - 1].series) ? 0.5 : 0
                    best = max(best, dp[i - 1][j - 1] + 1 + bonus)
                }
                dp[i][j] = best
            }
        }
        var out: [IssueMark] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            if cands[i - 1].issue == plan[j - 1].issue,
               abs(dp[i][j] - (dp[i - 1][j - 1] + 1 + (similar(cands[i - 1].series, plan[j - 1].series) ? 0.5 : 0))) < 0.0001 {
                out.append(IssueMark(page: cands[i - 1].page, issue: String(cands[i - 1].issue), series: plan[j - 1].series, year: plan[j - 1].year))
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return out.reversed()
    }

    private static func words(_ s: String?) -> Set<String> {
        guard let s = s else { return [] }
        let parts = s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(parts.filter { $0.count > 3 })
    }

    private static func similar(_ a: String?, _ b: String?) -> Bool {
        return !words(a).isDisjoint(with: words(b))
    }

    /// With the description's list: any match counts. Without it: needs two sightings so one stray "#2" is not believed.
    static func marks(from candidates: [Candidate], plan: [PlannedIssue]) -> [IssueMark] {
        if plan.count >= 2 {
            let aligned = align(candidates, plan: plan)
            if !aligned.isEmpty { return aligned }
        }
        return marks(from: candidates)
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

    /// Reads pages starting at the one you are on and working backwards (the issue you are in began before it), then
    /// forwards, then whatever is left. Reports as it finds things, and keeps going from where it stopped next time.
    static func scan(source: ComicSource, id: UUID, from start: Int, state: ScanState, progress: @escaping (ScanState) -> Void) async -> ScanState {
        var st = state
        let n = source.pageCount
        guard n > 0 else { st.finished = true; return st }
        let s0 = max(0, min(start, n - 1))
        let order = (Array(stride(from: s0, through: 0, by: -1)) + Array(stride(from: s0 + 1, to: n, by: 1))).filter { !st.done.contains($0) }
        var log = ""
        var sinceReport = 0
        for p in order {
            if Task.isCancelled { break }
            var foundNew = false
            autoreleasepool {
                if let image = source.pageImage(at: p, maxPixel: 1100) {
                    let lines = recognize(image)
                    if let c = candidate(page: p, lines: lines) { st.candidates.append(c); foundNew = true }
                    log += "page \(p + 1): " + lines.prefix(6).map { "\($0.text)(\(String(format: "%.3f", $0.height)))" }.joined(separator: " | ")
                        + (foundNew ? "  => issue \(st.candidates.last?.issue ?? 0)" : "") + "\n"
                } else {
                    log += "page \(p + 1): could not be read\n"
                }
            }
            st.done.insert(p)
            sinceReport += 1
            if foundNew || sinceReport >= 8 {
                progress(st)
                sinceReport = 0
                if st.done.count % 16 == 0 { writeState(id, st) }
            }
            await Task.yield()
        }
        if !Task.isCancelled { st.finished = true }
        writeState(id, st)
        try? log.write(to: Paths.companionCache.appendingPathComponent("scan-log.txt"), atomically: true, encoding: .utf8)
        progress(st)
        return st
    }

    // MARK: Remembering the result

    private static func stateFile(_ id: UUID) -> URL {
        return Paths.companionCache.appendingPathComponent(id.uuidString + "-scan-v2.json")
    }

    static func readState(_ id: UUID) -> ScanState? {
        guard let data = try? Data(contentsOf: stateFile(id)) else { return nil }
        return try? JSONDecoder().decode(ScanState.self, from: data)
    }

    static func writeState(_ id: UUID, _ state: ScanState) {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateFile(id), options: .atomic) }
    }
}
