import AppKit
import ServiceManagement
import BridgeCore
@MainActor final class MenuController: NSObject,NSMenuDelegate {
    let coordinator: Coordinator
    private let item = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
    init(_ coordinator: Coordinator) {
        self.coordinator = coordinator; super.init()
        item.button?.image = NSImage(systemSymbolName:"printer",accessibilityDescription:"MUNBYN ITPP130B Bridge")
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false; item.menu = menu
        coordinator.onChange = { [weak self] in self?.item.button?.toolTip = self?.coordinator.status }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu,"MUNBYN ITPP130B Bridge — alpha",enabled:false)
        add(menu,coordinator.status,enabled:false)
        add(menu,coordinator.printer.status,enabled:false)
        menu.addItem(.separator())
        add(menu,"Select Printer…",selector:#selector(selectPrinter))
        add(menu,"Connect (release after 10 seconds)",request:.init(command:"connect"))
        add(menu,"Disconnect / Release",request:.init(command:"release"))
        let mode = NSMenuItem(title:"BLE Write Mode",action:nil,keyEquivalent:""); let modeMenu = NSMenu()
        add(modeMenu,"With Response (conservative)",request:.init(command:"write-mode",value:"with-response"))
        add(modeMenu,"Without Response (calibrate on paper)…",request:.init(command:"write-mode",value:"without-response"))
        mode.submenu = modeMenu; menu.addItem(mode)
        let test = NSMenuItem(title:"One-label Test Print",action:nil,keyEquivalent:""); let submenu = NSMenu()
        add(submenu,"100 × 150 mm",request:.init(command:"test-print",value:"mm100x150"))
        add(submenu,"4 × 6 inches",request:.init(command:"test-print",value:"inch4x6")); test.submenu = submenu; menu.addItem(test)
        menu.addItem(.separator())
        let jobs = NSMenuItem(title:"Jobs (\(coordinator.jobs().count))",action:nil,keyEquivalent:""); let jobMenu = NSMenu()
        for job in coordinator.jobs().suffix(20).reversed() {
            let row = NSMenuItem(title:"\(job.id.uuidString.prefix(8)): \(job.state.rawValue), \(job.pages) labels",action:nil,keyEquivalent:""); let actions = NSMenu()
            if [.queued,.connecting,.sending,.failedBeforeSend].contains(job.state) { add(actions,"Cancel",request:.init(command:"cancel",value:job.id.uuidString)) }
            if job.state == .failedBeforeSend { add(actions,"Retry (no printer bytes sent)",request:.init(command:"retry",value:job.id.uuidString)) }
            if job.state == .outcomeUnknown {
                if !job.recoveryConfirmed { add(actions,"Confirm Printer Buffer Recovery…",request:.init(command:"confirm-recovery",value:job.id.uuidString,confirm:true)) }
                else { add(actions,"Reprint — Duplicate Warning…",request:.init(command:"reprint",value:job.id.uuidString,confirm:true)) }
            }
            add(actions,"Delete Job Data…",request:.init(command:"delete",value:job.id.uuidString,confirm:true))
            row.submenu = actions; jobMenu.addItem(row)
        }
        jobs.submenu = jobMenu; menu.addItem(jobs)
        add(menu,"Repair / Install Printer Queue",request:.init(command:"install-queue"))
        add(menu,"Uninstall Project Queue…",request:.init(command:"uninstall-queue",confirm:true))
        add(menu,"Start at Login: \(coordinator.loginStatus)",request:.init(command:"login",value:SMAppService.mainApp.status == .enabled ? "off" : "on"))
        add(menu,coordinator.dryRun ? "Disable Dry Run…" : "Enable Dry Run (Sensitive Captures)…",request:.init(command:"dry-run",value:coordinator.dryRun ? "off" : "on",confirm:true))
        add(menu,"Delete Sensitive Captures…",request:.init(command:"clear-captures",confirm:true))
        add(menu,"Diagnostics…",selector:#selector(diagnostics))
        add(menu,"Open Private Application Data",selector:#selector(openData))
        add(menu,"About…",selector:#selector(about))
        add(menu,"Quit…",request:.init(command:"quit",confirm:true))
    }
    private func add(_ menu:NSMenu,_ title:String,selector:Selector? = nil,request:ControlRequest? = nil,enabled:Bool = true) {
        let row = NSMenuItem(title:title,action:selector ?? (request == nil ? nil : #selector(action(_:))),keyEquivalent:"")
        row.target = self; row.isEnabled = enabled; row.representedObject = request; menu.addItem(row)
    }
    private func alert(_ title:String,_ message:String) {
        NSApp.activate(ignoringOtherApps:true)
        let a = NSAlert(); a.messageText = title; a.informativeText = message; a.runModal()
    }
    private func confirm(_ title:String,_ message:String) -> Bool {
        NSApp.activate(ignoringOtherApps:true)
        let a = NSAlert(); a.messageText = title; a.informativeText = message; a.addButton(withTitle:"Continue"); a.addButton(withTitle:"Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
    @objc func action(_ sender:NSMenuItem) {
        guard let request = sender.representedObject as? ControlRequest else { return }
        let warnings: [String:String] = [
            "test-print":"This consumes one synthetic calibration label. Load the selected physical stock. The TSPL and BLE path is experimental; inspect the paper before routine printing.",
            "write-mode":request.value == "without-response" ? "Stream bulk data without response; send each page's last existing chunk with response and wait before releasing the link. Both write properties are required. This may reduce delay but requires a complete synthetic test label and QR scan before routine use. GATT responses do not confirm paper output. The setting is saved only for your selected printer." : "Use response writes for the selected printer. This can be slower. Availability is checked on connection.",
            "confirm-recovery":"Inspect the paper for partial/duplicate labels. A partial command may remain buffered. No software reset has been verified: power-cycle the printer before confirming. Cancel any matching job still pending in Print Center. This enables subsequent jobs.",
            "reprint":"The original may already have printed. This creates a new complete job and can produce duplicate labels. Do not also retry the original in Print Center.",
            "clear-captures":"This permanently deletes all local opt-in diagnostic document captures. Ordinary deletion is not secure SSD erasure.",
            "delete":"This permanently deletes this job's local files using ordinary file deletion. Pending labels will be lost. It is not secure SSD erasure.",
            "uninstall-queue":"Remove only MUNBYN ITPP130B (Bluetooth). Pending/uncertain jobs must be reviewed first. Other printers remain unchanged.",
            "dry-run":request.value == "on" ? "Raster and TSPL captures may contain addresses or tracking numbers. Captures stay locally in the private diagnostics directory, persist until you delete them, and are never uploaded. Bluetooth will not be accessed for these jobs." : "Future queued jobs will be sent to the selected Bluetooth printer.",
            "quit":"Pending jobs stay on disk. Printing requires this user to be logged in and the bridge running. Active transmission will be cancelled; its outcome may become unknown."]
        if let warning = warnings[request.command], !confirm(sender.title,warning) { return }
        Task { do { _ = try await coordinator.command(request) } catch { alert("Action stopped",String(describing:error)) } }
    }
    @objc func selectPrinter() {
        Task {
            do {
                _ = try await coordinator.command(.init(command:"scan"))
                guard !coordinator.devices.isEmpty else { alert("No advertisements found","Turn on the ITPP130B and release it in the phone app. It may already be connected elsewhere; that is only a possibility."); return }
                let popup = NSPopUpButton(frame:NSRect(x:0,y:0,width:420,height:28))
                for device in coordinator.devices { popup.addItem(withTitle:"\(device.name) (\(device.rssi) dBm, \(device.identifier.uuidString.suffix(6)))") }
                let a = NSAlert(); a.messageText = "Select your ITPP130B"; a.informativeText = "Verify the physical printer. Names and generic UUIDs do not establish identity. This probes services without printing, saves this device only, then releases it."; a.accessoryView = popup
                a.addButton(withTitle:"Select and Verify"); a.addButton(withTitle:"Cancel"); NSApp.activate(ignoringOtherApps:true)
                if a.runModal() == .alertFirstButtonReturn {
                    let device = coordinator.devices[popup.indexOfSelectedItem]
                    _ = try await coordinator.command(.init(command:"select",value:device.identifier.uuidString))
                    alert("Printer selected","Expected writable characteristic verified for the selected peripheral. Physical printing, dimensions and phone coexistence still require testing.")
                }
            } catch { alert("Discovery stopped",String(describing:error)) }
        }
    }
    @objc func diagnostics() {
        Task { do { let data = try await coordinator.command(.init(command:"doctor")); alert("Diagnostics (no document payloads)",String(decoding:data,as:UTF8.self)) } catch { alert("Diagnostics unavailable",String(describing:error)) } }
    }
    @objc func openData() { NSWorkspace.shared.open(Paths.root) }
    @objc func about() { alert("MUNBYN ITPP130B Bridge 0.1.0-alpha.1","Independent open-source project; not affiliated with MUNBYN. MIT original code. Hardware verification remains required. Source: https://github.com/cmyker/munbyn-itpp130b-macos") }
}
