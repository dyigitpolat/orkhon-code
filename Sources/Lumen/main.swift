import AppKit
import Foundation

let lumenStart = DispatchTime.now().uptimeNanoseconds
func startupTrace(_ stage:String) {
    if ProcessInfo.processInfo.environment["LUMEN_PROFILE"] != nil {fputs("\(stage): \(Double(DispatchTime.now().uptimeNanoseconds-lumenStart)/1e6) ms\n",stderr)}
}
if ProcessInfo.processInfo.arguments.contains(where:{["--self-test","--revision-tests","--startup-tests"].contains($0)}) && ProcessInfo.processInfo.environment["ORKHON_TEST_DATA"] == nil {
    fputs("Set ORKHON_TEST_DATA to an isolated test directory before running integration tests.\n",stderr);exit(2)
}
MainActor.assumeIsolated {
    startupTrace("main")
    let app = NSApplication.shared
    startupTrace("NSApplication")
    let delegate = ApplicationCoordinator()
    startupTrace("delegate init")
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    startupTrace("activation policy")
    let startupTests=StartupTests(coordinator:delegate)
    withExtendedLifetime((delegate,startupTests)) { app.run() }
}
