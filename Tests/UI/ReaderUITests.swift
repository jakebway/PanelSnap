import XCTest
import UIKit

/// Opens a comic in the simulator and drives the reader the way a finger would, saving a screenshot at every step.
final class ReaderUITests: XCTestCase {
    var app: XCUIApplication!
    var last: UIImage?

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    // MARK: helpers

    @discardableResult
    func shot(_ name: String) -> UIImage {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        return s.image
    }

    /// Mean difference (0...1) between two screenshots, ignoring the status bar.
    func diff(_ a: UIImage, _ b: UIImage) -> Double {
        func pixels(_ im: UIImage) -> [UInt8] {
            let w = 48, h = 96
            var data = [UInt8](repeating: 0, count: w * h)
            let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .medium
            if let cg = im.cgImage { ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)) }
            return Array(data[(w * 6)...])          // drop the top rows (clock)
        }
        let p = pixels(a), q = pixels(b)
        var total = 0
        for i in 0..<min(p.count, q.count) { total += abs(Int(p[i]) - Int(q[i])) }
        return Double(total) / Double(min(p.count, q.count) * 255)
    }

    func at(_ x: Double, _ y: Double) -> XCUICoordinate {
        return app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    func settle(_ s: Double = 1.0) { Thread.sleep(forTimeInterval: s) }

    func openComic() {
        settle(2.5)
        shot("01-library")
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'UITest'")).firstMatch
        if title.waitForExistence(timeout: 8) {
            title.tap()
        } else {
            at(0.25, 0.3).tap()                      // first cover on the shelf
        }
        settle(3.0)
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: tests

    func testReaderGestures() {
        openComic()
        var prev = shot("02-reader-open")

        // Edge tap goes to the next panel.
        at(0.96, 0.5).tap(); settle(1.0)
        var now = shot("03-edge-tap-next")
        XCTAssertGreaterThan(diff(prev, now), 0.002, "tapping the right edge should move to the next panel")
        prev = now

        // Tap the middle of a panel: snaps to it (or toggles the controls when it is already focused).
        at(0.5, 0.5).tap(); settle(1.2)
        now = shot("04-centre-tap")
        prev = now

        // Pinch in.
        app.windows.firstMatch.pinch(withScale: 2.5, velocity: 2); settle(0.8)
        now = shot("05-pinched-in")
        XCTAssertGreaterThan(diff(prev, now), 0.002, "pinching should zoom")
        prev = now

        // Slow one-finger drag while zoomed moves the page.
        at(0.7, 0.6).press(forDuration: 0.05, thenDragTo: at(0.3, 0.4)); settle(0.8)
        now = shot("06-dragged")
        XCTAssertGreaterThan(diff(prev, now), 0.002, "dragging while zoomed should pan")
        prev = now

        // Fast flick: the page keeps gliding after the finger leaves.
        at(0.3, 0.5).press(forDuration: 0.02, thenDragTo: at(0.75, 0.5), withVelocity: .fast, thenHoldForDuration: 0)
        settle(0.08)
        let early = shot("07-flick-early")
        settle(1.5)
        let late = shot("08-flick-late")
        consoleLog("glide movement after release: \(diff(early, late))")
        prev = late

        // Double-tap zooms back out or in; either way the app must stay alive and respond.
        at(0.5, 0.5).doubleTap(); settle(1.0)
        now = shot("09-double-tap")
        XCTAssertEqual(app.state, .runningForeground)

        // Pinch back out to the whole page.
        app.windows.firstMatch.pinch(withScale: 0.4, velocity: -2); settle(1.0)
        shot("10-pinched-out")

        // Leave the app and come back: the reader must still be there and responsive.
        XCUIDevice.shared.press(.home); settle(1.5)
        app.activate(); settle(1.5)
        XCTAssertEqual(app.state, .runningForeground)
        shot("11-after-returning")
        at(0.96, 0.5).tap(); settle(1.0)
        shot("12-tap-after-returning")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testPageSwipes() {
        openComic()
        let a = shot("20-start")
        for i in 1...3 {
            at(0.85, 0.5).press(forDuration: 0.02, thenDragTo: at(0.15, 0.5), withVelocity: .fast, thenHoldForDuration: 0)
            settle(1.0)
            shot("21-swipe-\(i)")
        }
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertGreaterThan(diff(a, shot("22-end")), 0.002, "swiping should change what is on screen")
    }

    func consoleLog(_ s: String) { print("UITEST: \(s)") }
}
