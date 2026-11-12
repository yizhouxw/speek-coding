import Foundation
import IOKit.hid
import IOKit.hidsystem

public struct DJIServiceEndpoint: Equatable, Codable {
    public let service: DJIMapping.Service
    public let deviceRegistryID: UInt64
}

public enum DJINativeError: Error {
    case serviceGone, invalidProperty, changedMapping, writeRejected, verificationFailed
    case alreadyOwned, journalInvalid, ambiguousService
}

protocol DJIMappingBackend: AnyObject {
    func endpoints() throws -> [DJIServiceEndpoint]
    func read(_ endpoint: DJIServiceEndpoint) throws -> [DJIMapping.Entry]
    func write(_ endpoint: DJIServiceEndpoint, expected: [DJIMapping.Entry], replacement: [DJIMapping.Entry]) throws
}

/// Service-level API only. There is deliberately no event-system/global setter.
public final class DJIServiceMapping: DJIMappingBackend {
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    public init() {}
    private let key = "UserKeyMapping" as CFString

    static func decode(_ value: CFTypeRef?) throws -> [DJIMapping.Entry] {
        guard let value else { return [] }
        guard let array = value as? [NSDictionary] else { throw DJINativeError.invalidProperty }
        return try array.map { item in
            guard item.count == 2,
                  let src = item["HIDKeyboardModifierMappingSrc"] as? NSNumber,
                  let dst = item["HIDKeyboardModifierMappingDst"] as? NSNumber else { throw DJINativeError.invalidProperty }
            func number(_ n: NSNumber) throws -> UInt64 {
                guard CFGetTypeID(n) != CFBooleanGetTypeID(), let v = UInt64(n.stringValue) else { throw DJINativeError.invalidProperty }
                return v
            }
            return try .init(source: number(src), destination: number(dst))
        }
    }

    private func available() -> [IOHIDServiceClient] {
        IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
    }
    private func endpoint(_ ref: IOHIDServiceClient) -> DJIServiceEndpoint? {
        func int(_ key: String) -> Int { (IOHIDServiceClientCopyProperty(ref, key as CFString) as? NSNumber)?.intValue ?? -1 }
        guard int(kIOHIDVendorIDKey) == 11427, int(kIOHIDProductIDKey) == 16401,
              let id = IOHIDServiceClientGetRegistryID(ref) as? NSNumber else { return nil }
        let service = DJIMapping.Service(registryID: id.uint64Value, vendorID: int(kIOHIDVendorIDKey),
            productID: int(kIOHIDProductIDKey), usagePage: int(kIOHIDPrimaryUsagePageKey), usage: int(kIOHIDPrimaryUsageKey),
            transport: IOHIDServiceClientCopyProperty(ref, kIOHIDTransportKey as CFString) as? String ?? "")
        guard (try? DJIMapping.plan(service: service, existing: [])) != nil else { return nil }
        // Event-service IDs differ from IOHIDDevice IDs. Walk the real registry
        // ancestry instead of guessing from VID/PID or arrival timing.
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(service.registryID))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        for _ in 0..<16 {
            if IOObjectConformsTo(entry, "IOHIDDevice") != 0 {
                var deviceID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(entry, &deviceID) == KERN_SUCCESS else { return nil }
                return .init(service: service, deviceRegistryID: deviceID)
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(entry)
            entry = parent
        }
        return nil
    }
    func allMappingValues() throws -> [UInt64: Data] {
        var result: [UInt64: Data] = [:]
        for ref in available() {
            guard let id = IOHIDServiceClientGetRegistryID(ref) as? NSNumber else { throw DJINativeError.invalidProperty }
            let value = IOHIDServiceClientCopyProperty(ref, key) ?? [] as CFArray
            result[id.uint64Value] = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        }
        return result
    }
    public func endpoints() throws -> [DJIServiceEndpoint] { available().compactMap(endpoint) }
    private func resolve(_ target: DJIServiceEndpoint) throws -> IOHIDServiceClient {
        guard let ref = available().first(where: { (IOHIDServiceClientGetRegistryID($0) as? NSNumber)?.uint64Value == target.service.registryID && endpoint($0) == target }) else { throw DJINativeError.serviceGone }
        return ref
    }
    public func read(_ endpoint: DJIServiceEndpoint) throws -> [DJIMapping.Entry] {
        try Self.decode(IOHIDServiceClientCopyProperty(resolve(endpoint), key))
    }
    public func write(_ endpoint: DJIServiceEndpoint, expected: [DJIMapping.Entry], replacement: [DJIMapping.Entry]) throws {
        let ref = try resolve(endpoint)
        // Reject external changes. IOKit offers no atomic compare-and-swap, so
        // another writer can still race this check; never claim atomic ownership.
        guard try Self.decode(IOHIDServiceClientCopyProperty(ref, key)) == expected else { throw DJINativeError.changedMapping }
        let value = replacement.map { ["HIDKeyboardModifierMappingSrc": NSNumber(value: $0.source),
                                      "HIDKeyboardModifierMappingDst": NSNumber(value: $0.destination)] } as CFArray
        guard IOHIDServiceClientSetProperty(ref, key, value) else { throw DJINativeError.writeRejected }
        guard try read(endpoint) == replacement else { throw DJINativeError.verificationFailed }
    }
}
