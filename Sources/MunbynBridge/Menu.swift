import AppKit
import ServiceManagement
import BridgeCore
@MainActor final class MenuController: NSObject,NSMenuDelegate {
    static func visibleJobs(_ jobs: [Job]) -> [Job] {
        let terminal: Set<JobState> = [.transmitted, .captured, .cancelled]
        // Never bury a retained/uncertain job behind a limit on recent history.
        return Array(jobs.filter { !terminal.contains($0.state) }.reversed())
            + Array(jobs.filter { terminal.contains($0.state) }.suffix(10).reversed())
    }
    let coordinator: Coordinator
    private let item = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
    private var settingsWindow: SettingsWindowController?
    init(_ coordinator: Coordinator) {
        self.coordinator = coordinator; super.init()
        item.button?.image = NSImage(systemSymbolName:"printer",accessibilityDescription:"MUNBYN ITPP130B Bridge")
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false; item.menu = menu
        coordinator.onChange = { [weak self] in
            self?.item.button?.toolTip = self?.coordinator.status
            self?.settingsWindow?.refresh()
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu,"MUNBYN ITPP130B Bridge",enabled:false)
        add(menu,coordinator.status,enabled:false)
        add(menu,coordinator.printer.status,enabled:false)
        menu.addItem(.separator())
        let allJobs = coordinator.jobs()
        let jobs = NSMenuItem(title:"Jobs (\(allJobs.count))",action:nil,keyEquivalent:""); let jobMenu = NSMenu()
        add(jobMenu,"Clear All Jobs…",request:.init(command:"clear-jobs",confirm:true),enabled:!allJobs.isEmpty)
        jobMenu.addItem(.separator())
        let stateTitles: [JobState: String] = [.queued: "Queued", .connecting: "Connecting", .sending: "Sending",
            .transmitted: "Transmitted (paper unconfirmed)", .captured: "Dry-run capture", .failedBeforeSend: "Failed before sending",
            .outcomeUnknown: "Outcome unknown — review required", .cancelled: "Cancelled"]
        let visible = Self.visibleJobs(allJobs)
        if visible.isEmpty { add(jobMenu,"No recent jobs",enabled:false) }
        for job in visible {
            let row = NSMenuItem(title:"\(job.id.uuidString.prefix(8)): \(stateTitles[job.state] ?? job.state.rawValue), \(job.pages) labels",action:nil,keyEquivalent:""); let actions = NSMenu()
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
        add(menu,"Release Printer",request:.init(command:"release"))
        menu.addItem(.separator())
        add(menu,"Settings…",selector:#selector(showSettings))
        menu.items.last?.keyEquivalent = ","
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
        Task { await perform(request, title: sender.title) }
    }
    private func perform(_ request: ControlRequest, title: String) async {
        let warnings: [String:String] = [
            "test-print":"This consumes one synthetic calibration label. Load the selected physical stock. The TSPL and BLE path is experimental; inspect the paper before routine printing.",
            "write-mode":request.value == "without-response" ? "Stream bulk data without response; send each page's last existing chunk with response and wait before releasing the link. Both write properties are required. This may reduce delay but requires a complete synthetic test label and QR scan before routine use. GATT responses do not confirm paper output. The setting is saved only for your selected printer." : "Use response writes for the selected printer. This can be slower. Availability is checked on connection.",
            "confirm-recovery":"Inspect the paper for partial/duplicate labels. A partial command may remain buffered. No software reset has been verified: power-cycle the printer before confirming. Cancel any matching job still pending in Print Center. This enables subsequent jobs.",
            "reprint":"The original may already have printed. This creates a new complete job and can produce duplicate labels. Do not also retry the original in Print Center.",
            "clear-jobs":"This permanently deletes all bridge job records and their local files. Pending labels will be lost. Active work must be cancelled and uncertain printer-buffer recovery confirmed first. Print Center jobs and diagnostic captures are separate and remain unchanged. This does not reset the printer. Ordinary deletion is not secure SSD erasure.",
            "clear-captures":"This permanently deletes all local opt-in diagnostic document captures. Ordinary deletion is not secure SSD erasure.",
            "delete":"This permanently deletes this job's local files using ordinary file deletion. Pending labels will be lost. It is not secure SSD erasure.",
            "uninstall-queue":"Remove only MUNBYN ITPP130B (Bluetooth). Pending/uncertain jobs must be reviewed first. Other printers remain unchanged.",
            "dry-run":request.value == "on" ? "Raster and TSPL captures may contain addresses or tracking numbers. Captures stay locally in the private diagnostics directory, persist until you delete them, and are never uploaded. Bluetooth will not be accessed for these jobs." : "Future queued jobs will be sent to the selected Bluetooth printer.",
            "quit":"Pending jobs stay on disk. Printing requires this user to be logged in and the bridge running. Active transmission will be cancelled; its outcome may become unknown."]
        if let warning = warnings[request.command], !confirm(title,warning) { return }
        do { _ = try await coordinator.command(request) } catch { alert("Action stopped",String(describing:error)) }
    }
    private func selectPrinter() async {
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
    private func diagnostics() async {
        do { let data = try await coordinator.command(.init(command:"doctor")); alert("Diagnostics (no document payloads)",String(decoding:data,as:UTF8.self)) } catch { alert("Diagnostics unavailable",String(describing:error)) }
    }
    @objc private func showSettings() {
        if settingsWindow == nil {
            let model = SettingsModel(snapshot: { [weak self] in
                guard let self else { return SettingsSnapshot(login: .unknown) }
                return SettingsSnapshot(login: LoginState(SMAppService.mainApp.status),
                    printerSelected: self.coordinator.printer.profile != nil, status: self.coordinator.status,
                    bluetooth: self.coordinator.printer.status, dryRun: self.coordinator.dryRun,
                    writePreference: self.coordinator.printer.profile?.writePreference)
            }, perform: { [weak self] action in
                guard let self else { return }
                switch action {
                case let .command(request, title): await self.perform(request, title: title)
                case .selectPrinter: await self.selectPrinter()
                case .diagnostics: await self.diagnostics()
                case .openData: NSWorkspace.shared.open(Paths.root)
                case .openLoginSettings: SMAppService.openSystemSettingsLoginItems()
                case .openSource:
                    if let url = URL(string: "https://github.com/cmyker/munbyn-itpp130b-macos") { NSWorkspace.shared.open(url) }
                }
            })
            settingsWindow = SettingsWindowController(model)
        }
        settingsWindow?.present()
    }
}
