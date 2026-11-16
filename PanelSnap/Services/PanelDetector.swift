import CoreGraphics
import Foundation

/// Finds the panels on a comic page and returns them in reading order.
///
/// This is a clean-room implementation of well-known ideas (gutter analysis + recursive
/// XY-cut, with a connected-components pass for diagonal layouts). It does not use any
/// third-party code, so there are no licence strings attached.
///
/// Output rectangles are normalised (0...1) with a TOP-LEFT origin.
enum PanelDetector {

    static let version = 1

    private struct IRect: Equatable {
        var x0: Int
        var y0: Int
        var x1: Int   // exclusive
        var y1: Int   // exclusive
        var w: Int { return x1 - x0 }
        var h: Int { return y1 - y0 }
        var area: Int { return max(0, w) * max(0, h) }
    }

    private struct Grid {
        let width: Int
        let height: Int
        let mask: [UInt8]   // 1 = ink / artwork, 0 = background (gutter colour)
    }

    // MARK: - Public

    static func detect(image: CGImage, rtl: Bool) -> [CGRect] {
        guard let (gray, w, h) = makeGray(image: image, maxDimension: 720), w > 16, h > 16 else {
            return [CGRect(x: 0, y: 0, width: 1, height: 1)]
        }
        let bg = backgroundLevel(gray)
        var mask = [UInt8](repeating: 0, count: gray.count)
        for i in 0..<gray.count {
            let d = Int(gray[i]) - bg
            if d > 34 || d < -34 { mask[i] = 1 }
        }
        let grid = Grid(width: w, height: h, mask: mask)
        let page = IRect(x0: 0, y0: 0, x1: w, y1: h)
        let pageArea = w * h

        var rects: [IRect] = []
        let first = split(grid, page, eps: 0.004, rtl: rtl, depth: 0)
        for leaf in first {
            if leaf.area > Int(Double(pageArea) * 0.22) {
                // Big leaf: maybe a balloon bridges the gutter. Try a more forgiving cut.
                let relaxed = split(grid, leaf, eps: 0.04, rtl: rtl, depth: 0)
                let pieces = relaxed.count >= 2 ? relaxed : [leaf]
                for piece in pieces {
                    if piece.area > Int(Double(pageArea) * 0.18) {
                        let comps = components(grid, piece)
                        if comps.count >= 2 {
                            rects.append(contentsOf: readingOrder(comps, rtl: rtl))
                            continue
                        }
                    }
                    rects.append(piece)
                }
            } else {
                rects.append(leaf)
            }
        }

        // Drop specks.
        let minArea = Int(Double(pageArea) * 0.012)
        let minW = Int(Double(w) * 0.06)
        let minH = Int(Double(h) * 0.04)
        rects = rects.filter { $0.area >= minArea && $0.w >= minW && $0.h >= minH }

        if rects.isEmpty {
            if let t = trim(grid, page, eps: 0.004) {
                rects = [t]
            } else {
                rects = [page]
            }
        }

        // Normalise + a touch of breathing room.
        let pad = 0.006
        var out: [CGRect] = []
        for r in rects {
            var x0 = Double(r.x0) / Double(w) - pad
            var y0 = Double(r.y0) / Double(h) - pad
            var x1 = Double(r.x1) / Double(w) + pad
            var y1 = Double(r.y1) / Double(h) + pad
            x0 = max(0, x0)
            y0 = max(0, y0)
            x1 = min(1, x1)
            y1 = min(1, y1)
            out.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        }
        return out
    }

    // MARK: - Image -> grayscale

    private static func makeGray(image: CGImage, maxDimension: Int) -> ([UInt8], Int, Int)? {
        let srcW = image.width
        let srcH = image.height
        if srcW < 1 || srcH < 1 { return nil }
        let scale = min(1.0, Double(maxDimension) / Double(max(srcW, srcH)))
        let w = max(1, Int((Double(srcW) * scale).rounded()))
        let h = max(1, Int((Double(srcH) * scale).rounded()))
        var pixels = [UInt8](repeating: 255, count: w * h)
        let space = CGColorSpaceCreateDeviceGray()
        var ok = false
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            guard let ctx = CGContext(
                data: base,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w,
                space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            ctx.interpolationQuality = .medium
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            ok = true
        }
        if !ok { return nil }
        return (pixels, w, h)
    }

    /// Finds the colour of the gutters: either a light peak (white/cream paper) or a dark peak (black pages).
    private static func backgroundLevel(_ gray: [UInt8]) -> Int {
        var hist = [Int](repeating: 0, count: 256)
        for v in gray { hist[Int(v)] += 1 }
        var lightTotal = 0
        var lightBest = 170
        var lightBestCount = -1
        for v in 170..<256 {
            lightTotal += hist[v]
            if hist[v] > lightBestCount {
                lightBestCount = hist[v]
                lightBest = v
            }
        }
        var darkTotal = 0
        var darkBest = 0
        var darkBestCount = -1
        for v in 0..<60 {
            darkTotal += hist[v]
            if hist[v] > darkBestCount {
                darkBestCount = hist[v]
                darkBest = v
            }
        }
        return lightTotal >= darkTotal ? lightBest : darkBest
    }

    // MARK: - XY-cut

    private static func trim(_ g: Grid, _ r: IRect, eps: Double) -> IRect? {
        var x0 = r.x0
        var y0 = r.y0
        var x1 = r.x1
        var y1 = r.y1
        for _ in 0..<2 {
            if x1 - x0 < 4 || y1 - y0 < 4 { return nil }
            let rowThresh = max(1, Int(Double(x1 - x0) * eps))
            let colThresh = max(1, Int(Double(y1 - y0) * eps))
            var rows = [Int](repeating: 0, count: y1 - y0)
            var cols = [Int](repeating: 0, count: x1 - x0)
            for y in y0..<y1 {
                let base = y * g.width
                for x in x0..<x1 {
                    if g.mask[base + x] != 0 {
                        rows[y - y0] += 1
                        cols[x - x0] += 1
                    }
                }
            }
            guard let firstRow = rows.firstIndex(where: { $0 > rowThresh }),
                  let lastRow = rows.lastIndex(where: { $0 > rowThresh }),
                  let firstCol = cols.firstIndex(where: { $0 > colThresh }),
                  let lastCol = cols.lastIndex(where: { $0 > colThresh }) else {
                return nil
            }
            let nx0 = x0 + firstCol
            let nx1 = x0 + lastCol + 1
            let ny0 = y0 + firstRow
            let ny1 = y0 + lastRow + 1
            if nx0 == x0 && nx1 == x1 && ny0 == y0 && ny1 == y1 { break }
            x0 = nx0
            x1 = nx1
            y0 = ny0
            y1 = ny1
        }
        if x1 - x0 < 4 || y1 - y0 < 4 { return nil }
        return IRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    /// Returns [start, end) segments of content separated by gutters.
    private static func segments(_ counts: [Int], thresh: Int, minRun: Int, minSegment: Int) -> [(Int, Int)] {
        let n = counts.count
        var runs: [(Int, Int)] = []
        var i = 0
        while i < n {
            if counts[i] <= thresh {
                var j = i
                while j < n && counts[j] <= thresh { j += 1 }
                if j - i >= minRun && i > 0 && j < n {
                    runs.append((i, j))
                }
                i = j
            } else {
                i += 1
            }
        }
        var segs: [(Int, Int)] = []
        var start = 0
        for run in runs {
            segs.append((start, run.0))
            start = run.1
        }
        segs.append((start, n))

        // Merge segments that are too small to be a panel into their neighbour.
        var merged: [(Int, Int)] = []
        for s in segs {
            if let last = merged.last, (s.1 - s.0 < minSegment || last.1 - last.0 < minSegment) {
                merged[merged.count - 1] = (last.0, s.1)
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    private static func split(_ g: Grid, _ r: IRect, eps: Double, rtl: Bool, depth: Int) -> [IRect] {
        guard let t = trim(g, r, eps: eps) else { return [] }
        if depth > 8 { return [t] }

        var rows = [Int](repeating: 0, count: t.h)
        var cols = [Int](repeating: 0, count: t.w)
        for y in t.y0..<t.y1 {
            let base = y * g.width
            for x in t.x0..<t.x1 {
                if g.mask[base + x] != 0 {
                    rows[y - t.y0] += 1
                    cols[x - t.x0] += 1
                }
            }
        }
        let rowThresh = max(1, Int(Double(t.w) * eps))
        let colThresh = max(1, Int(Double(t.h) * eps))
        let minRunY = max(3, Int(Double(g.height) * 0.007))
        let minRunX = max(3, Int(Double(g.width) * 0.007))
        let minSegY = max(8, Int(Double(g.height) * 0.05))
        let minSegX = max(8, Int(Double(g.width) * 0.05))

        let hSegs = segments(rows, thresh: rowThresh, minRun: minRunY, minSegment: minSegY)
        if hSegs.count > 1 {
            var out: [IRect] = []
            for s in hSegs {
                let sub = IRect(x0: t.x0, y0: t.y0 + s.0, x1: t.x1, y1: t.y0 + s.1)
                out.append(contentsOf: split(g, sub, eps: eps, rtl: rtl, depth: depth + 1))
            }
            return out
        }

        var vSegs = segments(cols, thresh: colThresh, minRun: minRunX, minSegment: minSegX)
        if vSegs.count > 1 {
            if rtl { vSegs.reverse() }
            var out: [IRect] = []
            for s in vSegs {
                let sub = IRect(x0: t.x0 + s.0, y0: t.y0, x1: t.x0 + s.1, y1: t.y1)
                out.append(contentsOf: split(g, sub, eps: eps, rtl: rtl, depth: depth + 1))
            }
            return out
        }
        return [t]
    }

    // MARK: - Connected components (diagonal / irregular layouts)

    private static func components(_ g: Grid, _ r: IRect) -> [IRect] {
        let w = r.w
        let h = r.h
        if w < 8 || h < 8 { return [] }
        var seen = [Bool](repeating: false, count: w * h)
        var found: [IRect] = []
        var stack: [Int] = []

        for sy in 0..<h {
            for sx in 0..<w {
                let idx = sy * w + sx
                if seen[idx] { continue }
                if g.mask[(r.y0 + sy) * g.width + (r.x0 + sx)] == 0 { continue }
                seen[idx] = true
                stack.removeAll(keepingCapacity: true)
                stack.append(idx)
                var minX = sx
                var maxX = sx
                var minY = sy
                var maxY = sy
                while let cur = stack.popLast() {
                    let cy = cur / w
                    let cx = cur % w
                    if cx < minX { minX = cx }
                    if cx > maxX { maxX = cx }
                    if cy < minY { minY = cy }
                    if cy > maxY { maxY = cy }
                    // 4-neighbours
                    if cx > 0 { visit(g, r, w, cx - 1, cy, &seen, &stack) }
                    if cx < w - 1 { visit(g, r, w, cx + 1, cy, &seen, &stack) }
                    if cy > 0 { visit(g, r, w, cx, cy - 1, &seen, &stack) }
                    if cy < h - 1 { visit(g, r, w, cx, cy + 1, &seen, &stack) }
                }
                found.append(IRect(x0: r.x0 + minX, y0: r.y0 + minY, x1: r.x0 + maxX + 1, y1: r.y0 + maxY + 1))
            }
        }

        let minArea = Int(Double(r.area) * 0.08)
        let big = found.filter { $0.area >= minArea }
        var keep: [IRect] = []
        for c in big {
            var nested = false
            for o in big {
                if o == c { continue }
                if o.x0 <= c.x0 && o.y0 <= c.y0 && o.x1 >= c.x1 && o.y1 >= c.y1 {
                    nested = true
                    break
                }
            }
            if !nested { keep.append(c) }
        }
        return keep
    }

    private static func visit(_ g: Grid, _ r: IRect, _ w: Int, _ x: Int, _ y: Int,
                              _ seen: inout [Bool], _ stack: inout [Int]) {
        let idx = y * w + x
        if seen[idx] { return }
        if g.mask[(r.y0 + y) * g.width + (r.x0 + x)] == 0 { return }
        seen[idx] = true
        stack.append(idx)
    }

    // MARK: - Reading order for loose rectangles

    private static func readingOrder(_ rects: [IRect], rtl: Bool) -> [IRect] {
        let sorted = rects.sorted { $0.y0 < $1.y0 }
        var rows: [[IRect]] = []
        for r in sorted {
            let cy = Double(r.y0 + r.y1) / 2.0
            var placed = false
            for i in 0..<rows.count {
                let anchor = rows[i][0]
                if cy >= Double(anchor.y0) && cy <= Double(anchor.y1) {
                    rows[i].append(r)
                    placed = true
                    break
                }
            }
            if !placed { rows.append([r]) }
        }
        var out: [IRect] = []
        for row in rows {
            let ordered = row.sorted { rtl ? ($0.x0 > $1.x0) : ($0.x0 < $1.x0) }
            out.append(contentsOf: ordered)
        }
        return out
    }
}
