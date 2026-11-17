import Foundation
import CoreGraphics
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

/// Finds comic panels with a small neural network (the DeepPanel U-Net, Apache 2.0, by Pedro Gómez) instead of
/// rules. It looks at the whole page the way a reader does, so it copes with borderless art, panels that overlap
/// and odd layouts.
enum MLPanelDetector {
    private static let side = 224
    private static let lock = NSLock()
    private static var _status = "Not used yet"

    /// What the last page used, so a problem can be told apart from a wrong guess. Shown in Settings.
    static var status: String {
        lock.lock(); defer { lock.unlock() }
        return _status
    }
    private static func setStatus(_ s: String) {
        lock.lock(); _status = s; lock.unlock()
    }

    #if canImport(OnnxRuntimeBindings)
    private static var env: ORTEnv?
    private static var session: ORTSession?

    private static func loadSession() -> ORTSession? {
        lock.lock(); defer { lock.unlock() }
        if let s = session { return s }
        guard let path = Bundle.main.path(forResource: "deeppanel", ofType: "onnx") else {
            _status = "Model file missing"
            return nil
        }
        do {
            let e = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(2)
            let s = try ORTSession(env: e, modelPath: path, sessionOptions: options)
            env = e
            session = s
            return s
        } catch {
            Console.log("Panel model failed to load: \(error)")
            _status = "Model would not load"
            return nil
        }
    }
    #endif

    /// Panels in reading order as 0...1 rectangles (top-left origin), or nil if the model could not run.
    static func detect(image: CGImage, rtl: Bool) -> [CGRect]? {
        #if canImport(OnnxRuntimeBindings)
        guard let session = loadSession() else { return nil }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 8, ih > 8 else { return nil }

        // Fit the page into a 224 x 224 square on black, keeping its shape, as the model was trained.
        let fit = CGFloat(side) / max(iw, ih)
        let nw = ceil(iw * fit), nh = ceil(ih * fit)
        let ox = floor((CGFloat(side) - nw) / 2), oy = floor((CGFloat(side) - nh) / 2)
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        // Bitmap memory is top-down, so the vertical offset measured from the top is flipped for drawing.
        ctx.draw(image, in: CGRect(x: ox, y: CGFloat(side) - oy - nh, width: nw, height: nh))

        var input = [Float](repeating: 0, count: side * side * 3)
        for i in 0..<(side * side) {
            input[i * 3] = Float(bytes[i * 4]) / 255
            input[i * 3 + 1] = Float(bytes[i * 4 + 1]) / 255
            input[i * 3 + 2] = Float(bytes[i * 4 + 2]) / 255
        }

        let scores: [Float]
        do {
            let data = NSMutableData(bytes: input, length: input.count * MemoryLayout<Float>.size)
            let tensor = try ORTValue(tensorData: data, elementType: .float, shape: [1, NSNumber(value: side), NSNumber(value: side), 3])
            let out = try session.run(withInputs: ["input_2": tensor], outputNames: ["Identity"], runOptions: nil)
            guard let result = out["Identity"] else { return nil }
            let raw = try result.tensorData() as Data
            scores = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } catch {
            Console.log("Panel model failed to run: \(error)")
            setStatus("Model failed to run")
            return nil
        }
        if scores.count < side * side * 3 { return nil }

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
        if boxes.isEmpty { setStatus("No panels on last page"); return nil }
        setStatus("Neural network")
        return order(boxes, rtl: rtl)
        #else
        return nil
        #endif
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
            abs($0.minY - $1.minY) > 0.04 ? $0.minY < $1.minY : (rtl ? $0.minX > $1.minX : $0.minX < $1.minX)
        }
    }
}
