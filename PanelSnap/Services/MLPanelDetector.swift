import Foundation
import CoreGraphics
import CoreML

/// Finds comic panels with a small neural network, and puts them in reading order with a second small model.
/// Both come from the Inkwell project (huggingface.co/cedarrapidsboy/inkwell-panel-models): a YOLOv8-nano panel
/// detector trained on about 3,800 annotated comic pages (AGPL-3.0), and a pairwise reading-order model (MIT).
/// The detector runs on Apple's own Core ML, which is part of iOS; the ordering model is a few hundred decision
/// nodes evaluated right here, so nothing outside the app is needed.
enum MLPanelDetector {
    private static let side = 640
    private static let confidence: Float = 0.25
    private static let nmsOverlap: CGFloat = 0.45
    private static let lock = NSLock()
    private static var model: MLModel?
    private static var loadFailed = false

    private static func loadModel() -> MLModel? {
        lock.lock(); defer { lock.unlock() }
        if let m = model { return m }
        if loadFailed { return nil }
        let config = MLModelConfiguration()
        // The CPU gives exactly the answers the model was checked against; it is quick enough at this size.
        config.computeUnits = .cpuOnly
        do {
            var url = Bundle.main.url(forResource: "InkwellPanels", withExtension: "mlmodelc")
            if url == nil, let raw = Bundle.main.url(forResource: "InkwellPanels", withExtension: "mlmodel") {
                // Not compiled at build time: compile it once on the phone and keep the result.
                let kept = Paths.caches.appendingPathComponent("InkwellPanels.mlmodelc")
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

    /// Loads the models ahead of time so the first page does not wait for them.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = loadModel(); _ = OrderModel.shared }
    }

    /// Panels in reading order as 0...1 rectangles (top-left origin); empty when the page has none; nil if the model could not run.
    static func detect(image: CGImage, rtl: Bool) -> [CGRect]? {
        guard let model = loadModel() else { return nil }
        guard image.width > 8, image.height > 8 else { return nil }

        // The whole page, squeezed to 640 x 640 (the detector was trained on pages stretched this way).
        let count = side * side
        var bytes = [UInt8](repeating: 0, count: count * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        if !drawn { return nil }

        var rows: [[Float]] = []
        do {
            let input = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
            let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: count * 3)
            for i in 0..<count {
                ptr[i] = Float(bytes[i * 4]) / 255
                ptr[count + i] = Float(bytes[i * 4 + 1]) / 255
                ptr[2 * count + i] = Float(bytes[i * 4 + 2]) / 255
            }
            let features = try MLDictionaryFeatureProvider(dictionary: ["images": MLFeatureValue(multiArray: input)])
            let result = try model.prediction(from: features)
            guard let out = result.featureValue(for: "out")?.multiArrayValue else { return nil }
            let dims = out.shape.map { $0.intValue }, strides = out.strides.map { $0.intValue }
            // One row each for centre x, centre y, width, height and confidence, for every candidate box.
            guard dims.count >= 2, dims[dims.count - 2] == 5 else { return nil }
            let n = dims[dims.count - 1]
            let rs = strides[strides.count - 2], cs = strides[strides.count - 1]
            rows = (0..<5).map { r in (0..<n).map { i in readValue(out, r * rs + i * cs) } }
        } catch {
            Console.log("Panel model failed to run: \(error)")
            return nil
        }
        guard rows.count == 5, let n = rows.first?.count, n > 0 else { return nil }
        func value(_ row: Int, _ i: Int) -> Float { rows[row][i] }

        var candidates: [(rect: CGRect, score: Float)] = []
        for i in 0..<n where value(4, i) >= confidence {
            let cx = CGFloat(value(0, i)), cy = CGFloat(value(1, i)), w = CGFloat(value(2, i)), h = CGFloat(value(3, i))
            let s = CGFloat(side)
            let x0 = max(0, (cx - w / 2) / s), y0 = max(0, (cy - h / 2) / s)
            let x1 = min(1, (cx + w / 2) / s), y1 = min(1, (cy + h / 2) / s)
            if x1 - x0 > 0.04 && y1 - y0 > 0.03 {
                candidates.append((CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), value(4, i)))
            }
        }
        // Keep the most confident box of any group that mostly covers the same spot.
        candidates.sort { $0.score > $1.score }
        var boxes: [CGRect] = []
        for c in candidates {
            let a = c.rect.width * c.rect.height
            let clash = boxes.contains { b in
                let inter = c.rect.intersection(b)
                if inter.isNull { return false }
                let ia = inter.width * inter.height
                return ia / (a + b.width * b.height - ia) > nmsOverlap
            }
            if !clash { boxes.append(c.rect) }
        }
        if boxes.isEmpty { return [] }            // it ran and found no panels: a splash page
        return OrderModel.shared.order(boxes, rtl: rtl) ?? order(boxes, rtl: rtl)
    }

    /// One number from the model's answer, whatever type Core ML hands back.
    private static func readValue(_ a: MLMultiArray, _ offset: Int) -> Float {
        switch a.dataType {
        case .float32: return a.dataPointer.bindMemory(to: Float.self, capacity: offset + 1)[offset]
        case .double: return Float(a.dataPointer.bindMemory(to: Double.self, capacity: offset + 1)[offset])
        default: return a[offset].floatValue
        }
    }

    /// Backup reading order (only if the ordering model is missing): cut the page into bands wherever a clean horizontal line exists, otherwise into
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
