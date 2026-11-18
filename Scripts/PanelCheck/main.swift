// CI check: runs the app's own panel detector (model, gutter splitting, reading order) on a test page and
// compares the panels with the expected ones. Usage: check test-page.png expected.json
import Foundation
import CoreGraphics
import ImageIO

let args = CommandLine.arguments
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("::error::Could not read the test page."); exit(1)
}
let expected = try! JSONDecoder().decode([[Double]].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
guard let found = MLPanelDetector.detect(image: image, rtl: false) else {
    print("::error::The panel detector could not run."); exit(1)
}
for r in found { print(String(format: "  panel x %.3f-%.3f  y %.3f-%.3f", r.minX, r.maxX, r.minY, r.maxY)) }
var ok = found.count == expected.count
if ok {
    for (r, e) in zip(found, expected) {
        let d = [abs(r.minX - e[0]), abs(r.minY - e[1]), abs(r.maxX - e[2]), abs(r.maxY - e[3])].max()!
        if d > 0.03 { ok = false }
    }
}
if !ok {
    print("::error::Panel detector found \(found.count) panels, expected \(expected.count) (or they are in the wrong place or order).")
    exit(1)
}
print("Panel detector check passed: \(found.count) panels in the right order.")
