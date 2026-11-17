import Foundation
import CoreGraphics

/// Finds the panels on a comic page. Panels are found by a neural network (see `MLPanelDetector`); there is
/// no rule-based backup. A page where nothing is found (a splash page, say) is shown whole.
enum PanelDetector {
    /// Bump when detection changes so panels saved from an older version are found again.
    static let version = 7

    /// Panels in reading order as 0...1 rectangles with a top-left origin.
    static func detect(image: CGImage, rtl: Bool) -> [CGRect] {
        if let found = MLPanelDetector.detect(image: image, rtl: rtl), !found.isEmpty { return found }
        return [CGRect(x: 0, y: 0, width: 1, height: 1)]
    }
}
