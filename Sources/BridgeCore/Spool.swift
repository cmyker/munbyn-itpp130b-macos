import Foundation
public enum JobState: String,Codable,CaseIterable { case queued,connecting,sending,transmitted,captured,failedBeforeSend,outcomeUnknown,cancelled }
public struct Job: Codable,Identifiable {
    public var id: UUID; public var state: JobState; public var created: Date
    public var pages: Int; public var bytes: Int; public var error: String?; public var recoveryConfirmed: Bool
    public var captureOnly: Bool? = nil
    public var transmissionMetrics: TransmissionMetrics? = nil
}
public final class Spool {
    public let root: URL
    private let lock = NSRecursiveLock()
    public init(root: URL) throws { self.root = root; try PrivateFiles.directory(root) }
    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
    private func record(_ id: UUID) -> URL { folder(id).appendingPathComponent("job.json") }
    private func save(_ job: Job) throws { try PrivateFiles.write(JSONEncoder().encode(job),to: record(job.id)) }
    public func jobs() throws -> [Job] {
        lock.lock(); defer { lock.unlock() }
        let folders = try FileManager.default.contentsOfDirectory(at: root,includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }
        guard folders.count <= 128 else { throw BridgeError.invalid("Spool record limit exceeded") }
        return try folders.map { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { throw BridgeError.invalid("Unexpected file in spool") }
            let job = try JSONDecoder().decode(Job.self,from: PrivateFiles.read(record(id),maxBytes: 8192))
            guard job.id == id else { throw BridgeError.invalid("Spool identity mismatch") }
            return job
        }.sorted { $0.created < $1.created }
    }
    public func accept(pages: [RasterPage],captureOnly: Bool = false) throws -> Job {
        lock.lock(); defer { lock.unlock() }
        guard (1...64).contains(pages.count) else { throw BridgeError.invalid("Invalid label count") }
        for page in pages { try page.validate() }
        try cleanup()
        let all = try jobs(); let total = pages.reduce(0) { $0 + $1.black.count }
        guard all.count < 128, all.filter({ ![.transmitted,.captured,.cancelled].contains($0.state) }).count < 32,
              all.reduce(0,{ $0 + $1.bytes }) + total <= 128 * 1024 * 1024 else { throw BridgeError.invalid("Private spool capacity reached; review pending jobs") }
        let job = Job(id: UUID(),state: .queued,created: Date(),pages: pages.count,bytes: total,recoveryConfirmed: false,captureOnly:captureOnly)
        let directory = folder(job.id); try PrivateFiles.directory(directory)
        // Payload is durable before the queued record. Incomplete folders after a crash are surfaced, never silently discarded.
        try PrivateFiles.write(JSONEncoder().encode(pages),to: directory.appendingPathComponent("pages.json"))
        try save(job); try PrivateFiles.syncDirectory(root)
        return job
    }
    public func pages(for id: UUID) throws -> [RasterPage] {
        lock.lock(); defer { lock.unlock() }
        let pages = try JSONDecoder().decode([RasterPage].self,from: PrivateFiles.read(folder(id).appendingPathComponent("pages.json")))
        guard (1...64).contains(pages.count) else { throw BridgeError.invalid("Stored label count invalid") }
        for page in pages { try page.validate() }
        return pages
    }
    public func transition(_ id: UUID,to state: JobState,error: String? = nil,metrics: TransmissionMetrics? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard var job = try jobs().first(where: { $0.id == id }) else { throw BridgeError.invalid("Job not found") }
        let allowed: [JobState:[JobState]] = [.queued:[.connecting,.captured,.failedBeforeSend,.cancelled],.connecting:[.sending,.failedBeforeSend,.cancelled],.sending:[.transmitted,.outcomeUnknown],.failedBeforeSend:[.queued,.cancelled]]
        guard allowed[job.state]?.contains(state) == true else { throw BridgeError.invalid("Invalid job state transition") }
        job.state = state; job.error = error
        if state == .queued { job.transmissionMetrics = nil }
        if let metrics { job.transmissionMetrics = metrics }
        try save(job)
        if [.transmitted,.captured,.cancelled].contains(state) {
            try FileManager.default.removeItem(at: folder(id).appendingPathComponent("pages.json"))
            job.bytes = 0; try save(job)
        }
    }
    public func recover() throws {
        lock.lock(); defer { lock.unlock() }
        for job in try jobs() {
            if job.state == .queued && job.captureOnly == nil { try transition(job.id,to:.failedBeforeSend,error:"Legacy job destination unknown; explicit review/retry required") }
            if job.state == .sending { try transition(job.id,to: .outcomeUnknown,error: "App exited after sending intent; do not replay automatically") }
            if job.state == .connecting { try transition(job.id,to: .failedBeforeSend,error: "App exited before any printer write") }
        }
        try cleanup()
    }
    public func confirmRecovery(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard var job = try jobs().first(where: { $0.id == id }), job.state == .outcomeUnknown else { throw BridgeError.invalid("No unknown job to resolve") }
        job.recoveryConfirmed = true; try save(job)
    }
    public func reprint(_ id: UUID,duplicateConfirmed: Bool) throws -> Job {
        lock.lock(); defer { lock.unlock() }
        guard duplicateConfirmed,let job = try jobs().first(where: { $0.id == id }),job.state == .outcomeUnknown,job.recoveryConfirmed else { throw BridgeError.invalid("Confirm duplicate risk and printer-buffer recovery before reprinting") }
        return try accept(pages: pages(for: id),captureOnly:job.captureOnly ?? false)
    }
    public func delete(_ id: UUID,confirmed: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard confirmed,let job = try jobs().first(where: { $0.id == id }),![.connecting,.sending].contains(job.state),
              job.state != .outcomeUnknown || job.recoveryConfirmed else { throw BridgeError.invalid("Deletion requires confirmation; active/uncertain printer state must be resolved first") }
        try FileManager.default.removeItem(at: folder(id)); try PrivateFiles.syncDirectory(root)
    }
    public func clearAll(confirmed: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard confirmed else { throw BridgeError.invalid("Confirm deletion of all bridge job records and pending labels first") }
        let all = try jobs()
        // Check the whole snapshot before deleting any history. Clearing records
        // must never discard the evidence that blocks unsafe printer reuse.
        guard all.allSatisfy({ ![.connecting, .sending].contains($0.state) &&
            ($0.state != .outcomeUnknown || $0.recoveryConfirmed) }) else {
            throw BridgeError.invalid("Cancel active work and confirm uncertain printer-buffer recovery before clearing all jobs")
        }
        for job in all { try delete(job.id, confirmed: true) }
    }
    public func cleanup() throws {
        lock.lock(); defer { lock.unlock() }
        let finished = try jobs().filter { [.transmitted,.captured,.cancelled].contains($0.state) }
        for var job in finished {
            let payload = folder(job.id).appendingPathComponent("pages.json")
            if FileManager.default.fileExists(atPath:payload.path) {
                try FileManager.default.removeItem(at:payload); try PrivateFiles.syncDirectory(folder(job.id))
            }
            if job.bytes != 0 { job.bytes = 0; try save(job) }
        }
        for (index,job) in finished.enumerated() where job.created < Date().addingTimeInterval(-14 * 86400) || index < finished.count - 64 {
            try FileManager.default.removeItem(at: folder(job.id))
        }
    }
}
