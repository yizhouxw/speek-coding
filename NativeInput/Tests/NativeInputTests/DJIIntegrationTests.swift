import XCTest
@testable import NativeInput

final class MappingMemory: DJIMappingBackend {
    let endpoint = DJIServiceEndpoint(service: .init(registryID: 10, vendorID: 11427, productID: 16401,
        usagePage: 12, usage: 1, transport: "USB"), deviceRegistryID: 20)
    var values: [DJIMapping.Entry] = [.init(source: 99, destination: 100)]
    var present = true
    var rejectWrite = false
    var failAfterWrite = false
    var writes: [UInt64] = []
    func endpoints() throws -> [DJIServiceEndpoint] { present ? [endpoint] : [] }
    func read(_ endpoint: DJIServiceEndpoint) throws -> [DJIMapping.Entry] {
        guard present, endpoint == self.endpoint else { throw DJINativeError.serviceGone }
        return values
    }
    func write(_ endpoint: DJIServiceEndpoint, expected: [DJIMapping.Entry], replacement: [DJIMapping.Entry]) throws {
        guard try read(endpoint) == expected else { throw DJINativeError.changedMapping }
        if rejectWrite { throw DJINativeError.writeRejected }
        writes.append(endpoint.service.registryID)
        values = replacement
        if failAfterWrite { failAfterWrite = false; throw DJINativeError.verificationFailed }
    }
}
final class MemoryJournal: DJIMappingJournal {
    var records: [DJIMappingRecord] = []
    var fail = false
    func save(_ records: [DJIMappingRecord]) throws {
        if fail { throw DJINativeError.journalInvalid }
        self.records = records
    }
}
final class DJIIntegrationTests: XCTestCase {
    func testConnectVerifyTriggerAndStopRestores() {
        let backend = MappingMemory(), journal = MemoryJournal()
        let original = backend.values
        var toggles = 0
        let input = DJINativeInput(backend: backend, journal: journal, diagnostic: { _ in }) { toggles += 1 }
        input.receive(.button(20, true))
        input.receive(.button(20, false))
        XCTAssertEqual(toggles, 0)
        input.receive(.connected(20))
        XCTAssertEqual(input.readyDeviceIDs, [20])
        XCTAssertEqual(backend.values, original + [.init(source: DJIMapping.volumeIncrement, destination: 0)])
        input.receive(.button(999, true))
        input.receive(.button(20, true)); input.receive(.button(20, true))
        input.receive(.button(20, false)); input.receive(.button(20, true))
        XCTAssertEqual(toggles, 2)
        XCTAssertEqual(input.stop(), [])
        XCTAssertEqual(backend.values, original)
        XCTAssertTrue(journal.records.isEmpty)
        XCTAssertEqual(backend.writes, [10, 10])
        input.receive(.button(20, true))
        XCTAssertEqual(toggles, 2)
    }
    func testNoWriteOnFailedHIDOpenOrUnrelatedDevice() {
        let backend = MappingMemory(), journal = MemoryJournal()
        let input = DJINativeInput(backend: backend, journal: journal, diagnostic: { _ in }) { XCTFail() }
        input.receive(.unavailable(20, -1))
        input.receive(.connected(999))
        input.receive(.button(20, true))
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertTrue(input.readyDeviceIDs.isEmpty)
    }
    func testWriteFailurePreventsRecordingAndPartialWriteRollsBack() throws {
        for partial in [false, true] {
            let backend = MappingMemory(), journal = MemoryJournal()
            let original = backend.values
            backend.rejectWrite = !partial; backend.failAfterWrite = partial
            let input = DJINativeInput(backend: backend, journal: journal, diagnostic: { _ in }) { XCTFail() }
            input.receive(.connected(20)); input.receive(.button(20, true))
            XCTAssertTrue(input.readyDeviceIDs.isEmpty)
            XCTAssertEqual(backend.values, original)
            XCTAssertTrue(journal.records.isEmpty)
        }
    }
    func testJournalFailurePreventsAnyDeviceWrite() {
        let backend = MappingMemory(), journal = MemoryJournal()
        journal.fail = true
        let leases = DJIMappingLeases(backend: backend, journal: journal)
        XCTAssertThrowsError(try leases.install(backend.endpoint))
        XCTAssertTrue(backend.writes.isEmpty)
    }
    func testRecoveryAndFailedRestoreRetention() throws {
        let backend = MappingMemory(), journal = MemoryJournal()
        let original = backend.values
        let leases = DJIMappingLeases(backend: backend, journal: journal)
        try leases.install(backend.endpoint)
        backend.rejectWrite = true
        XCTAssertFalse(leases.restoreAll().isEmpty)
        XCTAssertEqual(journal.records.count, 1)
        backend.rejectWrite = false
        let recovery = DJIMappingLeases(backend: backend, journal: journal)
        XCTAssertEqual(recovery.restoreAll(), [])
        XCTAssertEqual(backend.values, original)
        XCTAssertTrue(journal.records.isEmpty)
    }
    func testExternalChangesArePreservedAndTriggeringStops() {
        let backend = MappingMemory(), journal = MemoryJournal()
        let input = DJINativeInput(backend: backend, journal: journal, diagnostic: { _ in }) { XCTFail() }
        input.receive(.connected(20))
        backend.values = [.init(source: DJIMapping.volumeIncrement, destination: 33)]
        input.receive(.button(20, true))
        XCTAssertTrue(input.readyDeviceIDs.isEmpty)
        input.reconcileMappings()
        XCTAssertEqual(backend.values, [.init(source: DJIMapping.volumeIncrement, destination: 33)])
        XCTAssertTrue(journal.records.isEmpty)
    }
    func testDisconnectDiscardsOldServiceAndDoesNotInventRelease() {
        let backend = MappingMemory(), journal = MemoryJournal()
        var toggles = 0
        let input = DJINativeInput(backend: backend, journal: journal, diagnostic: { _ in }) { toggles += 1 }
        input.receive(.connected(20)); input.receive(.button(20, true))
        backend.present = false
        input.receive(.removed(20)); input.receive(.button(20, false))
        XCTAssertEqual(toggles, 1)
        XCTAssertTrue(journal.records.isEmpty)
        XCTAssertTrue(input.readyDeviceIDs.isEmpty)
    }
    func testRestorationPreservesConcurrentEditsToOtherMappings() throws {
        let backend = MappingMemory(), journal = MemoryJournal()
        let leases = DJIMappingLeases(backend: backend, journal: journal)
        try leases.install(backend.endpoint)
        backend.values[0] = .init(source: 99, destination: 200)
        backend.values.append(.init(source: 77, destination: 88))
        XCTAssertEqual(leases.restoreAll(), [])
        XCTAssertEqual(backend.values, [.init(source: 99, destination: 200), .init(source: 77, destination: 88)])
    }
    func testPreexistingSuppressionIsNeverRemoved() throws {
        let backend = MappingMemory(), journal = MemoryJournal()
        backend.values = [.init(source: DJIMapping.volumeIncrement, destination: 0)]
        let leases = DJIMappingLeases(backend: backend, journal: journal)
        try leases.install(backend.endpoint)
        XCTAssertTrue(leases.isReady(backend.endpoint))
        XCTAssertTrue(leases.restoreAll().isEmpty)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(backend.values.count, 1)
    }
    func testPropertyCodecFailsClosedOnUnknownOrMalformedEntries() throws {
        XCTAssertEqual(try DJIServiceMapping.decode(nil), [])
        XCTAssertThrowsError(try DJIServiceMapping.decode("not an array" as CFString))
        for entry: NSDictionary in [
            ["HIDKeyboardModifierMappingSrc": true, "HIDKeyboardModifierMappingDst": 0],
            ["HIDKeyboardModifierMappingSrc": -1, "HIDKeyboardModifierMappingDst": 0],
            ["HIDKeyboardModifierMappingSrc": 1.5, "HIDKeyboardModifierMappingDst": 0],
            ["HIDKeyboardModifierMappingSrc": 1, "HIDKeyboardModifierMappingDst": 0, "extra": 1]
        ] { XCTAssertThrowsError(try DJIServiceMapping.decode([entry] as CFArray)) }
    }
    func testDiskJournalSerializesOwnershipAndRecovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        var journal: DJIDiskJournal? = try DJIDiskJournal(url: url)
        XCTAssertThrowsError(try DJIDiskJournal(url: url))
        let backend = MappingMemory()
        let plan = try DJIMapping.plan(service: backend.endpoint.service, existing: [])
        try journal!.save([.init(endpoint: backend.endpoint, original: plan.original, installed: plan.installed)])
        journal = nil
        let reopened = try DJIDiskJournal(url: url)
        XCTAssertEqual(reopened.records.count, 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
