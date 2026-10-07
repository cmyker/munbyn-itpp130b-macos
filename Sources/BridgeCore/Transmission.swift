import Foundation
@MainActor public protocol PrinterTransport: AnyObject {
    var maximumChunk: Int { get }
    func prepare() async throws
    func waitUntilReady() async throws
    func write(_ data: Data) async throws
    /// Complete the existing final chunk of a page with a transport response.
    /// This acknowledges a GATT write, never physical printing.
    func writeFinal(_ data: Data) async throws
    func finishTransmission() async throws
    func releaseLink()
}
public struct TransmissionFailure: Error,CustomStringConvertible {
    public var outcomeUnknown: Bool; public var message: String
    public var description: String { message }
}
public struct Pacing {
    public var chunkCap: Int; public var delay: Double; public var timeout: Double; public var timeLimit: Double
    public init(chunkCap: Int = 256,delay: Double = 0.01,timeout: Double = 15,timeLimit: Double = 600) { self.chunkCap = chunkCap; self.delay = delay; self.timeout = timeout; self.timeLimit = timeLimit }
}
/// Local software durations/counts. Successful transport calls are not printer acknowledgements.
public struct TransmissionMetrics: Codable,Equatable {
    public var prepareSeconds = 0.0; public var readinessSeconds = 0.0; public var writeSeconds = 0.0
    public var pacingSeconds = 0.0; public var interPageSeconds = 0.0; public var settlingSeconds = 0.0
    public var sendingIntentSeconds = 0.0; public var elapsedSeconds = 0.0
    public var writeCalls = 0; public var submittedBytes = 0; public var chunkBytes = 0
    public init() {}
}
@MainActor public func bounded<T>(_ seconds: Double,operation: @escaping @MainActor () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw BridgeError.invalid("Operation timed out") }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
public enum Transmission {
    @MainActor public static func send(data: Data,transport: PrinterTransport,pacing: Pacing = .init(),report: ((TransmissionMetrics) -> Void)? = nil,willWrite: () throws -> Void) async throws {
        try await send(pages: [data],transport: transport,pacing: pacing,report:report,willWrite: willWrite)
    }
    @MainActor public static func send(pages: [Data],transport: PrinterTransport,pacing: Pacing = .init(),report: ((TransmissionMetrics) -> Void)? = nil,willWrite: () throws -> Void) async throws {
        var intent = false
        var metrics = TransmissionMetrics()
        let clock = ContinuousClock(); let started = clock.now
        func seconds(since instant: ContinuousClock.Instant) -> Double {
            let duration = instant.duration(to:clock.now).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
        func measure(_ phase: WritableKeyPath<TransmissionMetrics,Double>,_ operation: () async throws -> Void) async throws {
            let began = clock.now
            defer { metrics[keyPath:phase] += seconds(since:began) }
            try await operation()
        }
        defer {
            transport.releaseLink()
            metrics.elapsedSeconds = seconds(since:started)
            report?(metrics)
        }
        do {
            guard (1...512).contains(pacing.chunkCap),pacing.delay.isFinite,(0...0.2).contains(pacing.delay),pacing.timeout.isFinite,(0.001...60).contains(pacing.timeout),pacing.timeLimit.isFinite,(0.001...600).contains(pacing.timeLimit),!pages.isEmpty else { throw BridgeError.invalid("Invalid pacing configuration") }
            let deadline = started.advanced(by:.seconds(pacing.timeLimit))
            func remaining() throws -> Double {
                try Task.checkCancellation()
                let duration = clock.now.duration(to:deadline).components
                let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                guard seconds > 0 else { throw BridgeError.invalid("Transmission time limit exceeded") }
                return seconds
            }
            func operationTime() throws -> Double { min(pacing.timeout,try remaining()) }
            func pause(_ seconds: Double) async throws {
                try await Task.sleep(for:.seconds(min(seconds,try remaining())))
                _ = try remaining()
            }
            try await measure(\.prepareSeconds) { try await bounded(try operationTime()) { try await transport.prepare() } }
            _ = try remaining()
            let chunk = min(pacing.chunkCap,transport.maximumChunk)
            guard chunk > 0 else { throw BridgeError.invalid("No writable BLE payload capacity") }
            metrics.chunkBytes = chunk
            for (index,data) in pages.enumerated() {
                guard !data.isEmpty,data.count <= 256 * 1024 else { throw BridgeError.invalid("Invalid encoded label length") }
                for offset in stride(from: 0,to: data.count,by: chunk) {
                    try await measure(\.readinessSeconds) { try await bounded(try operationTime()) { try await transport.waitUntilReady() } }
                    _ = try remaining()
                    if !intent {
                        let began = clock.now
                        defer { metrics.sendingIntentSeconds += seconds(since:began) }
                        try willWrite(); intent = true
                    }
                    _ = try remaining()
                    let end = min(data.count,offset + chunk)
                    let part = data.subdata(in: offset..<end)
                    metrics.writeCalls += 1
                    try await measure(\.writeSeconds) {
                        try await bounded(try operationTime()) {
                            if end == data.count { try await transport.writeFinal(part) }
                            else { try await transport.write(part) }
                        }
                    }
                    metrics.submittedBytes += part.count
                    _ = try remaining()
                    if pacing.delay > 0 { try await measure(\.pacingSeconds) { try await pause(pacing.delay) } }
                }
                // Provisional settling interval, no device buffer/print-complete acknowledgement implied.
                if pages.count > 1 && index < pages.count - 1 { try await measure(\.interPageSeconds) { try await pause(1) } }
            }
            try await measure(\.settlingSeconds) { try await bounded(try operationTime()) { try await transport.finishTransmission() } }
            _ = try remaining()
        } catch {
            throw TransmissionFailure(outcomeUnknown: intent,message: String(describing: error))
        }
    }
}
