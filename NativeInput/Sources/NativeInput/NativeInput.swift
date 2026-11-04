import Foundation
import IOKit.hid
import CoreGraphics

public enum InputStartError: Error {
    case inputMonitoringUnavailable
    case hidOpenFailed(Int32)
    case eventTapCreationFailed
    case alreadyStarted
}

/// All methods and callbacks must run on the main thread. No permission prompt is requested.
/// Observes only: this class never seizes a device or suppresses an event.
public final class DJIObserver {
    public enum Event { case connected(UInt64), removed(UInt64), button(UInt64, Bool) }
    private var manager: IOHIDManager?
    private var buttons = ButtonTracker<UInt64>()
    private var deviceIDs: [UnsafeRawPointer: UInt64] = [:]
    private let handler: (Event) -> Void
    public init(handler: @escaping (Event) -> Void) { self.handler = handler }
    private func id(_ device: IOHIDDevice) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id) == KERN_SUCCESS ? id : nil
    }
    public func start() throws {
        precondition(Thread.isMainThread)
        guard manager == nil else { throw InputStartError.alreadyStarted }
        guard CGPreflightListenEventAccess() else { throw InputStartError.inputMonitoringUnavailable }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 11427, kIOHIDProductIDKey: 16401] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { context, _, _, device in
            let owner = Unmanaged<DJIObserver>.fromOpaque(context!).takeUnretainedValue()
            if let id = owner.id(device) {
                owner.deviceIDs[UnsafeRawPointer(Unmanaged.passUnretained(device).toOpaque())] = id
                owner.handler(.connected(id))
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, device in
            let owner = Unmanaged<DJIObserver>.fromOpaque(context!).takeUnretainedValue()
            let key = UnsafeRawPointer(Unmanaged.passUnretained(device).toOpaque())
            if let id = owner.deviceIDs.removeValue(forKey: key) { owner.buttons.remove(device: id); owner.handler(.removed(id)) }
        }, context)
        IOHIDManagerRegisterInputValueCallback(m, { context, _, _, value in
            let owner = Unmanaged<DJIObserver>.fromOpaque(context!).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == 0x0c, IOHIDElementGetUsage(element) == 0xe9,
                  let id = owner.id(IOHIDElementGetDevice(element)) else { return }
            if let down = owner.buttons.update(device: id, down: IOHIDValueGetIntegerValue(value) != 0) {
                owner.handler(.button(id, down))
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            throw InputStartError.hidOpenFailed(result)
        }
        manager = m
    }
    public func stop() {
        precondition(Thread.isMainThread)
        guard let m = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        buttons.reset()
        deviceIDs.removeAll()
    }
    deinit { if manager != nil { stop() } }
}

/// Listen-only session tap; Fn detection is best effort and does not consume keyboard events.
public final class FnObserver {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tracker = FnTracker()
    private let handler: () -> Void
    public init(handler: @escaping () -> Void) { self.handler = handler }
    public func start() throws {
        precondition(Thread.isMainThread)
        guard tap == nil else { throw InputStartError.alreadyStarted }
        guard CGPreflightListenEventAccess() else { throw InputStartError.inputMonitoringUnavailable }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            let owner = Unmanaged<FnObserver>.fromOpaque(context!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.tracker.reset()
                if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if type == .flagsChanged && event.getIntegerValueField(.keyboardEventKeycode) == 63 {
                let flags = event.flags
                let other = !flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift]).isEmpty
                if owner.tracker.fnChanged(isDown: flags.contains(.maskSecondaryFn), otherModifiers: other) { owner.handler() }
            } else { owner.tracker.otherInput() }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { throw InputStartError.eventTapCreationFailed }
        let runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)!
        tap = port
        source = runSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }
    public func stop() {
        precondition(Thread.isMainThread)
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil; tracker.reset()
    }
    deinit { if tap != nil { stop() } }
}
