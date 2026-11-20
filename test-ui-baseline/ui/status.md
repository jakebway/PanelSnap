# UI test: failure

```
Test Case '-[PanelSnapUITests.ReaderUITests testPageSwipes]' started.
Test Case '-[PanelSnapUITests.ReaderUITests testPageSwipes]' passed (57.139 seconds).
Test Case '-[PanelSnapUITests.ReaderUITests testPinchFromSnappedPanelIsContinuous]' started.
UITEST: pinch continuity diff: 0.08814814814814814
Tests/UI/ReaderUITests.swift:146: error: -[PanelSnapUITests.ReaderUITests testPinchFromSnappedPanelIsContinuous] : XCTAssertLessThan failed: ("0.08814814814814814") is not less than ("0.08") - a tiny drag should move the page a tiny amount
Test Case '-[PanelSnapUITests.ReaderUITests testPinchFromSnappedPanelIsContinuous]' failed (25.376 seconds).
Test Case '-[PanelSnapUITests.ReaderUITests testReaderGestures]' started.
UITEST: glide movement after release: 0.12509622367465506
Test Case '-[PanelSnapUITests.ReaderUITests testReaderGestures]' passed (37.968 seconds).
Test Suite 'ReaderUITests' failed at 2026-11-20 17:36:30.561.
	 Executed 3 tests, with 1 failure (0 unexpected) in 120.482 (120.485) seconds
Test Suite 'PanelSnapUITests.xctest' failed at 2026-11-20 17:36:30.562.
	 Executed 3 tests, with 1 failure (0 unexpected) in 120.482 (120.486) seconds
Test Suite 'All tests' failed at 2026-11-20 17:36:30.562.
	 Executed 3 tests, with 1 failure (0 unexpected) in 120.482 (120.487) seconds
```
