import AppKit
import BridgeCore
@MainActor final class AppDelegate: NSObject,NSApplicationDelegate {
    var coordinator: Coordinator?
    var menu: MenuController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let c = try Coordinator(dryRun:CommandLine.arguments.contains("--dry-run")); coordinator = c
            menu = MenuController(c); try c.start()
        } catch {
            if String(describing:error) == "Bridge is already running" { NSApp.terminate(nil); return }
            let a = NSAlert(); a.messageText = "Bridge could not start"; a.informativeText = String(describing:error); a.runModal()
            coordinator?.stop(); NSApp.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { coordinator?.stop() }
}
@main struct BridgeApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(); app.delegate = delegate; app.run()
    }
}
