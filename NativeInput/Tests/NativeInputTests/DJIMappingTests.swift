import XCTest
@testable import NativeInput

final class DJIMappingTests: XCTestCase {
    private func service(vendor: Int = 11427, product: Int = 16401, page: Int = 12, usage: Int = 1, transport: String = "USB") -> DJIMapping.Service {
        .init(registryID: 123, vendorID: vendor, productID: product, usagePage: page, usage: usage, transport: transport)
    }
    func testOnlyDJIConsumerServiceIsEligible() {
        for s in [service(vendor: 1452), service(product: 1), service(page: 1, usage: 6), service(page: 1, usage: 2), service(transport: "Bluetooth")] {
            XCTAssertThrowsError(try DJIMapping.plan(service: s, existing: []))
        }
    }
    func testPreservesEveryOtherMappingAndRestoresOriginal() throws {
        let original = [DJIMapping.Entry(source: (0x0c << 32) | 0xea, destination: 42), .init(source: 99, destination: 100)]
        let plan = try DJIMapping.plan(service: service(), existing: original)
        XCTAssertEqual(plan.installed, original + [.init(source: DJIMapping.volumeIncrement, destination: 0)])
        XCTAssertEqual(plan.restoration(registryID: 123, current: plan.installed), original)
        XCTAssertNil(plan.restoration(registryID: 124, current: plan.installed))
        XCTAssertEqual(plan.restoration(registryID: 123, current: plan.installed + [.init(source: 1, destination: 2)]), original + [.init(source: 1, destination: 2)])
    }
    func testUserMappingConflictIsNeverOverwritten() {
        XCTAssertThrowsError(try DJIMapping.plan(service: service(), existing: [.init(source: DJIMapping.volumeIncrement, destination: 99)]))
        XCTAssertThrowsError(try DJIMapping.plan(service: service(), existing: Array(repeating: .init(source: DJIMapping.volumeIncrement, destination: 0), count: 2)))
    }
    func testExistingSuppressionIsNotOwnedOrRemoved() throws {
        let existing = [DJIMapping.Entry(source: DJIMapping.volumeIncrement, destination: 0)]
        let plan = try DJIMapping.plan(service: service(), existing: existing)
        XCTAssertEqual(plan.installed, existing)
        XCTAssertNil(plan.restoration(registryID: 123, current: existing))
    }
}
