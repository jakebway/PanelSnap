// Runs the app's Core ML panel model on a test page and checks it agrees with the original network.
// CI runs this before publishing, so a broken model can never reach a release.
// Usage: swift CheckPanelModel.swift DeepPanel.mlmodel input.f32 classes.u8
import CoreML
import Foundation

let args = CommandLine.arguments
let side = 224
let count = side * side
do {
    let compiled = try MLModel.compileModel(at: URL(fileURLWithPath: args[1]))
    let model = try MLModel(contentsOf: compiled)
    let input = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let expected = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[3])))
    let x = try MLMultiArray(shape: [1, NSNumber(value: side), NSNumber(value: side), 3], dataType: .float32)
    let p = x.dataPointer.bindMemory(to: Float.self, capacity: count * 3)
    input.withUnsafeBytes { raw in
        let f = raw.bindMemory(to: Float.self)
        for i in 0..<(count * 3) { p[i] = f[i] }
    }
    let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: x)])
    guard let out = try model.prediction(from: features).featureValue(for: "scores")?.multiArrayValue else {
        print("::error::The panel model gave no answer."); exit(1)
    }
    let dims = out.shape.map { $0.intValue }, st = out.strides.map { $0.intValue }
    let n = dims.count
    print("Output shape \(dims), type \(out.dataType.rawValue)")
    var same = 0
    for y in 0..<side {
        for xx in 0..<side {
            var best = 0
            var bestV = -Float.infinity
            for k in 0..<3 {
                let v = out[y * st[n - 3] + xx * st[n - 2] + k * st[n - 1]].floatValue
                if v > bestV { bestV = v; best = k }
            }
            if UInt8(best) == expected[y * side + xx] { same += 1 }
        }
    }
    let agree = Double(same) / Double(count)
    print(String(format: "Panel model agreement with the original network: %.4f", agree))
    if agree < 0.97 { print("::error::The panel model gives different answers from the original network."); exit(1) }
} catch {
    print("::error::Panel model check failed: \(error)")
    exit(1)
}
