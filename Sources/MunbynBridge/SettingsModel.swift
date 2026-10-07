import AppKit
import ServiceManagement
import BridgeCore

enum LoginState: Equatable {
    case enabled, requiresApproval, notRegistered, notFound, unknown
    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        case .notFound: self = .notFound
        @unknown default: self = .unknown
        }
    }
    var checkboxState: NSControl.StateValue {
        switch self {
        case .enabled: return .on
        case .requiresApproval: return .mixed
        default: return .off
        }
    }
    var statusText: String {
        switch self {
        case .enabled: return "Enabled in macOS."
        case .requiresApproval: return "Approval required in System Settings → Login Items."
        case .notRegistered: return "Off. Open the app manually after logging in."
        case .notFound: return "Not registered. Keep the installed app in Applications before enabling."
        case .unknown: return "macOS login registration status is unavailable."
        }
    }
    var toggleValue: String { self == .enabled || self == .requiresApproval ? "off" : "on" }
}

struct SettingsSnapshot {
    var login: LoginState
    var printerSelected = false
    var status = "Ready"
    var bluetooth = "Not initialized"
    var dryRun = false
    var writePreference: BLEWritePreference? = nil
}

enum SettingsAction {
    case command(ControlRequest, String)
    case selectPrinter, diagnostics, openData, openLoginSettings, openSource
}

@MainActor final class SettingsModel {
    let snapshot: () -> SettingsSnapshot
    private let perform: (SettingsAction) async -> Void
    private(set) var isPerforming = false
    var onChange: (() -> Void)?
    init(snapshot: @escaping () -> SettingsSnapshot, perform: @escaping (SettingsAction) async -> Void) {
        self.snapshot = snapshot; self.perform = perform
    }
    func run(_ action: SettingsAction) async {
        guard !isPerforming else { return }
        isPerforming = true; onChange?()
        defer { isPerforming = false; onChange?() }
        await perform(action)
    }
    func toggleLogin() async {
        let login = snapshot().login
        guard login != .unknown else { return }
        await run(.command(.init(command: "login", value: login.toggleValue), "Start at Login"))
    }
}
