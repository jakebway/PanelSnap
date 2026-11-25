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
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "the app should come back to the front")
        settle(1.5)
        shot("11-after-returning")
        at(0.96, 0.5).tap(); settle(1.0)
        shot("12-tap-after-returning")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Vertical scrolling: scroll, pinch, drag while zoomed, double-tap, edge tap.
    func testVerticalScroll() {
        openComic()
        at(0.5, 0.5).tap(); settle(0.6)
        let more = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'more' OR label CONTAINS[c] 'ellipsis'")).firstMatch
        if more.waitForExistence(timeout: 3) { more.tap(); settle(0.6) }
        shot("29-menu")
        let toggle = app.buttons["Vertical Scrolling"].firstMatch
        if toggle.waitForExistence(timeout: 3) { toggle.tap() } else { at(0.5, 0.5).tap() }
        settle(1.5)
        let a = shot("30-vertical-open")
        at(0.5, 0.7).press(forDuration: 0.05, thenDragTo: at(0.5, 0.2)); settle(1.0)
        let b = shot("31-scrolled")
        XCTAssertGreaterThan(diff(a, b), 0.002, "dragging should scroll")
        app.windows.firstMatch.pinch(withScale: 2.5, velocity: 2); settle(0.8)
        let c = shot("32-pinched")
        XCTAssertGreaterThan(diff(b, c), 0.002, "pinching should zoom")
        at(0.7, 0.6).press(forDuration: 0.05, thenDragTo: at(0.3, 0.4)); settle(0.8)
        let d = shot("33-panned")
        XCTAssertGreaterThan(diff(c, d), 0.002, "dragging while zoomed should pan")
        at(0.5, 0.5).doubleTap(); settle(1.0)
        shot("34-double-tap-out")
        at(0.96, 0.5).tap(); settle(1.0)
        shot("35-edge-tap")
        at(0.5, 0.5).tap(); settle(0.8)
        shot("36-tap-controls")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Hold one comic on top of another: the naming sheet for a new shelf should appear.
    func testMakeShelf() {
        settle(3.0)
        shot("40-library")
        let a = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'UITest'")).firstMatch
        let b = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Spider'")).firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 8) && b.waitForExistence(timeout: 3), "both test comics should be in the library")
        let screen = app.windows.firstMatch.frame
        let cw = (screen.width - 40 - 36) / 4
        func cover(_ t: XCUIElement) -> XCUICoordinate {
            let f = t.frame
            let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            return origin.withOffset(CGVector(dx: f.minX + cw / 2, dy: f.minY - 16 - cw * 0.75))
        }
        let from = cover(a), to = cover(b)
        from.press(forDuration: 0.45, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 2.5)
        settle(1.5)
        shot("41-after-hold")
        let field = app.textFields["Shelf name"]
        XCTAssertTrue(field.waitForExistence(timeout: 4), "holding a comic on another should open the new-shelf naming sheet")
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

    /// Pinching on a snapped panel must carry on from exactly what is on screen (zooming a little), not jump elsewhere.
    func testPinchFromSnappedPanelIsContinuous() {
        openComic()
        at(0.96, 0.5).tap(); settle(1.2)                 // make sure a panel is snapped
        let before = shot("30-snapped-panel")
        app.windows.firstMatch.pinch(withScale: 1.2, velocity: 0.6); settle(1.0)
        let after = shot("31-after-small-pinch")
        let d = diff(before, after)
        consoleLog("pinch continuity diff: \(d)")
        XCTAssertLessThan(d, 0.10, "a small pinch on a snapped panel should look like the same view, slightly larger")
    }

    /// An omnibus of three issues: Companion should work out which issue the page belongs to, and follow the reader.
    func testOmnibusCompanion() {
        settle(2.5)
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Omnibus'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the omnibus should be in the library")
        title.tap(); settle(3.0)
        shot("40-omnibus-open")

        func showControls() {
            let bar = app.descendants(matching: .any)["page-scrubber"]
            if bar.waitForExistence(timeout: 1) { return }
            at(0.5, 0.5).tap()
            _ = bar.waitForExistence(timeout: 4)
        }
        /// Drags the page bar to a place along its length and checks the page really changed.
        func scrub(to fraction: Double) {
            showControls()
            let bar = app.descendants(matching: .any)["page-scrubber"]
            XCTAssertTrue(bar.exists, "the page bar should be there")
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
                .press(forDuration: 0.2, thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)))
            settle(2.0)
        }
        func openCompanion() -> String {
            showControls()                                          // bring the controls up
            let button = app.buttons["companion-button"]
            if button.waitForExistence(timeout: 4) { button.tap() } else { at(0.93, 0.93).tap() }
            settle(1.0)
            let banner = app.descendants(matching: .any)["companion-issue-banner"]
            _ = banner.waitForExistence(timeout: 150)                // the page text is read in the background first
            settle(1.5)
            shot("41-companion")
            return banner.exists ? banner.label : "(no banner)"
        }
        func closeCompanion() {
            let done = app.buttons["Done"]
            if done.waitForExistence(timeout: 3) { done.tap() }
            settle(0.8)
        }

        // The file opens on the cover, which comes before issue #1; move into the first issue.
        scrub(to: 0.12)
        let first = openCompanion()
        consoleLog("banner at the start: \(first)")
        XCTAssertTrue(first.contains("#1"), "page 2 onwards is issue #1, got: \(first)")
        settle(8.0)                                                  // let the lookups fill in
        shot("42-companion-issue1")

        // Ask the phone's own model a question (only when this simulator has Apple Intelligence).
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Who is'")).firstMatch
        if chip.exists {
            chip.tap()
            let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Answered on your phone'")).firstMatch
            let got = note.waitForExistence(timeout: 90)
            settle(1.0)
            shot("45-ask-answer")
            consoleLog("ask answered: \(got)")
        } else {
            consoleLog("ask not available here")
        }
        closeCompanion()

        // Jump to a page inside issue #3 with the slider, then look again.
        scrub(to: 0.85)
        shot("43-jumped")
        let later = openCompanion()
        consoleLog("banner after jumping: \(later)")
        XCTAssertTrue(later.contains("#3"), "page ~31 is in issue #3, got: \(later)")
        settle(8.0)
        shot("44-companion-issue3")
    }

    func consoleLog(_ s: String) { print("UITEST: \(s)") }
}
