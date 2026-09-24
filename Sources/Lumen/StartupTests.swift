import AppKit

/// Exercises actual AppKit launch callbacks and asynchronous session restoration.
/// Enabled only by the isolated startup test runner, never by an ordinary launch.
@MainActor
final class StartupTests {
    private let coordinator:ApplicationCoordinator
    private let scenario:String
    private let directory:URL
    private var observer:NSObjectProtocol?
    private var checks:[String:Bool]=[:]
    init?(coordinator:ApplicationCoordinator) {
        guard CommandLine.arguments.contains("--startup-tests"),
              let path=ProcessInfo.processInfo.environment["ORKHON_TEST_DATA"],
              let scenario=ProcessInfo.processInfo.environment["ORKHON_STARTUP_SCENARIO"] else{return nil}
        self.coordinator=coordinator;self.scenario=scenario;directory=URL(fileURLWithPath:path)
        observer=NotificationCenter.default.addObserver(forName:NSApplication.willFinishLaunchingNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {self?.willFinish()}
        }
    }
    private var file:URL {directory.appendingPathComponent("requested.swift")}
    private func willFinish() {
        checks["AppKit is running before didFinishLaunching"]=NSApp.isRunning
        if scenario=="early" || scenario=="reopen" {
            coordinator.application(NSApp,open:[file,file])
            _=coordinator.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            checks["Early events are buffered without creating a window"]=coordinator.windows.isEmpty
        }
        DispatchQueue.main.async { [self] in
            if scenario=="late" {coordinator.application(NSApp,open:[file])}
            if scenario=="restore-race",let first=coordinator.active {
                first.recoveryQueue.suspend()
                // The initial deferred restore runs between these two blocks.
                DispatchQueue.main.async {
                    self.coordinator.application(NSApp,open:[self.file])
                    first.recoveryQueue.resume()
                }
            }
            self.verify(after:0)
        }
    }
    private func verify(after attempts:Int) {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { [self] in
            let windows=coordinator.windows
            let expected=scenario=="session" ? 2:1
            let loaded=windows.count==expected && windows.allSatisfy{!$0.documents.contains(where:{$0.loading})}
            let ready=scenario=="session" ? windows.count==2:windows.first?.documents.contains(where:{$0.url==file})==true
            if (!loaded || !ready || attempts<3) && attempts<50 {verify(after:attempts+1);return}
            checks["Expected window count"]=windows.count==expected
            checks["No extra Untitled document"]=windows.allSatisfy{!$0.documents.contains(where:{$0.title=="Untitled"})}
            if scenario != "session" {
                checks["Requested file is opened exactly once"]=windows.flatMap(\.documents).filter{$0.url==file}.count==1
                checks["Saved windows do not accompany a Finder open"]=windows.flatMap(\.documents).allSatisfy{$0.url==file}
                coordinator.application(NSApp,open:[file,file])
                checks["Repeated file opens reuse their window"]=coordinator.windows.count==1 && coordinator.active?.documents.count==1
                let another=coordinator.newWindow()
                checks["Explicit New Window still creates a window"]=coordinator.windows.count==2
                another.finishClosing();another.window.orderOut(nil);coordinator.removeWindow(another)
                if scenario=="reopen" {
                    for window in coordinator.windows {window.finishClosing();window.window.orderOut(nil);coordinator.removeWindow(window)}
                    _=coordinator.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
                    checks["Reopen after closing all windows creates one"]=coordinator.windows.count==1
                }
            }
            let report:[String:Any]=["checks":checks,"failures":checks.filter{!$0.value}.map(\.key),"scenario":scenario]
            if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:directory.appendingPathComponent("result.json"))}
            if let observer {NotificationCenter.default.removeObserver(observer)}
            NSApp.terminate(nil)
        }
    }
}
