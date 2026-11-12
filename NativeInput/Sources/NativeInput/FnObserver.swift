import AppKit
import CoreGraphics

/// Listen-only session tap. Fn must reach Quartz; an upstream remapper can hide it.
/// All methods and callbacks run on the main thread. No input is suppressed.
public final class FnObserver {
    public enum Diagnostic {
        case fnChanged(Bool), otherInput, tapDisabled, reset
    }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var tracker = FnTracker()
    private var pressedKeys = Set<Int64>()
    private let diagnostic: (Diagnostic) -> Void
    private let handler: () -> Void
    public var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    public init(diagnostic: @escaping (Diagnostic) -> Void = { _ in }, handler: @escaping () -> Void) {
        self.diagnostic = diagnostic
        self.handler = handler
    }

    // Media keys use systemDefined rather than keyDown on some keyboard settings.
    static let eventTypes: [UInt32] = [CGEventType.flagsChanged.rawValue, CGEventType.keyDown.rawValue,
        CGEventType.keyUp.rawValue, UInt32(NSEvent.EventType.systemDefined.rawValue),
        CGEventType.leftMouseDown.rawValue, CGEventType.rightMouseDown.rawValue,
        CGEventType.otherMouseDown.rawValue, CGEventType.scrollWheel.rawValue]

    public func start() throws {
        precondition(Thread.isMainThread)
        guard tap == nil else { throw InputStartError.alreadyStarted }
        guard CGPreflightListenEventAccess() else { throw InputStartError.inputMonitoringUnavailable }
        let mask = Self.eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
                let owner = Unmanaged<FnObserver>.fromOpaque(context!).takeUnretainedValue()
                owner.receive(type: type, event: event)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { throw InputStartError.eventTapCreationFailed }
        guard let runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            throw InputStartError.eventTapCreationFailed
        }
        tap = port
        source = runSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reset()
            })
        }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    // Internal for replay tests: no event posting or TCC permission required.
    func receive(type: CGEventType, event: CGEvent, otherKeyHeld: Bool? = nil) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            diagnostic(.tapDisabled)
            if let tap, CGPreflightListenEventAccess() { CGEvent.tapEnable(tap: tap, enable: true) }
        } else if type == .flagsChanged && event.getIntegerValueField(.keyboardEventKeycode) == 63 {
            let flags = event.flags
            let down = flags.contains(.maskSecondaryFn)
            // Quartz keyState can retain stuck keys after a remapper exits. Track
            // observed transitions instead; keys held before start remain unknown.
            let held = down && (otherKeyHeld ?? !pressedKeys.isEmpty)
            let other = held || !flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift]).isEmpty
            diagnostic(.fnChanged(down))
            if tracker.fnChanged(isDown: down, otherModifiers: other, timestamp: Double(event.timestamp) / 1_000_000_000) {
                handler()
            }
        } else {
            if type == .keyDown { pressedKeys.insert(event.getIntegerValueField(.keyboardEventKeycode)) }
            if type == .keyUp { pressedKeys.remove(event.getIntegerValueField(.keyboardEventKeycode)) }
            if tracker.isPressed { diagnostic(.otherInput) }
            tracker.otherInput()
        }
    }

    public func reset() {
        precondition(Thread.isMainThread)
        tracker.reset()
        pressedKeys.removeAll()
        diagnostic(.reset)
    }
    public func stop() {
        precondition(Thread.isMainThread)
        for observer in lifecycleObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        lifecycleObservers.removeAll()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        tracker.reset()
        pressedKeys.removeAll()
    }
    deinit { if tap != nil { stop() } }
}
