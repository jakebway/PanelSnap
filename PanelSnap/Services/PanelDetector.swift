import Foundation
import CoreGraphics

/// Finds the panels on a comic page. Panels are found by a neural network (see `MLPanelDetector`); there is
/// no rule-based backup. A page where nothing is found (a splash page, say) is shown whole.
enum PanelDetector {
    /// Bump when detection changes so panels saved from an older version are found again.
    static let version = 8

    /// Panels in reading order as 0...1 rectangles with a top-left origin. A page with no panels comes back as the
    /// whole page. Nil means the model could not run this time, so the answer should not be saved.
    static func detect(image: CGImage, rtl: Bool) -> [CGRect]? {
        guard let found = MLPanelDetector.detect(image: image, rtl: rtl) else { return nil }
        return found.isEmpty ? [CGRect(x: 0, y: 0, width: 1, height: 1)] : found
    }
}
