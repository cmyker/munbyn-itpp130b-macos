import AppKit
import Foundation
import Testing
@testable import BridgeCore
@testable import MunbynBridge

@Suite(.serialized) @MainActor struct RecoveryUITests {
    private let stopped = Data(#"{"paused":true,"needsPrinterRestart":false}"#.utf8)
    private let needsRestart = Data(#"{"paused":true,"needsPrinterRestart":true}"#.utf8)
    private let finished = Data(#"{"paused":false,"needsPrinterRestart":false}"#.utf8)
    @Test func openingRecoveryDoesNotStopOrDeleteAnything() {
        var calls = 0
        let model = RecoveryModel(command: { _ in calls += 1; return self.finished })
        #expect(model.stage == .warning)
        #expect(calls == 0)
        #expect(!model.isPerforming)
    }
    @Test func failedJobDeletionAndClearPresentRecoveryWithoutStartingIt() async {
        for action in ["delete", "clear-jobs"] {
            var resetCalls = 0, genericErrors = 0
            let model = RecoveryModel(command: { _ in resetCalls += 1; return self.finished })
            await MenuActionExecutor.run(.init(command: action, confirm: true), command: { _ in
                throw BridgeError.invalid("The printer buffer must be recovered first")
            }, recover: { reason in model.explainFailure(reason) }, report: { _ in genericErrors += 1 })
            #expect(model.triggerError.contains("printer buffer"))
            #expect(model.stage == .warning && resetCalls == 0 && genericErrors == 0)
        }
    }
    @Test func otherActionErrorsStillUseTheirNormalMessage() async {
        var recoveryCalls = 0, errors = 0
        await MenuActionExecutor.run(.init(command: "test-print"), command: { _ in
            throw BridgeError.invalid("Select a printer")
        }, recover: { _ in recoveryCalls += 1 }, report: { _ in errors += 1 })
        #expect(recoveryCalls == 0 && errors == 1)
    }
    @Test func safeIdleResetCompletesOnlyAfterExplicitStart() async {
        var commands: [ControlRequest] = []
        let model = RecoveryModel(command: { request in
            commands.append(request)
            return request.command == "recovery-begin" ? self.stopped : self.finished
        })
        await model.advance()
        #expect(model.stage == .complete)
        #expect(commands.map(\.command) == ["recovery-begin", "recovery-finish"])
        #expect(commands.allSatisfy { $0.confirm })
        #expect(commands.last?.value == nil)
    }
    @Test func ambiguousOutcomeCannotClearUntilUserAcknowledgesPrinterRestart() async {
        var commands: [ControlRequest] = []
        let model = RecoveryModel(command: { request in
            commands.append(request)
            return request.command == "recovery-begin" ? self.needsRestart : self.finished
        })
        await model.advance()
        #expect(model.stage == .printerRestart)
        await model.advance()
        #expect(commands.count == 1)
        model.setPrinterRestarted(true)
        await model.advance()
        #expect(model.stage == .complete)
        #expect(commands.last?.value == "printer-restarted")
    }
    @Test func failureNeedsAnExplicitRetryAndDoesNotReplayLabels() async {
        var commands: [String] = []
        var fail = true
        let model = RecoveryModel(command: { request in
            commands.append(request.command)
            if fail { throw BridgeError.invalid("Native queue unavailable") }
            return request.command == "recovery-begin" ? self.stopped : self.finished
        })
        await model.advance()
        #expect(model.stage == .failed)
        #expect(model.errorText.contains("Native queue unavailable"))
        #expect(commands == ["recovery-begin"])
        fail = false
        await model.advance()
        #expect(model.stage == .complete)
        #expect(commands == ["recovery-begin", "recovery-begin", "recovery-finish"])
    }
    @Test func repeatedClicksDoNotStartOverlappingResets() async throws {
        var pending: CheckedContinuation<Data, Never>?
        var calls = 0
        let model = RecoveryModel(command: { request in
            calls += 1
            if request.command == "recovery-begin" { return await withCheckedContinuation { pending = $0 } }
            return self.finished
        })
        let first = Task { await model.advance() }
        for _ in 0..<10_000 where pending == nil { await Task.yield() }
        if pending == nil { first.cancel(); Issue.record("Reset did not start"); return }
        await model.advance()
        #expect(calls == 1)
        pending?.resume(returning: stopped)
        await first.value
        #expect(calls == 2 && model.stage == .complete)
    }
    @Test func recoveryAndPausedSettingsWindowsLoadWithoutOwnerActions() throws {
        let app = NSApplication.shared, old = app.activationPolicy()
        app.setActivationPolicy(.prohibited); defer { app.setActivationPolicy(old) }
        var calls = 0
        let recovery = RecoveryWindowController(RecoveryModel(command: { _ in calls += 1; return self.finished }))
        defer { recovery.close() }
        recovery.present()
        #expect(recovery.window?.isVisible == true)
        #expect(calls == 0)
        let settings = SettingsWindowController(SettingsModel(snapshot: {
            SettingsSnapshot(login: .enabled, recoveryPaused: true)
        }, perform: { _ in calls += 1 }))
        defer { settings.close() }
        settings.present()
        let content = try #require(settings.window?.contentView)
        let tabs = try #require(content.subviews.compactMap { $0 as? NSTabView }.first)
        tabs.selectTabViewItem(withIdentifier: "Printer")
        #expect(button("Recover Printing…", in: content)?.isEnabled == true)
        #expect(button("Print Test Label…", in: content)?.isEnabled == false)
        #expect(calls == 0)
    }
    private func button(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for child in view.subviews { if let result = button(title, in: child) { return result } }
        return nil
    }
}
