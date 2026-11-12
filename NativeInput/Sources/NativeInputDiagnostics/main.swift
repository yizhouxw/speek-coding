import Foundation
import CoreGraphics
import IOKit.hid
import NativeInput

// Deliberately emits no characters, key codes, device serials, or recording data.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] {
    print("Usage: swift run --package-path NativeInput native-input-diagnose [--seconds 30]")
    print("Quit Karabiner. Tap Fn three times, then Fn+Shift and Fn+F12; expect exactly three taps.")
    exit(0)
}
let seconds: Double
if arguments.isEmpty { seconds = 30 }
else if arguments.count == 2, arguments[0] == "--seconds", let value = Double(arguments[1]), value.isFinite, (1...300).contains(value) { seconds = value }
else { fputs("Expected --seconds between 1 and 300.\n", stderr); exit(2) }
setbuf(stdout, nil)
print("Input Monitoring: \(CGPreflightListenEventAccess())")
// Opening each keyboard separately identifies physical-device contention even
// when a manager could still observe a remapper's virtual keyboard.
let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6] as CFDictionary)
for device in IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] {
    let result = CGPreflightListenEventAccess() ? IOHIDDeviceOpen(device, 0) : kIOReturnNotPermitted
    let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Keyboard"
    print("HID \(product): \(result == kIOReturnExclusiveAccess ? "exclusive access (another client owns this device)" : String(result))")
    if result == kIOReturnSuccess { IOHIDDeviceClose(device, 0) }
}
var taps = 0
let observer = FnObserver(diagnostic: { event in
    switch event {
    case .fnChanged(let down): print("Fn \(down ? "down" : "up")")
    case .otherInput: print("Chord input; cancel pending tap")
    case .tapDisabled: print("Event tap disabled; pending tap discarded")
    case .reset: print("State reset")
    }
}) {
    taps += 1
    print("FN_TAP \(taps)")
}
do { try observer.start() }
catch { fputs("Cannot listen: \(error). Allow Input Monitoring for the launching app and retry.\n", stderr); exit(1) }
print("READY for \(Int(seconds)) seconds. No recording is started.")
RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
observer.stop()
print("DONE taps=\(taps)")
