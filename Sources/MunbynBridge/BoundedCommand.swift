import Foundation
import Darwin
import BridgeCore

/// Fixed native tools only; callers provide an argv vector, never a shell command.
enum BoundedCommand {
    static func run(executable: String, arguments: [String], timeout: Double = 15, ownerLifetime: Bool = false) throws -> (Int32, String) {
        guard timeout.isFinite, timeout > 0, timeout <= 30 else { throw BridgeError.invalid("Invalid native command timeout") }
        let process = Process(), pipe = Pipe(), output = CommandOutput()
        let exited = DispatchSemaphore(value: 0), readDone = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "CUPS_SERVER": QueuePlan.server]
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let lifetime = Pipe()
        defer { try? lifetime.fileHandleForWriting.close(); try? lifetime.fileHandleForReading.close() }
        if ownerLifetime {
            // Only the app keeps the write end. Its exit closes this channel
            // even if no Swift cleanup/reaper can run after an unexpected exit.
            guard fcntl(lifetime.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw BridgeError.invalid("Cannot protect recovery worker lifetime") }
            process.standardInput = lifetime
        }
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        try? lifetime.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
        let readHandle = pipe.fileHandleForReading
        let fd = readHandle.fileDescriptor
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? readHandle.close(); readDone.signal() }
            var bytes = [UInt8](repeating: 0, count: 8192)
            while !output.stopped {
                var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&event, 1, 100)
                if ready < 0 { if errno == EINTR { continue }; break }
                if ready == 0 { continue }
                let count = read(fd, &bytes, bytes.count)
                if count > 0 { output.append(Data(bytes.prefix(count))) }
                else if count == 0 || errno != EINTR { break }
            }
        }
        let timedOut = exited.wait(timeout: .now() + timeout) != .success
        if timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 0.5) != .success, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            // Reap our own child before allowing any recovery retry. A detached
            // libcups worker must never survive and cancel jobs after timeout.
            process.waitUntilExit()
        }
        var fullyRead = readDone.wait(timeout: .now() + 0.5) == .success
        if !fullyRead {
            output.stop(); fullyRead = readDone.wait(timeout: .now() + 0.5) == .success
        }
        guard !timedOut, !process.isRunning else { throw BridgeError.invalid("Native printer command timed out; recovery remains paused") }
        guard fullyRead else { throw BridgeError.invalid("Native printer response unavailable; recovery remains paused") }
        return (process.terminationStatus, output.text)
    }
}
private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data(), stopRequested = false
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return stopRequested }
    func stop() { lock.lock(); stopRequested = true; lock.unlock() }
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; data.append(bytes.prefix(max(0, 65_536 - data.count))) }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
