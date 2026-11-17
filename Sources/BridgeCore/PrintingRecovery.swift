import Foundation

/// Durable pause and deletion policy. External operations belong to the single app owner.
@MainActor public final class PrintingRecovery {
    private let spool: Spool
    private let stateURL: URL
    public private(set) var isPaused: Bool
    private var operationInProgress = false

    public init(spool: Spool, stateURL: URL) throws {
        self.spool = spool; self.stateURL = stateURL
        isPaused = FileManager.default.fileExists(atPath: stateURL.path)
            ? try JSONDecoder().decode(Bool.self, from: PrivateFiles.read(stateURL, maxBytes: 128)) : false
    }
    private func persist(_ paused: Bool) throws {
        try PrivateFiles.write(JSONEncoder().encode(paused), to: stateURL)
        isPaused = paused
    }
    public func needsPrinterRestart() throws -> Bool {
        try spool.jobs().contains { $0.state == .outcomeUnknown && !$0.recoveryConfirmed }
    }
    public func begin(stop: () async throws -> Void, cancelNative: () async throws -> Void) async throws {
        guard !operationInProgress else { throw BridgeError.invalid("Recovery is already running") }
        operationInProgress = true; defer { operationInProgress = false }
        // A crash or closed recovery window must not turn held jobs into new prints.
        try persist(true)
        try await stop()
        try await cancelNative()
    }
    public func finish(printerRestarted: Bool, prepare: () async throws -> Void, resume: () async throws -> Void) async throws {
        guard !operationInProgress else { throw BridgeError.invalid("Recovery is still stopping work") }
        operationInProgress = true; defer { operationInProgress = false }
        guard isPaused else { throw BridgeError.invalid("Start Recover Printing before completing it") }
        let jobs = try spool.jobs()
        guard !jobs.contains(where: { [.connecting, .sending].contains($0.state) }) else {
            throw BridgeError.invalid("Printing is still stopping. Retry Recover Printing; jobs have been retained")
        }
        let needsRestart = try needsPrinterRestart()
        guard printerRestarted || !needsRestart else {
            throw BridgeError.invalid("Inspect the paper and turn the printer off and on before finishing recovery")
        }
        try await prepare()
        let needsRestartAfterPreparation = try needsPrinterRestart()
        guard printerRestarted || !needsRestartAfterPreparation else {
            throw BridgeError.invalid("A transmission became uncertain while stopping; inspect the paper and restart the printer")
        }
        for job in try spool.jobs() where job.state == .outcomeUnknown && !job.recoveryConfirmed {
            try spool.confirmRecovery(job.id)
        }
        try spool.clearAll(confirmed: true)
        try await resume()
        // Clear the pause last; every earlier error remains safely resumable.
        try persist(false)
    }
}
