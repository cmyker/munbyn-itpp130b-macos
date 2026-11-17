import Foundation
import CBridge

/// Runs only in the owner's bounded, unprivileged native-recovery child.
public enum NativeQueueRecovery {
    public static func cancelPending() throws {
        guard mb_recovery_watchdog(STDIN_FILENO, 20) == 0 else { throw BridgeError.invalid("Recovery worker has no live owner; no queue changes made") }
        let user = NSUserName()
        guard !user.isEmpty, user.utf8.count <= 256, !user.contains("\0") else { throw BridgeError.invalid("Cannot determine the current printing user") }
        let queue = try snapshot(); try QueuePlan.validateOwnership(queue)
        guard queue != nil else { return }
        let result = mb_cancel_pending_jobs(QueuePlan.id, user)
        if result == -3 {
            throw BridgeError.invalid("macOS denied cancellation of pending Bluetooth printer jobs. Open Print Center, cancel jobs for MUNBYN ITPP130B (Bluetooth), then choose Retry Recovery")
        }
        guard result == 0 else { throw BridgeError.invalid("Bluetooth printer jobs could not be cleared. Open Print Center, cancel jobs for MUNBYN ITPP130B (Bluetooth), then choose Retry Recovery") }
        try QueuePlan.validateOwnership(snapshot())
    }
    private static func snapshot() throws -> QueueSnapshot? {
        var location = [CChar](repeating: 0, count: 1024), uri = [CChar](repeating: 0, count: 2048)
        let result = mb_queue_snapshot(QueuePlan.id, &location, location.count, &uri, uri.count)
        guard result >= 0 else { throw BridgeError.invalid("Local CUPS inspection failed; recovery remains paused") }
        return result == 0 ? nil : QueueSnapshot(location: String(cString: location), uri: String(cString: uri))
    }
}
