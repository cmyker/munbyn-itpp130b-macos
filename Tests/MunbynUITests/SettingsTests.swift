import Testing
import AppKit
@testable import BridgeCore
@testable import MunbynBridge

@MainActor struct SettingsTests {
    @Test func settingsPresentationCreatesAWindowWithoutOwnerCommands() throws {
        let app = NSApplication.shared
        let previous = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(previous) }
        var actions = 0
        let model = SettingsModel(snapshot: { SettingsSnapshot(login: .notRegistered) }, perform: { _ in actions += 1 })
        let controller = SettingsWindowController(model)
        defer { controller.close() }
        controller.present()
        #expect(controller.isWindowLoaded)
        #expect(controller.window?.title == "MUNBYN Bridge Settings")
        #expect(controller.window?.isVisible == true)
        controller.refresh()
        #expect(actions == 0)
    }
    @Test func oldUnknownJobRemainsVisibleAfterManyCompletedJobs() {
        let unknown = Job(id: UUID(), state: .outcomeUnknown, created: Date(timeIntervalSince1970: 0), pages: 1, bytes: 1, recoveryConfirmed: false)
        let completed = (1...30).map { index in
            Job(id: UUID(), state: .transmitted, created: Date(timeIntervalSince1970: Double(index)), pages: 1, bytes: 0, recoveryConfirmed: false)
        }
        #expect(MenuController.visibleJobs([unknown] + completed).contains { $0.id == unknown.id })
    }
    @Test func readingSettingsDoesNotRegisterLoginOrRunPrinterCommands() {
        var actions = 0
        let model = SettingsModel(snapshot: { SettingsSnapshot(login: .notRegistered) }, perform: { _ in actions += 1 })
        _ = model.snapshot()
        #expect(actions == 0)
        #expect(!model.isPerforming)
    }

    @Test func pendingApprovalIsNotReportedAsEnabledAndCanBeDisabled() async {
        var value: String?
        let model = SettingsModel(snapshot: { SettingsSnapshot(login: .requiresApproval) }, perform: { action in
            if case let .command(request, _) = action { value = request.value }
        })
        #expect(model.snapshot().login.checkboxState == .mixed)
        await model.toggleLogin()
        #expect(value == "off")
    }

    @Test func unsuccessfulRegistrationKeepsActualSystemState() async {
        var value: String?
        let model = SettingsModel(snapshot: { SettingsSnapshot(login: .notFound) }, perform: { action in
            // The owner handles cancellation/errors; macOS state stays unavailable.
            if case let .command(request, _) = action { value = request.value }
        })
        await model.toggleLogin()
        #expect(value == "on")
        #expect(model.snapshot().login.checkboxState == .off)
        #expect(!model.isPerforming)
    }

    @Test func registrationResultComesFromSystemInsteadOfOptimisticCheckbox() async {
        var state = LoginState.notRegistered
        let model = SettingsModel(snapshot: { SettingsSnapshot(login: state) }, perform: { _ in state = .requiresApproval })
        await model.toggleLogin()
        #expect(model.snapshot().login.checkboxState == .mixed)
        #expect(!model.isPerforming)
    }

    @Test func overlappingSettingsActionsAreNotSubmittedTwice() async throws {
        var submitted = 0
        var continuation: CheckedContinuation<Void, Never>?
        let model = SettingsModel(snapshot: { SettingsSnapshot(login: .notRegistered) }, perform: { _ in
            submitted += 1
            guard submitted == 1 else { return }
            await withCheckedContinuation { continuation = $0 }
        })
        let first = Task { await model.toggleLogin() }
        for _ in 0..<10_000 where continuation == nil { await Task.yield() }
        try #require(continuation != nil)
        #expect(model.isPerforming)
        await model.toggleLogin()
        #expect(submitted == 1)
        continuation?.resume()
        await first.value
        #expect(!model.isPerforming)
    }
}
