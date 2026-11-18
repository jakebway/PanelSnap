import Foundation
import CoreGraphics

/// Reading order for comic panels, from the Inkwell project's pairwise model (MIT). For every pair of panels it
/// estimates how likely one is to be read before the other, from where they sit and how big they are; a panel's
/// score is the total over all the others, and panels are read from the highest score down. The model is a set of
/// 100 small decision trees, exported to InkwellOrder.json and evaluated here.
final class OrderModel {
    static let shared = OrderModel()
    /// Where to find InkwellOrder.json when it is not in the app bundle (the build machine's command-line check).
    static var resourceFolder: URL?

    private struct Trees: Decodable {
        let roots: [Int]
        let feature: [Int]
        let value: [Double]
        let yes: [Int]
        let no: [Int]
    }
    private let trees: Trees?

    private init() {
        if let url = OrderModel.resourceFolder?.appendingPathComponent("InkwellOrder.json") ?? Bundle.main.url(forResource: "InkwellOrder", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            trees = try? JSONDecoder().decode(Trees.self, from: data)
        } else {
            trees = nil
        }
        if trees == nil { Console.log("Panel order model is missing from the app") }
    }

    /// Chance that panel `a` is read before panel `b` (features as the model was trained on them).
    private func before(_ f: [Double]) -> Double {
        guard let t = trees else { return 0.5 }
        var total = 0.0
        for root in t.roots {
            var k = root
            while t.feature[k] >= 0 { k = f[t.feature[k]] <= t.value[k] ? t.yes[k] : t.no[k] }
            total += t.value[k]
        }
        return 1 / (1 + exp(-total))
    }

    /// Panels in reading order, or nil if the model is not available. Right-to-left pages are mirrored first,
    /// because the model learned left-to-right reading.
    func order(_ boxes: [CGRect], rtl: Bool) -> [CGRect]? {
        guard trees != nil else { return nil }
        if boxes.count < 2 { return boxes }
        let p = boxes.map { rtl ? CGRect(x: 1 - $0.maxX, y: $0.minY, width: $0.width, height: $0.height) : $0 }
        let heights = p.map { Double($0.height) }.sorted()
        let median = heights.count % 2 == 1 ? heights[heights.count / 2]
                                            : (heights[heights.count / 2 - 1] + heights[heights.count / 2]) / 2
        func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat, _ shorter: CGFloat) -> Double {
            return Double(max(0, min(a1, b1) - max(a0, b0)) / max(shorter, 1e-6))
        }
        func features(_ a: CGRect, _ b: CGRect) -> [Double] {
            let dx = Double(b.midX - a.midX)
            let vOverlap = overlap(a.minY, a.maxY, b.minY, b.maxY, min(a.height, b.height))
            let hOverlap = overlap(a.minX, a.maxX, b.minX, b.maxX, min(a.width, b.width))
            return [dx, Double(b.midY - a.midY), vOverlap, hOverlap,
                    Double(a.height / b.height), Double(a.width / b.width),
                    a.midX < 0.5 ? 1 : 0, b.midX < 0.5 ? 1 : 0, a.midY < 0.5 ? 1 : 0, b.midY < 0.5 ? 1 : 0,
                    Double(a.height) > 1.4 * median ? 1 : 0, Double(b.height) > 1.4 * median ? 1 : 0,
                    Double(boxes.count) / 20, (vOverlap >= 0.3 && dx > 0) ? 1 : 0]
        }
        var score = [Double](repeating: 0, count: boxes.count)
        for i in 0..<boxes.count {
            for j in 0..<boxes.count where j != i { score[i] += before(features(p[i], p[j])) }
        }
        return boxes.indices.sorted { score[$0] != score[$1] ? score[$0] > score[$1] : $0 < $1 }.map { boxes[$0] }
    }
}
