import Foundation
import Testing
import Darwin
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
    @Test func timedOutWorkerIsGoneBeforeTheCallerCanRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("child.pid")
        do {
            _ = try BoundedCommand.run(executable: "/bin/sh", arguments: ["-c", "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 5", "fixture", file.path], timeout: 0.2)
            Issue.record("Expected timeout")
        } catch {}
        let pid = try #require(Int32(String(contentsOf: file, encoding: .utf8)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
    @Test func recoveryWorkerDiesWithItsParentOrItsOwnDeadline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent("lifetime-fixture")
        let compile = try BoundedCommand.run(executable: "/usr/bin/clang", arguments: [
            "-I", repo.appendingPathComponent("Sources/CBridge/include").path,
            repo.appendingPathComponent("scripts/test-fixtures/recovery-lifetime.c").path,
            repo.appendingPathComponent("Sources/CBridge/CBridge.c").path,
            "-lcups", "-framework", "Security", "-o", executable.path], timeout: 15)
        #expect(compile.0 == 0)
        for mode in ["parent-exit", "deadline"] {
            let pidFile = root.appendingPathComponent(mode + ".pid")
            let result = try BoundedCommand.run(executable: executable.path, arguments: [mode, pidFile.path], timeout: 2)
            #expect(result.0 == 0)
            let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
            defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while kill(pid, 0) == 0 && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
            #expect(kill(pid, 0) == -1 && errno == ESRCH)
        }
    }
}
