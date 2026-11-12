import Foundation

/// State is scoped to one HID service, not merely a vendor/product pair.
public struct ButtonTracker<ID: Hashable> {
    private var pressed = Set<ID>()
    public init() {}
    public mutating func update(device: ID, down: Bool) -> Bool? {
        if down { return pressed.insert(device).inserted ? true : nil }
        return pressed.remove(device) != nil ? false : nil
    }
    /// Disconnect clears state; it does not synthesize an activation or release.
    public mutating func remove(device: ID) { pressed.remove(device) }
    public mutating func reset() { pressed.removeAll() }
}

/// Fn is a tap only when released without any intervening key or modifier change.
public struct FnTracker {
    private var down = false
    private var chord = false
    private var pressedAt: TimeInterval = 0
    public var isPressed: Bool { down }
    public init() {}
    public mutating func fnChanged(isDown: Bool, otherModifiers: Bool, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if isDown {
            if !down { down = true; chord = otherModifiers; pressedAt = timestamp }
            else if otherModifiers { chord = true }
            return false
        }
        guard down else { return false }
        down = false
        let elapsed = timestamp - pressedAt
        let tapped = !chord && !otherModifiers && elapsed >= 0 && elapsed <= 1
        chord = false
        return tapped
    }
    public mutating func otherInput() { if down { chord = true } }
    public mutating func reset() { down = false; chord = false }
}
