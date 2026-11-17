import Foundation
import BridgeCore

enum QueueRecovery {
    static func cancelPending() throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/munbyn-bridge")
        let result = try BoundedCommand.run(executable: helper.path, arguments: ["--internal-recovery-native"], timeout: 20, ownerLifetime: true)
        guard result.0 == 0 else { throw BridgeError.invalid(String(result.1.prefix(1024))) }
    }
}
