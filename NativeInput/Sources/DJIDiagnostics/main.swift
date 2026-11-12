import Foundation
import NativeInput
import Darwin

setbuf(stdout, nil)
let args = Array(CommandLine.arguments.dropFirst())
do {
    if args.isEmpty || args == ["--inspect"] {
        let mapping = DJIServiceMapping()
        let endpoints = try mapping.endpoints()
        print("Eligible DJI services: \(endpoints.count)")
        for endpoint in endpoints {
            let values = try mapping.read(endpoint)
            let plan = try DJIMapping.plan(service: endpoint.service, existing: values)
            print("service=\(endpoint.service.registryID) rawDevice=\(endpoint.deviceRegistryID) existingMappings=\(values.count) changes=\(plan.original != plan.installed)")
        }
    } else if args == ["--verify-write"] {
        for result in try DJINativeInput.verifyMappingRoundTrip() { print(result) }
    } else if args == ["--recover"] {
        let warnings = try DJINativeInput.recoverMappings()
        for warning in warnings { print(warning) }
        if !warnings.isEmpty { exit(1) }
        print("Recovery complete")
    } else if args.count == 2, args[0] == "--listen", let seconds = Double(args[1]), seconds.isFinite, (1...300).contains(seconds) {
        var taps = 0
        let input = try DJINativeInput(diagnostic: { print($0) }) { taps += 1; print("DJI_PRESS \(taps)") }
        var stopping = false
        let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { stopping = true }
            source.resume()
            return source
        }
        try input.start()
        let end = Date(timeIntervalSinceNow: seconds)
        while !stopping && Date() < end { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) }
        let ready = input.readyDeviceIDs.count
        let warnings = input.stop()
        signals.forEach { $0.cancel() }
        warnings.forEach { print($0) }
        print("DONE readyDevices=\(ready) presses=\(taps) restorationWarnings=\(warnings.count)")
        if ready == 0 || !warnings.isEmpty { exit(1) }
    } else {
        print("Usage: dji-input-diagnose [--inspect | --verify-write | --recover | --listen SECONDS]")
        print("Default is read-only. --verify-write briefly installs and restores only the DJI volume-up mapping.")
        print("--listen installs suppression and observes raw DJI input; it never starts recording. SIGINT/SIGTERM restore mappings.")
        if args != ["--help"] { exit(2) }
    }
} catch { fputs("DJI diagnostic failed: \(error)\n", stderr); exit(1) }
