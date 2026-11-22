import Foundation
import Vision
import CoreGraphics

/// Where one issue of a collected edition (an omnibus, a trade, a "complete collection") starts inside the file.
struct IssueMark: Codable, Hashable {
    var page: Int          // 0-based page where the issue begins
    var issue: String      // "3"
    var series: String?    // the series name ("Vision and the Scarlet Witch")
    var year: Int? = nil   // the year of that run, when the collection's description says
    var estimated: Bool? = nil   // true = worked out from the issue list and page count, not seen on the page yet
}

/// What the page scan has read so far. Saved as it goes, so closing the comic never loses the work.
struct ScanState: Codable {
    var done: Set<Int> = []
    var candidates: [IssueScanner.Candidate] = []
    var finished = false
}

/// Finds the issue boundaries inside a collected edition by reading the printed text on each page. Everything runs on the device.
enum IssueScanner {

    struct Line {
        var text: String
        var height: CGFloat          // 0...1, how tall the line is compared to the page
    }

    struct Candidate: Hashable, Codable {
        var page: Int
        var issue: Int               // 0 = the series title was seen but no number
        var series: String?
        var strong: Bool
    }

    // MARK: Is this worth scanning?

    static func looksLikeCollection(_ id: ComicIdentity, pageCount: Int) -> Bool {
        if pageCount >= 70 { return true }
        let name = ((id.series ?? "") + " " + (id.title ?? "") + " " + (id.volume ?? "")).lowercased()
        return ["omnibus", "collection", "compendium", "treasury", "complete", "epic", "library", "tpb", "vol", "saga"].contains { name.contains($0) } && pageCount >= 30
    }

    /// "Amazing Spider-Man Omnibus Vol. 1" -> "Amazing Spider-Man".
    static func baseSeries(_ name: String) -> String {
        let pattern = "\\b(omnibus|complete collection|epic collection|the complete|collection|compendium|treasury|trade paperback|tpb|hardcover|deluxe edition|vol(ume)?\\.?\\s*\\d+|book\\s*\\d+)\\b.*$"
        let s = name.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " -–:,.")).isEmpty ? name : s.trimmingCharacters(in: CharacterSet(charactersIn: " -–:,."))
    }

    // MARK: Reading one page

    private static let creditWords = ["WRITER", "WRITTEN", "STORY", "SCRIPT", "PENCIL", "PENCILS", "PENCILLER", "INKS", "INKER", "COLORS", "COLORIST",
                                      "COLOURS", "LETTERS", "LETTERER", "LETTERING", "EDITOR", "EDITED", "ARTIST", "ART BY", "COVER", "CREATED", "ASSISTANT",
                                      "PLOT", "SCRIPTER", "EDITOR-IN-CHIEF", "EDITOR IN CHIEF"]

    static func words(_ s: String?) -> Set<String> {
        guard let s = s else { return [] }
        let stop: Set<String> = ["the", "and", "of", "a", "an"]
        let parts = s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(parts.filter { $0.count > 2 && !stop.contains($0) })
    }

    static func similar(_ a: String?, _ b: String?) -> Bool {
        let wa = words(a), wb = words(b)
        if wa.isEmpty || wb.isEmpty { return false }
        return wa.intersection(wb).count >= min(2, min(wa.count, wb.count))
    }

    /// Decides from the lines of text on one page whether it opens an issue. `titles` are the series the collection
    /// says it holds: a big printed title from that list counts even without a number (old splash pages often have none).
    static func candidate(page: Int, lines: [Line], titles: [String] = []) -> Candidate? {
        let upper = lines.map { $0.text.uppercased() }
        let creditHits = Set(creditWords.filter { w in upper.contains { $0.range(of: "\\b" + w + "\\b", options: .regularExpression) != nil } })
        var best: Candidate?
        for (i, line) in lines.enumerated() {
            let t = line.text
            var number: Int?
            var before = ""
            if let r = t.range(of: "#\\s?(\\d{1,4})\\b", options: .regularExpression) {
                number = Int(t[r].filter { $0.isNumber })
                before = String(t[..<r.lowerBound])
            } else if let r = t.range(of: "\\b(?:ISSUE|NO\\.)\\s*#?\\s*(\\d{1,4})\\b", options: [.regularExpression, .caseInsensitive]) {
                number = Int(t[r].filter { $0.isNumber })
                before = String(t[..<r.lowerBound])
            }
            guard let n = number, n > 0 else { continue }
            let strong = line.height > 0.03
            if !(strong || creditHits.count >= 2) { continue }
            var series = before.trimmingCharacters(in: CharacterSet(charactersIn: " -–:,.|•"))
            if series.filter({ $0.isLetter }).count < 3, i > 0 {
                series = lines[i - 1].text.trimmingCharacters(in: CharacterSet(charactersIn: " -–:,.|•"))
            }
            if series.filter({ $0.isLetter }).count < 3 || series.count > 60 { series = "" }
            let cand = Candidate(page: page, issue: n, series: series.isEmpty ? nil : series, strong: strong)
            if best == nil || (cand.strong && !(best?.strong ?? false)) { best = cand }
        }
        if best != nil { return best }
        // No number: a large title (a cover logo or splash title) naming one of the collection's series.
        if !titles.isEmpty {
            let all = lines.map { $0.text }.joined(separator: " ")
            for line in lines where line.height > 0.025 {
                for title in titles where similar(line.text, title) || (similar(all, title) && creditHits.count >= 2) {
                    return Candidate(page: page, issue: 0, series: title, strong: line.height > 0.04)
                }
            }
        }
        return nil
    }

    /// The quick pass found something that might be an issue opener, so read the page again carefully.
    static func worthCloserLook(_ lines: [Line], titles: [String]) -> Bool {
        for l in lines {
            let u = l.text.uppercased()
            if u.contains("#") || u.contains("ISSUE") || u.contains("NO.") { return true }
            if l.height > 0.03 && l.text.contains(where: { $0.isNumber }) { return true }
            if creditWords.contains(where: { u.contains($0) }) { return true }
            if l.height > 0.025, titles.contains(where: { similar(l.text, $0) }) { return true }
        }
        return false
    }

    // MARK: Turning sightings into issue starts

    /// Without a list from the description: keep a rising run of numbers, allowing a restart at #1-#3 for a new series.
    static func choose(_ all: [Candidate]) -> [Candidate] {
        var seq: [Candidate] = []
        for c in all.sorted(by: { $0.page < $1.page }) where c.issue > 0 {
            if let last = seq.last {
                if last.issue == c.issue, c.page - last.page <= 8 { continue }
                if !(c.issue > last.issue || c.issue <= 3) { continue }
            }
            seq.append(c)
        }
        return seq
    }

    static func marks(from candidates: [Candidate]) -> [IssueMark] {
        let chosen = choose(candidates)
        guard chosen.count >= 2 else { return [] }
        var counts: [String: Int] = [:]
        for c in chosen { if let s = c.series { counts[s, default: 0] += 1 } }
        let common = counts.max(by: { $0.value < $1.value })?.key
        return chosen.map { IssueMark(page: $0.page, issue: String($0.issue), series: $0.series ?? common) }
    }

    /// Lines the sightings up with the issues the description lists, in order (numbers repeat, so order matters, and
    /// where a sighting sits in the book helps pick the right one). Issues not seen yet get an estimated start between
    /// their neighbours, so there is always an answer for any page.
    static func marks(from all: [Candidate], plan: [PlannedIssue], pageCount: Int) -> [IssueMark] {
        let m = plan.count
        guard m >= 2, pageCount > 0 else { return marks(from: all) }
        var cands: [Candidate] = []
        for c in all.sorted(by: { $0.page < $1.page }) {
            if let last = cands.last, c.page - last.page <= 8 {
                if last.issue == c.issue || c.issue == 0 { continue }
                if last.issue == 0 { cands[cands.count - 1] = c; continue }      // a number beats a bare title nearby
            }
            cands.append(c)
        }
        let n = cands.count
        func score(_ c: Candidate, _ j: Int) -> Double {
            let pos = 1 - min(1, abs(Double(c.page) / Double(pageCount) - Double(j) / Double(m)) * 4)   // 1 when it sits where expected
            if c.issue > 0 {
                guard c.issue == plan[j].issue else { return 0 }
                return 1 + (similar(c.series, plan[j].series) ? 0.5 : 0) + 0.4 * pos
            }
            guard similar(c.series, plan[j].series) else { return 0 }
            return 0.6 + 0.4 * pos
        }
        var matched: [(Int, Int)] = []          // (plan index, page)
        if n > 0 {
            var dp = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
            for i in 1...n {
                for j in 1...m {
                    var best = max(dp[i - 1][j], dp[i][j - 1])
                    let s = score(cands[i - 1], j - 1)
                    if s > 0 { best = max(best, dp[i - 1][j - 1] + s) }
                    dp[i][j] = best
                }
            }
            var i = n, j = m
            while i > 0 && j > 0 {
                let s = score(cands[i - 1], j - 1)
                if s > 0, abs(dp[i][j] - (dp[i - 1][j - 1] + s)) < 0.0001 {
                    matched.append((j - 1, cands[i - 1].page)); i -= 1; j -= 1
                } else if dp[i - 1][j] >= dp[i][j - 1] { i -= 1 } else { j -= 1 }
            }
            matched.reverse()
        }
        // Fill the gaps by spreading the unseen issues evenly between the known starts.
        var anchors: [(Double, Double)] = [(-1, Double(pageCount) * 0.015)]
        for (j, p) in matched { anchors.append((Double(j), Double(p))) }
        anchors.append((Double(m), Double(pageCount)))
        let seen = Dictionary(matched, uniquingKeysWith: { a, _ in a })
        var out: [IssueMark] = []
        var lastPage = -1
        for j in 0..<m {
            var page: Int
            let real = seen[j] != nil
            if let p = seen[j] {
                page = p
            } else {
                let lo = anchors.last(where: { $0.0 < Double(j) })!
                let hi = anchors.first(where: { $0.0 > Double(j) })!
                let f = (Double(j) - lo.0) / (hi.0 - lo.0)
                page = Int((lo.1 + (hi.1 - lo.1) * f).rounded())
            }
            page = max(page, lastPage + 1)
            if page >= pageCount { break }
            lastPage = page
            out.append(IssueMark(page: page, issue: String(plan[j].issue), series: plan[j].series, year: plan[j].year, estimated: real ? nil : true))
        }
        return out
    }

    // MARK: Reading text

    /// All text recognition goes through this one queue, so the issue scan, the page reading for Ask and the reader never
    /// run several heavy Vision requests at once (that used to pile up memory).
    private static let ocrQueue = DispatchQueue(label: "panelsnap.ocr", qos: .utility)

    static func recognize(_ image: CGImage, fast: Bool, correct: Bool = false) -> [Line] {
        return ocrQueue.sync {
            autoreleasepool {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = fast ? .fast : .accurate
                request.usesLanguageCorrection = correct
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try? handler.perform([request])
                return (request.results ?? []).compactMap { obs in
                    guard let top = obs.topCandidates(1).first else { return nil }
                    return Line(text: top.string, height: obs.boundingBox.height)
                }
            }
        }
    }

    /// The lettering on a page (balloons, captions, sound effects) in rough reading order, for the Ask feature.
    static func readDialogue(_ image: CGImage) -> String {
        return ocrQueue.sync {
            autoreleasepool {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                let obs = (request.results ?? []).sorted {
                    let a = ($0.boundingBox.midY * 12).rounded(), b = ($1.boundingBox.midY * 12).rounded()
                    return a != b ? a > b : $0.boundingBox.minX < $1.boundingBox.minX
                }
                let lines = obs.compactMap { $0.topCandidates(1).first?.string }.filter { $0.filter({ $0.isLetter }).count >= 2 }
                return lines.joined(separator: " ").replacingOccurrences(of: "- ", with: "")
            }
        }
    }

    // MARK: Scanning a whole file

    /// Reads pages starting at the one you are on and working backwards (the issue you are in began before it), then
    /// forwards. A quick pass on every page; a careful pass only on pages that look like an issue opener.
    static func scan(source: ComicSource, id: UUID, from start: Int, state: ScanState, titles: [String],
                     progress: @escaping (ScanState) -> Void) async -> ScanState {
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
                    let quick = recognize(image, fast: true)
                    var c: Candidate?
                    if worthCloserLook(quick, titles: titles) {
                        c = candidate(page: p, lines: recognize(image, fast: false), titles: titles)
                    }
                    if let c = c { st.candidates.append(c); foundNew = true }
                    log += "page \(p + 1): " + quick.prefix(5).map { "\($0.text)(\(String(format: "%.3f", $0.height)))" }.joined(separator: " | ")
                        + (c.map { "  => issue \($0.issue) \($0.series ?? "")" } ?? "") + "\n"
                }
            }
            st.done.insert(p)
            sinceReport += 1
            if foundNew || sinceReport >= 10 {
                progress(st)
                sinceReport = 0
                if st.done.count % 20 == 0 { writeState(id, st) }
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
        return Paths.companionCache.appendingPathComponent(id.uuidString + "-scan-v3.json")
    }

    static func readState(_ id: UUID) -> ScanState? {
        guard let data = try? Data(contentsOf: stateFile(id)) else { return nil }
        return try? JSONDecoder().decode(ScanState.self, from: data)
    }

    static func writeState(_ id: UUID, _ state: ScanState) {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateFile(id), options: .atomic) }
    }
}
