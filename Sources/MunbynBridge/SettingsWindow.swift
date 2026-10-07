import AppKit
import BridgeCore

/// Presentation only: loading/refreshing this window never registers login,
/// scans Bluetooth, installs a queue or submits a print job.
@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    private let login = NSButton(checkboxWithTitle: "Start at Login", target: nil, action: nil)
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let loginApproval = NSButton(title: "Open Login Items…", target: nil, action: nil)
    private let printerStatus = NSTextField(wrappingLabelWithString: "")
    private let jobStatus = NSTextField(wrappingLabelWithString: "")
    private let media = NSPopUpButton(frame: .zero, pullsDown: false)
    private let writeMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dryRun = NSButton(checkboxWithTitle: "Dry Run — capture locally instead of printing", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var actionButtons: [NSButton] = []
    private let tabs = NSTabView()
    private var isPresented = false

    init(_ model: SettingsModel) {
        self.model = model
        super.init(window: nil)
        model.onChange = { [weak self] in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MUNBYN Bridge Settings"
        window.isReleasedWhenClosed = false; window.delegate = self
        self.window = window
        guard let content = window.contentView else { return }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.tabViewType = .topTabsBezelBorder
        content.addSubview(tabs)
        progress.style = .spinning; progress.controlSize = .small
        progress.isDisplayedWhenStopped = false; progress.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(progress)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -32),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            progress.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
        ])
        addTab("General", views: generalViews())
        addTab("Printer", views: printerViews())
        addTab("Advanced", views: advancedViews())
        window.center()
        refresh()
    }

    func present() {
        // init(window: nil) marks a nibless controller loaded without a window;
        // showWindow alone will not call our programmatic loadWindow override.
        if window == nil { loadWindow() }
        isPresented = true
        showWindow(nil); refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func windowDidBecomeKey(_ notification: Notification) { refresh() }
    func windowWillClose(_ notification: Notification) { isPresented = false }

    func refresh() {
        guard isWindowLoaded, window != nil else { return }
        let state = model.snapshot()
        login.state = state.login.checkboxState
        loginStatus.stringValue = state.login.statusText
        loginApproval.isHidden = state.login != .requiresApproval
        login.isEnabled = !model.isPerforming && state.login != .unknown
        printerStatus.stringValue = state.printerSelected ? "An ITPP130B is selected. \(state.bluetooth)" : "No printer selected. Choose your physical ITPP130B below."
        jobStatus.stringValue = state.status
        dryRun.state = state.dryRun ? .on : .off
        dryRun.isEnabled = !model.isPerforming
        writeMode.selectItem(at: state.writePreference == nil ? 0 : state.writePreference == .withoutResponse ? 1 : 2)
        writeMode.isEnabled = !model.isPerforming && state.printerSelected
        media.isEnabled = !model.isPerforming
        for button in actionButtons { button.isEnabled = !model.isPerforming }
        if model.isPerforming { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    private func generalViews() -> [NSView] {
        login.target = self; login.action = #selector(toggleLogin); login.allowsMixedState = true
        configure(loginApproval, .openLoginSettings)
        return [heading("MUNBYN ITPP130B Bridge"),
                note("Print from the normal macOS print dialog. Keep the bridge running in your logged-in session."),
                divider(), login,
                note("Launch automatically when you log in. macOS may require approval."), loginStatus, loginApproval,
                divider(), heading("About", size: 14),
                note("Version 0.1.0-alpha.3 · Experimental\nIndependent open-source project, not affiliated with MUNBYN. Original code is MIT licensed."),
                button("Project and documentation…", .openSource)]
    }

    private func printerViews() -> [NSView] {
        media.addItems(withTitles: ["100 × 150 mm", "4 × 6 inches"])
        media.setAccessibilityLabel("Test label media")
        return [heading("Printer"), printerStatus, jobStatus,
                note("The bridge connects for each job and releases the link afterward. Only the ITPP130B is supported."),
                row([button("Select Printer…", .selectPrinter),
                     button("Check Connection", .command(.init(command: "connect"), "Check Connection"))]),
                divider(), heading("Test label", size: 14),
                note("Choose matching stock. A physical test consumes one label; inspect its output."),
                row([media, button("Print Test Label…", selector: #selector(testPrint))]),
                divider(), heading("System printer queue", size: 14),
                note("Create or repair the separate Bluetooth printer. Your existing USB queue and default printer are preserved."),
                row([button("Repair / Install Printer Queue…", .command(.init(command: "install-queue"), "Repair / Install Printer Queue")),
                     button("Remove Queue…", .command(.init(command: "uninstall-queue", confirm: true), "Remove Printer Queue"))])]
    }

    private func advancedViews() -> [NSView] {
        writeMode.addItems(withTitles: ["Automatic — verify on connection", "Streaming (without response)", "With response"])
        writeMode.menu?.autoenablesItems = false
        writeMode.item(at: 0)?.isEnabled = false
        writeMode.target = self; writeMode.action = #selector(changeWriteMode)
        writeMode.setAccessibilityLabel("BLE write mode")
        dryRun.target = self; dryRun.action = #selector(toggleDryRun)
        return [heading("Advanced"), note("Change these options only when investigating a printing problem."),
                heading("BLE write mode", size: 14), writeMode,
                note("An explicit mode is saved for the selected printer. Availability is checked on connection; changing it requires another physical test."),
                divider(), dryRun,
                note("Captures can contain sensitive document contents. They stay on this Mac until you delete them. No Bluetooth writes are made for captured jobs."),
                button("Delete Sensitive Captures…", .command(.init(command: "clear-captures", confirm: true), "Delete Sensitive Captures")),
                divider(), heading("Diagnostics", size: 14),
                row([button("Show Diagnostics…", .diagnostics), button("Open Private Application Data…", .openData)])]
    }

    private func addTab(_ title: String, views: [NSView]) {
        let pane = NSView()
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: pane.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor, constant: -20)
        ])
        for view in views where view is NSTextField || view is NSBox {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let tab = NSTabViewItem(identifier: title); tab.label = title; tab.view = pane
        tabs.addTabViewItem(tab)
    }
    private func heading(_ title: String, size: CGFloat = 20) -> NSTextField {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: size, weight: .semibold)
        return label
    }
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text); label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12); return label
    }
    private func divider() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 10; return stack
    }
    private func configure(_ button: NSButton, _ choice: SettingsAction) {
        button.bezelStyle = .rounded; button.target = self; button.action = #selector(action(_:))
        button.identifier = NSUserInterfaceItemIdentifier(UUID().uuidString)
        actions[button.identifier!] = choice; actionButtons.append(button)
    }
    private var actions: [NSUserInterfaceItemIdentifier: SettingsAction] = [:]
    private func button(_ title: String, _ action: SettingsAction) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil); configure(button, action); return button
    }
    private func button(_ title: String, selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector); button.bezelStyle = .rounded
        actionButtons.append(button); return button
    }
    @objc private func action(_ sender: NSButton) {
        guard let id = sender.identifier, let action = actions[id] else { return }
        Task {
            guard !model.isPerforming else { return }
            await model.run(action)
            // Authorization UI can leave an accessory app behind other windows.
            // Return only for queue actions and never reopen a user-closed/minimized window.
            if case let .command(request, _) = action,
               ["install-queue", "uninstall-queue"].contains(request.command),
               isPresented, window?.isMiniaturized == false {
                NSApp.unhide(nil)
                present()
            }
        }
    }
    @objc private func toggleLogin() { Task { await model.toggleLogin() } }
    @objc private func testPrint() {
        let value = media.indexOfSelectedItem == 0 ? "mm100x150" : "inch4x6"
        Task { await model.run(.command(.init(command: "test-print", value: value), "Print Test Label")) }
    }
    @objc private func changeWriteMode() {
        guard writeMode.indexOfSelectedItem > 0 else { refresh(); return }
        let value = writeMode.indexOfSelectedItem == 1 ? "without-response" : "with-response"
        Task { await model.run(.command(.init(command: "write-mode", value: value), "Change BLE Write Mode")) }
    }
    @objc private func toggleDryRun() {
        let value = model.snapshot().dryRun ? "off" : "on"
        Task { await model.run(.command(.init(command: "dry-run", value: value, confirm: true), "Change Dry Run")) }
    }
}
