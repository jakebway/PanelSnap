import Foundation
import CoreGraphics
import CoreML

/// Finds comic panels with a small neural network (the DeepPanel U-Net, Apache 2.0, by Pedro Gómez). It looks at
/// the whole page the way a reader does, so it copes with borderless art, inset panels and odd layouts.
/// It runs on Apple's own Core ML, which is part of iOS, so nothing outside the app is needed.
enum MLPanelDetector {
    private static let side = 224
    private static let lock = NSLock()
    private static var model: MLModel?
    private static var loadFailed = false

    private static func loadModel() -> MLModel? {
        lock.lock(); defer { lock.unlock() }
        if let m = model { return m }
        if loadFailed { return nil }
        let config = MLModelConfiguration()
        // The CPU gives exactly the answers the model was checked against; it is quick at this size.
        config.computeUnits = .cpuOnly
        do {
            var url = Bundle.main.url(forResource: "DeepPanel", withExtension: "mlmodelc")
            if url == nil, let raw = Bundle.main.url(forResource: "DeepPanel", withExtension: "mlmodel") {
                // Not compiled at build time: compile it once on the phone and keep the result.
                let kept = Paths.caches.appendingPathComponent("DeepPanel.mlmodelc")
                if !FileManager.default.fileExists(atPath: kept.path) {
                    let tmp = try MLModel.compileModel(at: raw)
                    try? FileManager.default.removeItem(at: kept)
                    try FileManager.default.moveItem(at: tmp, to: kept)
                }
                url = kept
            }
            guard let found = url else {
                Console.log("Panel model is missing from the app")
                loadFailed = true
                return nil
            }
            let m = try MLModel(contentsOf: found, configuration: config)
            model = m
            return m
        } catch {
            Console.log("Panel model failed to load: \(error)")
            loadFailed = true
            return nil
        }
    }

    /// Loads the model ahead of time so the first page does not wait for it.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = loadModel() }
    }

    /// Panels in reading order as 0...1 rectangles (top-left origin); empty when the page has none; nil if the model could not run.
    static func detect(image: CGImage, rtl: Bool) -> [CGRect]? {
        guard let model = loadModel() else { return nil }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 8, ih > 8 else { return nil }

        // Fit the page into a 224 x 224 square on black, keeping its shape, as the model was trained.
        let fit = CGFloat(side) / max(iw, ih)
        let nw = ceil(iw * fit), nh = ceil(ih * fit)
        let ox = floor((CGFloat(side) - nw) / 2), oy = floor((CGFloat(side) - nh) / 2)
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.interpolationQuality = .high
            // Bitmap memory is top-down, so the vertical offset measured from the top is flipped for drawing.
            ctx.draw(image, in: CGRect(x: ox, y: CGFloat(side) - oy - nh, width: nw, height: nh))
            return true
        }
        if !drawn { return nil }

        let count = side * side
        let scores: [Float]
        do {
            let input = try MLMultiArray(shape: [1, NSNumber(value: side), NSNumber(value: side), 3], dataType: .float32)
            let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: count * 3)
            for i in 0..<count {
                ptr[i * 3] = Float(bytes[i * 4]) / 255
                ptr[i * 3 + 1] = Float(bytes[i * 4 + 1]) / 255
                ptr[i * 3 + 2] = Float(bytes[i * 4 + 2]) / 255
            }
            let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)])
            let result = try model.prediction(from: features)
            guard let out = result.featureValue(for: "scores")?.multiArrayValue else { return nil }
            scores = readScores(out)
        } catch {
            Console.log("Panel model failed to run: \(error)")
            return nil
        }
        if scores.count < count * 3 { return nil }

        // Class 2 is "inside a panel". Label the connected blobs of it.
        var mask = [Bool](repeating: false, count: side * side)
        for i in 0..<(side * side) {
            let a = scores[i * 3], b = scores[i * 3 + 1], c = scores[i * 3 + 2]
            mask[i] = c >= a && c >= b
        }
        var seen = [Bool](repeating: false, count: side * side)
        var boxes: [CGRect] = []
        let minArea = Int(Double(nw * nh) * 0.012)
        var stack: [Int] = []
        for start in 0..<(side * side) where mask[start] && !seen[start] {
            var minX = side, maxX = 0, minY = side, maxY = 0, count = 0
            stack.append(start)
            seen[start] = true
            while let p = stack.popLast() {
                let x = p % side, y = p / side
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if x > 0, mask[p - 1], !seen[p - 1] { seen[p - 1] = true; stack.append(p - 1) }
                if x < side - 1, mask[p + 1], !seen[p + 1] { seen[p + 1] = true; stack.append(p + 1) }
                if y > 0, mask[p - side], !seen[p - side] { seen[p - side] = true; stack.append(p - side) }
                if y < side - 1, mask[p + side], !seen[p + side] { seen[p + side] = true; stack.append(p + side) }
            }
            if count < minArea { continue }
            // back to page coordinates (0...1), with a touch of breathing room
            let pad: CGFloat = 0.006
            let x0 = max(0, (CGFloat(minX) - ox) / nw - pad)
            let x1 = min(1, (CGFloat(maxX + 1) - ox) / nw + pad)
            let y0 = max(0, (CGFloat(minY) - oy) / nh - pad)
            let y1 = min(1, (CGFloat(maxY + 1) - oy) / nh + pad)
            if x1 - x0 > 0.04 && y1 - y0 > 0.03 { boxes.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) }
        }

        // Boxes can overlap on purpose: a small panel inset on top of a big one is still its own panel.
        if boxes.isEmpty { return [] }            // it ran and found no panels: a splash page
        return order(refine(boxes, image: image), rtl: rtl)
    }

    // MARK: - Splitting panels the model saw as one

    /// The model sees the page at 224 x 224, where a thin gutter can vanish and two panels merge. Each box is
    /// checked against the full page: a clean strip of gutter running all the way across it, with art or a panel
    /// frame on both sides, splits it in two.
    static func refine(_ boxes: [CGRect], image: CGImage) -> [CGRect] {
        let maxDim = 1000
        let scale = Double(maxDim) / Double(max(image.width, image.height))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        var gray = [UInt8](repeating: 255, count: w * h)
        let ok: Bool = gray.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !ok { return boxes }

        // Light gutters always count; dark ones only on pages with a dark surround.
        var edgeDark = 0, edgeLight = 0, edgeAll = 0
        func sample(_ v: UInt8) { edgeAll += 1; if v < 55 { edgeDark += 1 } else if v > 200 { edgeLight += 1 } }
        for x in 0..<w { sample(gray[x]); sample(gray[(h - 1) * w + x]) }
        for y in 0..<h { sample(gray[y * w]); sample(gray[y * w + w - 1]) }
        let darkPage = Double(edgeDark) > Double(edgeAll) * 0.6 && Double(edgeLight) < Double(edgeAll) * 0.2
        let tests: [(UInt8) -> Bool] = darkPage ? [{ $0 > 205 }, { $0 < 50 }] : [{ $0 > 205 }]

        struct Piece { var x0, y0, x1, y1: Int; var cut: Bool }
        var pieces: [Piece] = []

        func profile(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, rows: Bool, _ test: (UInt8) -> Bool) -> [Double] {
            if rows {
                return (y0..<y1).map { y in
                    var c = 0
                    for x in x0..<x1 where test(gray[y * w + x]) { c += 1 }
                    return Double(c) / Double(x1 - x0)
                }
            }
            return (x0..<x1).map { x in
                var c = 0
                for y in y0..<y1 where test(gray[y * w + x]) { c += 1 }
                return Double(c) / Double(y1 - y0)
            }
        }

        func split(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ depth: Int) {
            if depth < 6 && x1 - x0 >= 20 && y1 - y0 >= 20 {
                for rows in [true, false] {
                    for test in tests {
                        let f = profile(x0, y0, x1, y1, rows: rows, test)
                        let n = f.count
                        let lo = Int(Double(n) * 0.08), hi = n - lo
                        var i = lo
                        while i < hi {
                            if f[i] >= 0.97 {
                                var j = i
                                while j < hi && f[j] >= 0.97 { j += 1 }
                                let before = f[max(0, i - 3)..<i].min() ?? 1
                                let after = f[j..<min(n, j + 3)].min() ?? 1
                                if j - i >= 2 && j < n && before < 0.6 && after < 0.6 {
                                    let c = (i + j) / 2
                                    if rows {
                                        split(x0, y0, x1, y0 + c, depth + 1); split(x0, y0 + c, x1, y1, depth + 1)
                                    } else {
                                        split(x0, y0, x0 + c, y1, depth + 1); split(x0 + c, y0, x1, y1, depth + 1)
                                    }
                                    return
                                }
                                i = j
                            }
                            i += 1
                        }
                    }
                }
            }
            pieces.append(Piece(x0: x0, y0: y0, x1: x1, y1: y1, cut: depth > 0))
        }

        for b in boxes {
            let x0 = max(0, Int(b.minX * Double(w))), y0 = max(0, Int(b.minY * Double(h)))
            let x1 = min(w, Int((b.maxX * Double(w)).rounded(.up))), y1 = min(h, Int((b.maxY * Double(h)).rounded(.up)))
            if x1 > x0 && y1 > y0 { split(x0, y0, x1, y1, 0) }
        }

        let rects = pieces.map { p in
            (CGRect(x: Double(p.x0) / Double(w), y: Double(p.y0) / Double(h),
                    width: Double(p.x1 - p.x0) / Double(w), height: Double(p.y1 - p.y0) / Double(h)), p.cut)
        }
        func area(_ r: CGRect) -> Double { return r.isNull || r.isEmpty ? 0 : Double(r.width * r.height) }
        var kept: [CGRect] = []
        for (i, (r, cut)) in rects.enumerated() {
            if cut {
                // a piece cut off a bigger box: drop slivers and pieces that really belong to a neighbour
                if area(r) < 0.008 { continue }
                var covered = 0.0
                for (j, (o, _)) in rects.enumerated() where j != i && area(o) > area(r) { covered += area(r.intersection(o)) }
                if covered > 0.6 * area(r) { continue }
            }
            kept.append(r)
        }
        return kept.isEmpty ? boxes : kept
    }

    /// The model's answer as a flat height x width x 3 list, whatever memory layout Core ML hands back.
    private static func readScores(_ a: MLMultiArray) -> [Float] {
        let dims = a.shape.map { $0.intValue }
        let st = a.strides.map { $0.intValue }
        guard dims.count >= 3 else { return [] }
        let n = dims.count
        let (h, w, c) = (dims[n - 3], dims[n - 2], dims[n - 1])
        let (sh, sw, sc) = (st[n - 3], st[n - 2], st[n - 1])
        guard h == side, w == side, c >= 3 else { return [] }
        var out = [Float](repeating: 0, count: h * w * 3)
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
            for y in 0..<h { for x in 0..<w { for k in 0..<3 { out[(y * w + x) * 3 + k] = p[y * sh + x * sw + k * sc] } } }
        case .double:
            let p = a.dataPointer.bindMemory(to: Double.self, capacity: a.count)
            for y in 0..<h { for x in 0..<w { for k in 0..<3 { out[(y * w + x) * 3 + k] = Float(p[y * sh + x * sw + k * sc]) } } }
        default:
            for y in 0..<h { for x in 0..<w { for k in 0..<3 { out[(y * w + x) * 3 + k] = a[y * sh + x * sw + k * sc].floatValue } } }
        }
        return out
    }

    /// Reading order for boxes: cut the page into bands wherever a clean horizontal line exists, otherwise into
    /// columns, and repeat. That keeps a tall panel beside a stack of small ones in the order a person reads them.
    static func order(_ boxes: [CGRect], rtl: Bool) -> [CGRect] {
        if boxes.count <= 1 { return boxes }
        let tol: CGFloat = 0.01
        // Horizontal cut: a y that no box crosses.
        let byTop = boxes.sorted { $0.minY < $1.minY }
        var reach = byTop[0].maxY
        for i in 1..<byTop.count {
            if byTop[i].minY >= reach - tol {
                let cut = (reach + byTop[i].minY) / 2
                let top = boxes.filter { $0.midY < cut }
                let bottom = boxes.filter { $0.midY >= cut }
                if !top.isEmpty && !bottom.isEmpty { return order(top, rtl: rtl) + order(bottom, rtl: rtl) }
            }
            reach = max(reach, byTop[i].maxY)
        }
        // Vertical cut: an x that no box crosses.
        let byLeft = boxes.sorted { $0.minX < $1.minX }
        var right = byLeft[0].maxX
        for i in 1..<byLeft.count {
            if byLeft[i].minX >= right - tol {
                let cut = (right + byLeft[i].minX) / 2
                let left = boxes.filter { $0.midX < cut }
                let rest = boxes.filter { $0.midX >= cut }
                if !left.isEmpty && !rest.isEmpty {
                    return rtl ? order(rest, rtl: rtl) + order(left, rtl: rtl) : order(left, rtl: rtl) + order(rest, rtl: rtl)
                }
            }
            right = max(right, byLeft[i].maxX)
        }
        // Overlapping layout with no clean cut: top to bottom, then along the row.
        return boxes.sorted {
            let a = Int(($0.minY / 0.04).rounded()), b = Int(($1.minY / 0.04).rounded())
            return a != b ? a < b : (rtl ? $0.minX > $1.minX : $0.minX < $1.minX)
        }
    }
}
