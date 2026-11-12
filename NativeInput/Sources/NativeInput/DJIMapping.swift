import Foundation

/// Pure planning layer: never changes a device or system property.
public enum DJIMapping {
    public static let volumeIncrement: UInt64 = (0x0c << 32) | 0xe9
    public struct Entry: Equatable {
        public let source: UInt64
        public let destination: UInt64
        public init(source: UInt64, destination: UInt64) {
            self.source = source; self.destination = destination
        }
    }
    public struct Service {
        public let registryID: UInt64
        public let vendorID: Int
        public let productID: Int
        public let usagePage: Int
        public let usage: Int
        public let transport: String
        public init(registryID: UInt64, vendorID: Int, productID: Int, usagePage: Int, usage: Int, transport: String) {
            self.registryID = registryID; self.vendorID = vendorID; self.productID = productID
            self.usagePage = usagePage; self.usage = usage; self.transport = transport
        }
    }
    public enum PlanningError: Error { case wrongService, conflictingMapping }
    public struct Plan {
        public let registryID: UInt64
        public let original: [Entry]
        public let installed: [Entry]
        /// Restore only if nobody changed the mapping since installation. A new
        /// registry ID after reconnect is a new service, never an old lease.
        public func restoration(registryID: UInt64, current: [Entry]) -> [Entry]? {
            guard registryID == self.registryID, current == installed, original != installed else { return nil }
            return original
        }
    }
    public static func plan(service: Service, existing: [Entry]) throws -> Plan {
        guard service.registryID != 0, service.vendorID == 11427, service.productID == 16401,
              service.usagePage == 12, service.usage == 1, service.transport == "USB" else {
            throw PlanningError.wrongService
        }
        let matches = existing.filter { $0.source == volumeIncrement }
        guard matches.count <= 1, matches.allSatisfy({ $0.destination == 0 }) else {
            throw PlanningError.conflictingMapping
        }
        let installed = matches.isEmpty ? existing + [Entry(source: volumeIncrement, destination: 0)] : existing
        return Plan(registryID: service.registryID, original: existing, installed: installed)
    }
}
