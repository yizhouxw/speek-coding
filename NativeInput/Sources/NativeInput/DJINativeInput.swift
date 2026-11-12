import Foundation
import CoreGraphics

/// Couples raw input to a verified, service-scoped suppression lease. No record
/// callback is delivered while open/mapping verification is incomplete.
public final class DJINativeInput {
    public var isRunning: Bool { observer != nil }
    public private(set) var readyDeviceIDs = Set<UInt64>()
    private let backend: DJIMappingBackend
    private let leases: DJIMappingLeases
    private var observer: DJIObserver?
    private var timer: Timer?
    private var connected = Set<UInt64>()
    private var installed: [UInt64: DJIServiceEndpoint] = [:]
    private var pressed = Set<UInt64>()
    private var lastMessage: String?
    private let diagnostic: (String) -> Void
    private let handler: () -> Void

    public convenience init(diagnostic: @escaping (String) -> Void = { _ in }, handler: @escaping () -> Void) throws {
        let journal = try DJIDiskJournal()
        self.init(backend: DJIServiceMapping(), journal: journal, diagnostic: diagnostic, handler: handler)
    }
    init(backend: DJIMappingBackend, journal: DJIMappingJournal, diagnostic: @escaping (String) -> Void, handler: @escaping () -> Void) {
        self.backend = backend
        self.leases = DJIMappingLeases(backend: backend, journal: journal)
        self.diagnostic = diagnostic
        self.handler = handler
    }
    /// Recovery can run on app startup even when the preference is now disabled.
    public static func recoverMappings() throws -> [String] {
        let journal = try DJIDiskJournal()
        return DJIMappingLeases(backend: DJIServiceMapping(), journal: journal).restoreAll()
    }
    /// Bounded property round trip only: no input synthesis, audio or recording.
    public static func verifyMappingRoundTrip() throws -> [String] {
        let backend = DJIServiceMapping()
        let journal = try DJIDiskJournal()
        let leases = DJIMappingLeases(backend: backend, journal: journal)
        var results = leases.restoreAll()
        defer { for warning in leases.restoreAll() { fputs("\(warning)\n", stderr) } }
        let endpoints = try backend.endpoints()
        guard !endpoints.isEmpty else { throw DJINativeError.serviceGone }
        for endpoint in endpoints {
            let original = try backend.read(endpoint)
            let before = try backend.allMappingValues()
            try leases.install(endpoint)
            let during = try backend.allMappingValues()
            guard before.filter({ $0.key != endpoint.service.registryID }) == during.filter({ $0.key != endpoint.service.registryID }) else { throw DJINativeError.verificationFailed }
            guard leases.isReady(endpoint) else { throw DJINativeError.verificationFailed }
            let warnings = leases.restore(id: endpoint.service.registryID)
            guard warnings.isEmpty, try backend.read(endpoint) == original, try backend.allMappingValues() == before else { throw DJINativeError.verificationFailed }
            results.append("Service \(endpoint.service.registryID): targeted write/read-back/restore verified; other HID services unchanged while installed.")
        }
        return results
    }
    public func start() throws {
        precondition(Thread.isMainThread)
        guard observer == nil else { throw InputStartError.alreadyStarted }
        for warning in leases.restoreAll() { report(warning) }
        let input = DJIObserver { [weak self] event in self?.receive(event) }
        try input.start()
        observer = input
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.reconcile() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func receive(_ event: DJIObserver.Event) {
        switch event {
        case .connected(let id): connected.insert(id); reconcileMappings()
        case .removed(let id):
            connected.remove(id); pressed.remove(id); readyDeviceIDs.remove(id)
            if let endpoint = installed.removeValue(forKey: id) {
                for warning in leases.restore(id: endpoint.service.registryID) { report(warning) }
            }
        case .unavailable(let id, let code): report("HID device \(id) unavailable: \(code); mapping not installed.")
        case .button(let id, let down):
            if !down { pressed.remove(id); return }
            guard pressed.insert(id).inserted else { return }
            guard connected.contains(id), readyDeviceIDs.contains(id),
                  let endpoint = installed[id], leases.isReady(endpoint) else {
                readyDeviceIDs.remove(id)
                return
            }
            handler()
        }
    }
    func reconcile() {
        // Revocation stops raw input and restores mappings rather than silently
        // leaving a suppressed button that can no longer trigger recording.
        guard CGPreflightListenEventAccess() else { _ = stop(); report("Input Monitoring unavailable."); return }
        reconcileMappings()
    }
    func reconcileMappings() {
        do {
            let available = try backend.endpoints()
            for id in Array(connected) {
                if let endpoint = installed[id] {
                    if available.contains(endpoint), leases.isReady(endpoint) { readyDeviceIDs.insert(id); continue }
                    readyDeviceIDs.remove(id)
                    for warning in leases.restore(id: endpoint.service.registryID) { report(warning) }
                    installed.removeValue(forKey: id)
                    // Require a reconnect/restart after external mapping changes.
                    report("Suppression lost for device \(id); native triggering stopped.")
                    connected.remove(id)
                    continue
                }
                let matches = available.filter { $0.deviceRegistryID == id }
                guard matches.count == 1 else {
                    report("Waiting for exactly one DJI event service for device \(id).")
                    continue
                }
                do {
                    try leases.install(matches[0])
                    installed[id] = matches[0]
                    readyDeviceIDs.insert(id)
                    report("DJI mapping verified for device \(id).")
                } catch { report("DJI mapping unavailable: \(error)") }
            }
        } catch { readyDeviceIDs.removeAll(); report("Cannot enumerate DJI services: \(error)") }
    }
    private func report(_ message: String) {
        if message != lastMessage { diagnostic(message); lastMessage = message }
    }
    @discardableResult public func stop() -> [String] {
        precondition(Thread.isMainThread)
        readyDeviceIDs.removeAll()
        timer?.invalidate(); timer = nil
        observer?.stop(); observer = nil
        connected.removeAll(); pressed.removeAll(); installed.removeAll()
        return leases.restoreAll()
    }
    deinit { _ = stop() }
}
