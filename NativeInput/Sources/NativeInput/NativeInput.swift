import Foundation
import IOKit.hid
import CoreGraphics

public enum InputStartError: Error {
    case inputMonitoringUnavailable
    case hidOpenFailed(Int32)
    case eventTapCreationFailed
    case alreadyStarted
}

/// Non-exclusive, per-device input listener. A failed open never enables callbacks.
/// Main-thread lifecycle and callbacks; no audio interfaces are opened.
public final class DJIObserver {
    public enum Event { case connected(UInt64), removed(UInt64), button(UInt64, Bool), unavailable(UInt64, Int32) }
    private var manager: IOHIDManager?
    private var devices: [UInt64: IOHIDDevice] = [:]
    private var ids: [UnsafeRawPointer: UInt64] = [:]
    private var buttons = ButtonTracker<UInt64>()
    private let handler: (Event) -> Void
    public init(handler: @escaping (Event) -> Void) { self.handler = handler }
    public func start() throws {
        precondition(Thread.isMainThread)
        guard manager == nil else { throw InputStartError.alreadyStarted }
        guard CGPreflightListenEventAccess() else { throw InputStartError.inputMonitoringUnavailable }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 11427, kIOHIDProductIDKey: 16401,
            kIOHIDPrimaryUsagePageKey: 12, kIOHIDPrimaryUsageKey: 1, kIOHIDTransportKey: "USB"] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { context, result, _, device in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<DJIObserver>.fromOpaque(context).takeUnretainedValue().connect(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, device in
            guard let context else { return }
            let owner = Unmanaged<DJIObserver>.fromOpaque(context).takeUnretainedValue()
            let key = UnsafeRawPointer(Unmanaged.passUnretained(device).toOpaque())
            if let id = owner.ids.removeValue(forKey: key) {
                owner.disconnect(id)
                owner.handler(.removed(id))
            }
        }, context)
        manager = m
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(m, 0)
        if result != kIOReturnSuccess { stop(); throw InputStartError.hidOpenFailed(result) }
    }
    private func connect(_ device: IOHIDDevice) {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id) == KERN_SUCCESS,
              devices[id] == nil else { return }
        let result = IOHIDDeviceOpen(device, 0)
        guard result == kIOReturnSuccess else {
            IOHIDDeviceClose(device, 0)
            handler(.unavailable(id, result))
            return
        }
        devices[id] = device
        ids[UnsafeRawPointer(Unmanaged.passUnretained(device).toOpaque())] = id
        IOHIDDeviceSetInputValueMatching(device, [kIOHIDElementUsagePageKey: 12, kIOHIDElementUsageKey: 233] as CFDictionary)
        IOHIDDeviceRegisterInputValueCallback(device, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let owner = Unmanaged<DJIObserver>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let device = IOHIDElementGetDevice(element)
            let key = UnsafeRawPointer(Unmanaged.passUnretained(device).toOpaque())
            guard IOHIDElementGetUsagePage(element) == 12, IOHIDElementGetUsage(element) == 233,
                  let id = owner.ids[key], owner.devices[id] != nil else { return }
            if let down = owner.buttons.update(device: id, down: IOHIDValueGetIntegerValue(value) != 0) {
                owner.handler(.button(id, down))
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        handler(.connected(id))
    }
    private func disconnect(_ id: UInt64) {
        guard let device = devices.removeValue(forKey: id) else { return }
        ids.removeValue(forKey: UnsafeRawPointer(Unmanaged.passUnretained(device).toOpaque()))
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceClose(device, 0)
        buttons.remove(device: id)
    }
    public func stop() {
        precondition(Thread.isMainThread)
        guard let m = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerRegisterDeviceMatchingCallback(m, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(m, nil, nil)
        for id in Array(devices.keys) { disconnect(id) }
        IOHIDManagerClose(m, 0)
        manager = nil
        ids.removeAll()
        buttons.reset()
    }
    deinit { if manager != nil { stop() } }
}
