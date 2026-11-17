import Foundation
import BridgeCore

@MainActor enum MenuActionExecutor {
    static func run(_ request: ControlRequest, command: (ControlRequest) async throws -> Data,
                    recover: (String) -> Void, report: (String) -> Void) async {
        do { _ = try await command(request) }
        catch {
            let reason = String(describing: error)
            if ["delete", "clear-jobs"].contains(request.command) { recover(reason) }
            else { report(reason) }
        }
    }
}
