# UI test: failure

```
Test Case '-[PanelSnapUITests.ReaderUITests testPageSwipes]' started.
Test Case '-[PanelSnapUITests.ReaderUITests testPageSwipes]' passed (64.969 seconds).
Test Case '-[PanelSnapUITests.ReaderUITests testPinchFromSnappedPanelIsContinuous]' started.
UITEST: pinch continuity diff: 0.08814814814814814
Tests/UI/ReaderUITests.swift:146: error: -[PanelSnapUITests.ReaderUITests testPinchFromSnappedPanelIsContinuous] : XCTAssertLessThan failed: ("0.08814814814814814") is not less than ("0.08") - a tiny drag should move the page a tiny amount
Test Case '-[PanelSnapUITests.ReaderUITests testPinchFromSnappedPanelIsContinuous]' failed (31.060 seconds).
Test Case '-[PanelSnapUITests.ReaderUITests testReaderGestures]' started.
UITEST: glide movement after release: 0.11629992737835874
Test Case '-[PanelSnapUITests.ReaderUITests testReaderGestures]' passed (38.760 seconds).
Test Suite 'ReaderUITests' failed at 2026-11-20 17:41:59.617.
	 Executed 3 tests, with 1 failure (0 unexpected) in 134.790 (134.795) seconds
Test Suite 'PanelSnapUITests.xctest' failed at 2026-11-20 17:41:59.619.
	 Executed 3 tests, with 1 failure (0 unexpected) in 134.790 (134.797) seconds
Test Suite 'All tests' failed at 2026-11-20 17:41:59.620.
	 Executed 3 tests, with 1 failure (0 unexpected) in 134.790 (134.801) seconds
```
