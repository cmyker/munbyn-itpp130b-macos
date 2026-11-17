import AppKit

@MainActor final class RecoveryWindowController: NSWindowController {
    let model: RecoveryModel
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let trigger = NSTextField(wrappingLabelWithString: "")
    private let acknowledgement = NSButton(checkboxWithTitle: "I inspected the paper and turned the printer off and on", target: nil, action: nil)
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let printCenter = NSButton(title: "Open Print Center", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let footer = NSTextField(wrappingLabelWithString: "")
    init(_ model: RecoveryModel) {
        self.model = model; super.init(window: nil)
        model.onChange = { [weak self] in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Recover Printing"; window.isReleasedWhenClosed = false; self.window = window
        guard let content = window.contentView else { return }
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        detail.font = .systemFont(ofSize: 13)
        trigger.font = .systemFont(ofSize: 12); trigger.textColor = .systemRed
        acknowledgement.target = self; acknowledgement.action = #selector(toggleAcknowledgement)
        primary.target = self; primary.action = #selector(advance); primary.bezelStyle = .rounded
        printCenter.target = self; printCenter.action = #selector(openPrintCenter); printCenter.bezelStyle = .rounded
        let close = NSButton(title: "Close", target: self, action: #selector(closeRecovery)); close.bezelStyle = .rounded; close.keyEquivalent = "\u{1b}"
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let buttons = NSStackView(views: [spinner, printCenter, close, primary]); buttons.orientation = .horizontal; buttons.spacing = 12
        footer.font = .systemFont(ofSize: 11); footer.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, trigger, detail, acknowledgement, footer, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor), footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            trigger.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center(); refresh()
    }
    func present() {
        if window == nil { loadWindow() }
        showWindow(nil); refresh(); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    private func refresh() {
        guard window != nil else { return }
        trigger.isHidden = model.triggerError.isEmpty || model.stage == .complete
        trigger.stringValue = "The job action could not finish: \(model.triggerError)"
        printCenter.isHidden = model.stage != .failed
        acknowledgement.isHidden = model.stage != .printerRestart
        acknowledgement.state = model.printerRestarted ? .on : .off
        acknowledgement.isEnabled = !model.isPerforming
        primary.isEnabled = !model.isPerforming && (model.stage != .printerRestart || model.printerRestarted)
        if model.isPerforming { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        footer.stringValue = "No changes are made until you start recovery."
        switch model.stage {
        case .warning:
            heading.stringValue = "Start fresh with this printer"
            detail.stringValue = "This stops printing, clears bridge jobs and your jobs in MUNBYN ITPP130B (Bluetooth), and resets the bridge’s connection. Pending labels will be lost; an earlier label may already have printed.\n\nYour USB printer, default printer, selection, settings and diagnostic captures are preserved. No old job will be reprinted automatically."
            primary.title = "Stop and Reset Printing"
        case .stopping:
            footer.stringValue = "This step can finish in the background. A required printer restart still needs your confirmation."
            heading.stringValue = "Stopping printing…"
            detail.stringValue = "Releasing the printer and cancelling your Bluetooth-queue jobs. Please wait."
            primary.title = "Stopping…"
        case .printerRestart:
            footer.stringValue = "Closing now keeps printing paused. Choose Recover Printing… to continue."
            heading.stringValue = "Restart the printer"
            detail.stringValue = "Printing has stopped. Inspect the paper for partial or duplicate labels. Turn the printer off, wait a moment, then turn it back on.\n\nConfirm below when you have done this. The interrupted jobs will then be cleared."
            primary.title = "Clear Jobs and Finish"
        case .finishing:
            footer.stringValue = "This confirmed reset can finish in the background."
            heading.stringValue = "Resetting the connection…"
            detail.stringValue = "Clearing held jobs and preparing a fresh connection for your next print."
            primary.title = "Finishing…"
        case .complete:
            footer.stringValue = "Your USB printer and preferences have been preserved."
            heading.stringValue = "Recovery finished"
            detail.stringValue = "The old jobs are cleared. The bridge will make a fresh Bluetooth connection for the next print. You can now submit your document once."
            primary.title = "Done"
        case .failed:
            footer.stringValue = "Choose Recover Printing… again to retry unfinished recovery."
            heading.stringValue = "Recovery needs another step"
            detail.stringValue = "\(model.errorText)\n\nSome reset steps may already have completed. Retry recovery to finish; no old label is replayed automatically."
            primary.title = "Retry Recovery"
        }
    }
    @objc private func toggleAcknowledgement() { model.setPrinterRestarted(acknowledgement.state == .on) }
    @objc private func advance() {
        if model.stage == .complete { close(); return }
        Task { await model.advance() }
    }
    @objc private func closeRecovery() { close() }
    @objc private func openPrintCenter() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.printcenter") {
            NSWorkspace.shared.open(url)
        }
    }
}
