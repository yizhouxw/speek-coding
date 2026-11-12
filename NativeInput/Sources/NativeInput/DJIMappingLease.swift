import Foundation
import Darwin

struct DJIMappingRecord: Codable {
    let endpoint: DJIServiceEndpoint
    let original: [DJIMapping.Entry]
    let installed: [DJIMapping.Entry]
}

protocol DJIMappingJournal: AnyObject {
    var records: [DJIMappingRecord] { get }
    func save(_ records: [DJIMappingRecord]) throws
}

/// One owner across the app and diagnostic CLI. Journal is written before the
/// device property, so a later launch can recover an interrupted transaction.
final class DJIDiskJournal: DJIMappingJournal {
    private struct Document: Codable { let version: Int; let boot: String; let records: [DJIMappingRecord] }
    private let url: URL
    private let boot: String
    private var lock: Int32 = -1
    private(set) var records: [DJIMappingRecord] = []
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/speek-coding/native-dji-mappings.json")
    }
    init(url: URL = DJIDiskJournal.defaultURL) throws {
        self.url = url
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { throw DJINativeError.journalInvalid }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { throw DJINativeError.journalInvalid }
        boot = String(cString: bytes)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DJINativeError.alreadyOwned }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw DJINativeError.alreadyOwned }
        lock = fd
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 1_048_576 else { throw DJINativeError.journalInvalid }
                let doc = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
                guard doc.version == 1 else { throw DJINativeError.journalInvalid }
                // Registry IDs alone must never be trusted across a reboot.
                if doc.boot == boot { records = doc.records }
            }
        } catch { close(fd); lock = -1; throw error }
    }
    func save(_ records: [DJIMappingRecord]) throws {
        let data = try JSONEncoder().encode(Document(version: 1, boot: boot, records: records))
        try data.write(to: url, options: [.atomic])
        self.records = records
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
}

final class DJIMappingLeases {
    private let backend: DJIMappingBackend
    private let journal: DJIMappingJournal
    private var active: [UInt64: DJIServiceEndpoint] = [:]
    init(backend: DJIMappingBackend, journal: DJIMappingJournal) {
        self.backend = backend; self.journal = journal
    }
    func install(_ endpoint: DJIServiceEndpoint) throws {
        let id = endpoint.service.registryID
        guard !journal.records.contains(where: { $0.endpoint.service.registryID == id }) else { throw DJINativeError.journalInvalid }
        let original = try backend.read(endpoint)
        let plan = try DJIMapping.plan(service: endpoint.service, existing: original)
        if plan.original != plan.installed {
            let record = DJIMappingRecord(endpoint: endpoint, original: original, installed: plan.installed)
            try journal.save(journal.records + [record])
            do { try backend.write(endpoint, expected: original, replacement: plan.installed) }
            catch {
                _ = restore(id: id)
                throw error
            }
        }
        do {
            guard try backend.read(endpoint) == plan.installed else { throw DJINativeError.verificationFailed }
        } catch {
            _ = restore(id: id)
            throw error
        }
        active[id] = endpoint
    }
    func isReady(_ endpoint: DJIServiceEndpoint) -> Bool {
        guard active[endpoint.service.registryID] == endpoint,
              let current = try? backend.read(endpoint) else { return false }
        let mapping = current.filter { $0.source == DJIMapping.volumeIncrement }
        return mapping.count == 1 && mapping[0].destination == 0
    }
    /// Returns warnings; failed writes remain journaled for recovery. Conflicting
    /// external edits are preserved and ownership is abandoned, never overwritten.
    @discardableResult func restore(id: UInt64) -> [String] {
        active.removeValue(forKey: id)
        guard let record = journal.records.first(where: { $0.endpoint.service.registryID == id }) else { return [] }
        var warning: String?
        do {
            let plan = try DJIMapping.plan(service: record.endpoint.service, existing: record.original)
            guard plan.installed == record.installed else { throw DJINativeError.journalInvalid }
            let current = try backend.read(record.endpoint)
            if let restored = plan.restoration(registryID: id, current: current) {
                try backend.write(record.endpoint, expected: current, replacement: restored)
            } else if current != record.original {
                warning = "Mapping changed externally on service \(id); preserved current mapping."
            }
        } catch DJINativeError.serviceGone {
            // A removed service has no surviving property to restore.
        } catch { return ["Restore failed on service \(id): \(error)"] }
        do { try journal.save(journal.records.filter { $0.endpoint.service.registryID != id }) }
        catch { return ["Could not update recovery journal: \(error)"] }
        return warning.map { [$0] } ?? []
    }
    @discardableResult func restoreAll() -> [String] {
        active.removeAll()
        return journal.records.map { $0.endpoint.service.registryID }.flatMap { restore(id: $0) }
    }
}
