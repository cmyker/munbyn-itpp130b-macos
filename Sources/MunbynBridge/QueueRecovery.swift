import Foundation
import BridgeCore

enum QueueRecovery {
    static func cancelPending() throws {
        let user = NSUserName()
        let args = try QueuePlan.cancelPending(existing: QueueInstaller.snapshot(), user: user)
        guard !args.isEmpty else { return }
        let result = try BoundedCommand.run(executable: "/usr/bin/cancel", arguments: args)
        guard result.0 == 0 else { throw BridgeError.invalid("Could not cancel this user's Bluetooth printer jobs: \(result.1.prefix(512))") }
        // Keep inspection pinned and recheck ownership before any subsequent action.
        guard let queue = try QueueInstaller.snapshot() else { return }
        _ = try QueuePlan.cancelPending(existing: queue, user: user)
        let pending = try BoundedCommand.run(executable: "/usr/bin/lpstat", arguments: QueuePlan.pendingQuery(user: user))
        guard pending.0 == 0, pending.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError.invalid("Jobs are still stopping in Print Center. Try Recover Printing again")
        }
    }
}
