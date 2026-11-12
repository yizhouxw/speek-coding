import AppKit
import XCTest
@testable import NativeInput

final class FnObserverTests: XCTestCase {
    private func fn(_ down: Bool, at time: Double) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: 63)
        event.flags = down ? .maskSecondaryFn : []
        event.timestamp = UInt64(time * 1_000_000_000)
        return event
    }
    func testSingleTapAndDuplicateRelease() {
        var taps = 0
        let observer = FnObserver { taps += 1 }
        observer.receive(type: .flagsChanged, event: fn(true, at: 1), otherKeyHeld: false)
        observer.receive(type: .flagsChanged, event: fn(false, at: 1.2), otherKeyHeld: false)
        observer.receive(type: .flagsChanged, event: fn(false, at: 1.3), otherKeyHeld: false)
        XCTAssertEqual(taps, 1)
    }
    func testAllObservedChordInputsCancelTap() {
        for type in FnObserver.eventTypes where type != CGEventType.flagsChanged.rawValue {
            var taps = 0
            let observer = FnObserver { taps += 1 }
            observer.receive(type: .flagsChanged, event: fn(true, at: 1), otherKeyHeld: false)
            observer.receive(type: CGEventType(rawValue: type)!, event: CGEvent(source: nil)!)
            observer.receive(type: .flagsChanged, event: fn(false, at: 1.2), otherKeyHeld: false)
            XCTAssertEqual(taps, 0, "event type \(type)")
        }
    }
    func testKeyHeldBeforeFnAndThenReleased() {
        var taps = 0
        let observer = FnObserver { taps += 1 }
        let key = CGEvent(source: nil)!
        key.setIntegerValueField(.keyboardEventKeycode, value: 0)
        observer.receive(type: .keyDown, event: key)
        observer.receive(type: .flagsChanged, event: fn(true, at: 1))
        observer.receive(type: .flagsChanged, event: fn(false, at: 1.2))
        XCTAssertEqual(taps, 0)
        observer.receive(type: .keyUp, event: key)
        observer.receive(type: .flagsChanged, event: fn(true, at: 2))
        observer.receive(type: .flagsChanged, event: fn(false, at: 2.2))
        XCTAssertEqual(taps, 1)
    }
    func testHeldKeyLongPressAndDisabledTapDoNotActivate() {
        var taps = 0
        let observer = FnObserver { taps += 1 }
        observer.receive(type: .flagsChanged, event: fn(true, at: 1), otherKeyHeld: true)
        observer.receive(type: .flagsChanged, event: fn(false, at: 1.2), otherKeyHeld: false)
        observer.receive(type: .flagsChanged, event: fn(true, at: 2), otherKeyHeld: false)
        observer.receive(type: .flagsChanged, event: fn(false, at: 3.1), otherKeyHeld: false)
        observer.receive(type: .flagsChanged, event: fn(true, at: 4), otherKeyHeld: false)
        observer.receive(type: .tapDisabledByTimeout, event: CGEvent(source: nil)!)
        observer.receive(type: .flagsChanged, event: fn(false, at: 4.2), otherKeyHeld: false)
        XCTAssertEqual(taps, 0)
    }
    func testOtherModifierAndRestartWhileHeldDoNotActivate() {
        var taps = 0
        let observer = FnObserver { taps += 1 }
        observer.receive(type: .flagsChanged, event: fn(false, at: 0.5), otherKeyHeld: false)
        observer.receive(type: .flagsChanged, event: fn(true, at: 1), otherKeyHeld: false)
        let shift = CGEvent(source: nil)!
        shift.type = .flagsChanged
        shift.setIntegerValueField(.keyboardEventKeycode, value: 56)
        shift.flags = [.maskShift, .maskSecondaryFn]
        observer.receive(type: .flagsChanged, event: shift)
        observer.receive(type: .flagsChanged, event: fn(false, at: 1.2), otherKeyHeld: false)
        observer.receive(type: .flagsChanged, event: fn(true, at: 2), otherKeyHeld: false)
        observer.reset()
        observer.receive(type: .flagsChanged, event: fn(false, at: 2.2), otherKeyHeld: false)
        XCTAssertEqual(taps, 0)
    }
}
