import XCTest
@testable import NativeInput

final class StateTests: XCTestCase {
    func testButtonsAreDeduplicatedPerDeviceAndResetOnRemoval() {
        var t = ButtonTracker<Int>()
        XCTAssertEqual(t.update(device: 1, down: true), true)
        XCTAssertNil(t.update(device: 1, down: true))
        XCTAssertEqual(t.update(device: 2, down: true), true)
        XCTAssertEqual(t.update(device: 1, down: false), false)
        XCTAssertNil(t.update(device: 1, down: false))
        t.remove(device: 2)
        XCTAssertNil(t.update(device: 2, down: false))
        XCTAssertEqual(t.update(device: 2, down: true), true)
    }
    func testFnTapAndChords() {
        var t = FnTracker()
        XCTAssertFalse(t.fnChanged(isDown: true, otherModifiers: false))
        XCTAssertTrue(t.fnChanged(isDown: false, otherModifiers: false))
        XCTAssertFalse(t.fnChanged(isDown: false, otherModifiers: false))
        _ = t.fnChanged(isDown: true, otherModifiers: false)
        t.otherInput()
        XCTAssertFalse(t.fnChanged(isDown: false, otherModifiers: false))
        _ = t.fnChanged(isDown: true, otherModifiers: true)
        XCTAssertFalse(t.fnChanged(isDown: false, otherModifiers: false))
        _ = t.fnChanged(isDown: true, otherModifiers: false)
        t.reset()
        XCTAssertFalse(t.fnChanged(isDown: false, otherModifiers: false))
    }
}
