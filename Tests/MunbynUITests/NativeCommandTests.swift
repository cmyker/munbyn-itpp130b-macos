import Foundation
import Testing
@testable import MunbynBridge

struct NativeCommandTests {
    @Test func capturesArgumentsWithoutShellEvaluation() throws {
        let value = "literal; $(not-a-command)"
        let result = try BoundedCommand.run(executable: "/usr/bin/printf", arguments: ["%s", value], timeout: 2)
        #expect(result.0 == 0)
        #expect(result.1 == value)
    }
    @Test func terminatesAnUnresponsiveChildWithinABoundedTime() {
        let started = ContinuousClock.now
        do {
            _ = try BoundedCommand.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.05)
            Issue.record("Expected command timeout")
        } catch { #expect(String(describing: error).contains("timed out")) }
        #expect(started.duration(to: .now) < .seconds(3))
    }
    @Test func boundsCapturedOutput() throws {
        let result = try BoundedCommand.run(executable: "/usr/bin/printf", arguments: ["%s", String(repeating: "x", count: 100_000)], timeout: 2)
        #expect(result.0 == 0)
        #expect(result.1.utf8.count == 65_536)
    }
}
