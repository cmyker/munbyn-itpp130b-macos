import Foundation
import Testing
@testable import BridgeCore
func temporarySpool() throws -> Spool {
    try Spool(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
}
let testPage = RasterPage(width: 8,height: 1,black: Data([0x80]))
struct SpoolTests {
    @Test func durableAcceptanceAndPrivatePermissions() throws {
        let spool = try temporarySpool(); defer { try? FileManager.default.removeItem(at: spool.root) }
        let job = try spool.accept(pages: [testPage])
        let reopened = try Spool(root: spool.root)
        #expect(try reopened.jobs().map(\.id) == [job.id])
        #expect(try reopened.pages(for: job.id) == [testPage])
        let attrs = try FileManager.default.attributesOfItem(atPath: spool.root.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
    @Test func restartNeverReplaysSendingOrLosesQueuedWork() throws {
        let s = try temporarySpool(); defer { try? FileManager.default.removeItem(at: s.root) }
        let queued = try s.accept(pages: [testPage]); let connecting = try s.accept(pages: [testPage]); let sending = try s.accept(pages: [testPage])
        try s.transition(connecting.id,to: .connecting)
        try s.transition(sending.id,to: .connecting); try s.transition(sending.id,to: .sending)
        try s.recover()
        let states = Dictionary(uniqueKeysWithValues: try s.jobs().map { ($0.id,$0.state) })
        #expect(states[queued.id] == .queued)
        #expect(states[connecting.id] == .failedBeforeSend)
        #expect(states[sending.id] == .outcomeUnknown)
        expectThrows(try s.reprint(sending.id,duplicateConfirmed: false))
        expectThrows(try s.reprint(sending.id,duplicateConfirmed: true))
        try s.confirmRecovery(sending.id)
        let reprint = try s.reprint(sending.id,duplicateConfirmed: true)
        #expect(reprint.id != sending.id)
    }
    @Test func invalidTransitionsAndDeletionNeedConfirmation() throws {
        let s = try temporarySpool(); defer { try? FileManager.default.removeItem(at: s.root) }
        let job = try s.accept(pages: [testPage])
        expectThrows(try s.transition(job.id,to: .transmitted))
        expectThrows(try s.delete(job.id,confirmed: false))
        try s.transition(job.id,to: .cancelled)
        try s.delete(job.id,confirmed: true)
        #expect(try s.jobs().isEmpty)
        expectThrows(try s.accept(pages: []))
    }
    @Test func intentionalIdenticalLabelsAreSeparateJobs() throws {
        let s = try temporarySpool(); defer { try? FileManager.default.removeItem(at: s.root) }
        let a = try s.accept(pages: [testPage]); let b = try s.accept(pages: [testPage])
        #expect(a.id != b.id); #expect(try s.jobs().count == 2)
    }
}
@MainActor final class TestTransport: PrinterTransport {
    var maximumChunk = 3; var output = Data(); var writes = 0; var failAt: Int?; var notReady = false; var stall = false
    var chunkSizes: [Int] = []
    var failFinish = false; var finishedBeforeRelease = false
    var released = false
    var prepareDelay: UInt64 = 0; var finishDelay: UInt64 = 0; var writeDelay: UInt64 = 0
    var finalWrites: [Data] = []; var failFinal = false
    var finalDelay: UInt64 = 0; var awaitingFinalAck = false
    func prepare() async throws { if prepareDelay > 0 { try await Task.sleep(nanoseconds:prepareDelay) } }
    func waitUntilReady() async throws {
        if stall { try await Task.sleep(nanoseconds: 1_000_000_000) }
        if notReady { throw BridgeError.invalid("Not ready") }
    }
    func write(_ data: Data) async throws {
        writes += 1
        if writes == failAt { throw BridgeError.invalid("Disconnected") }
        #expect(data.count <= maximumChunk)
        chunkSizes.append(data.count)
        output.append(data)
        if writeDelay > 0 { try await Task.sleep(nanoseconds:writeDelay) }
    }
    func writeFinal(_ data: Data) async throws {
        finalWrites.append(data)
        try await write(data)
        awaitingFinalAck = true
        defer { awaitingFinalAck = false }
        if finalDelay > 0 { try await Task.sleep(nanoseconds:finalDelay) }
        if failFinal { throw BridgeError.invalid("Final write acknowledgement failed") }
    }
    func releaseLink() { released = true }
    func finishTransmission() async throws {
        finishedBeforeRelease = !released
        if finishDelay > 0 { try await Task.sleep(nanoseconds:finishDelay) }
        if failFinish { throw BridgeError.invalid("Disconnected during settling") }
    }
}
struct TransmissionTests {
    @Test @MainActor func eachPageEndsWithItsExistingFinalChunkAcknowledged() async throws {
        let t = TestTransport()
        // Exact multiple and short final chunk, including binary control bytes.
        let pages = [Data([0,10,13,255,4,5]),Data([6,7,8,9])]
        var intent = 0
        try await Transmission.send(pages:pages,transport:t,pacing:.init(delay:0)) { intent += 1 }
        #expect(t.output == Data([0,10,13,255,4,5,6,7,8,9]))
        #expect(t.finalWrites == [Data([255,4,5]),Data([9])])
        #expect(t.writes == 4); #expect(intent == 1); #expect(t.released)
    }
    @Test @MainActor func finalAcknowledgementFailureIsUnknownAndNeverRetried() async {
        let t = TestTransport(); t.failFinal = true
        do {
            try await Transmission.send(data:Data([1,2,3,4]),transport:t,pacing:.init(delay:0)) {}
            Issue.record("Expected final acknowledgement failure")
        } catch let error as TransmissionFailure { #expect(error.outcomeUnknown) }
        catch { Issue.record("Wrong failure") }
        #expect(t.finalWrites == [Data([4])]); #expect(t.writes == 2)
        #expect(t.output == Data([1,2,3,4])); #expect(t.released)
        #expect(!t.finishedBeforeRelease)
    }
    @Test @MainActor func finalAcknowledgementTimeoutKeepsAmbiguousOutcome() async {
        let t = TestTransport(); t.finalDelay = 1_000_000_000
        do {
            try await Transmission.send(data:Data([1,2,3,4]),transport:t,pacing:.init(delay:0,timeout:0.02)) {}
            Issue.record("Expected final acknowledgement timeout")
        } catch let error as TransmissionFailure { #expect(error.outcomeUnknown) }
        catch { Issue.record("Wrong failure") }
        #expect(t.finalWrites == [Data([4])]); #expect(t.released)
        #expect(!t.finishedBeforeRelease)
    }
    @Test @MainActor func connectionStaysOwnedWhileFinalAcknowledgementIsPending() async throws {
        let t = TestTransport(); t.finalDelay = 30_000_000
        var completed = false
        let task = Task {
            defer { completed = true }
            try await Transmission.send(data:Data([1]),transport:t,pacing:.init(delay:0)) {}
        }
        while !completed && !t.awaitingFinalAck { await Task.yield() }
        #expect(t.awaitingFinalAck); #expect(!t.released)
        try await task.value
        #expect(t.finalWrites == [Data([1])]); #expect(t.released)
    }
    @Test @MainActor func cancellationDuringFinalAcknowledgementStaysUnknown() async {
        let t = TestTransport(); t.finalDelay = 1_000_000_000
        var completed = false
        let task = Task {
            defer { completed = true }
            try await Transmission.send(data:Data([1]),transport:t,pacing:.init(delay:0)) {}
        }
        while !completed && !t.awaitingFinalAck { await Task.yield() }
        #expect(t.awaitingFinalAck); #expect(!t.released)
        task.cancel()
        do { try await task.value; Issue.record("Expected cancellation") }
        catch let error as TransmissionFailure { #expect(error.outcomeUnknown) }
        catch { Issue.record("Wrong failure") }
        #expect(t.finalWrites == [Data([1])]); #expect(t.released)
        #expect(!t.finishedBeforeRelease)
    }
    @Test @MainActor func settlingFailureIsUnknownAndLinkRemainsOwnedUntilSettled() async {
        let t = TestTransport(); t.failFinish = true
        do { try await Transmission.send(data:Data([1,2,3]),transport:t,pacing:.init(delay:0)) {}; Issue.record("Expected settling failure") }
        catch let error as TransmissionFailure { #expect(error.outcomeUnknown) }
        catch { Issue.record("Wrong failure") }
        #expect(t.finishedBeforeRelease); #expect(t.released)
        #expect(t.output == Data([1,2,3]))
    }
    @Test @MainActor func defaultPacingBoundsHighCapacityPeripheralAndPreservesTail() async throws {
        let t = TestTransport(); t.maximumChunk = 512
        let source = Data((0..<600).map { UInt8($0 % 251) })
        try await Transmission.send(data:source,transport:t) {}
        // Selected-unit physical tests passed four labels/QRs with a 256-byte cap.
        #expect(t.chunkSizes == [256,256,88])
        #expect(t.output == source); #expect(t.released)
    }
    @Test @MainActor func chunksAndWritesOneIntentBeforeTransmission() async throws {
        let t = TestTransport(); var intent = 0
        try await Transmission.send(data: Data([0,1,2,3,4,5,6]),transport: t,pacing: .init(delay: 0)) { intent += 1; #expect(t.output.isEmpty) }
        #expect(t.output == Data([0,1,2,3,4,5,6])); #expect(t.writes == 3)
        #expect(intent == 1); #expect(t.released)
    }
    @Test @MainActor func firstWriteErrorIsUnknownAndNeverRetried() async {
        let t = TestTransport(); t.failAt = 1
        do { try await Transmission.send(data: Data([0,1,2]),transport: t,pacing: .init(delay: 0)) {} ; Issue.record("Expected failure") }
        catch let error as TransmissionFailure { #expect(error.outcomeUnknown) }
        catch { Issue.record("Wrong error") }
        #expect(t.writes == 1); #expect(t.released)
    }
    @Test @MainActor func backpressureTimeoutAndIntentFailureSendNoBytes() async {
        for type in 0..<3 {
            let t = TestTransport(); t.notReady = type == 0; t.stall = type == 1
            do { try await Transmission.send(data: Data([1]),transport: t,pacing: .init(delay: 0,timeout: 0.01)) {
                if type == 2 { throw BridgeError.invalid("Persistence failed") }
            }; Issue.record("Expected failure") }
            catch let error as TransmissionFailure { #expect(!error.outcomeUnknown) }
            catch { Issue.record("Wrong error") }
            #expect(t.output.isEmpty); #expect(t.released)
        }
    }
}
extension TransmissionTests {
    @Test @MainActor func cancellationAfterFirstChunkStaysUnknown() async {
        let t = TestTransport()
        let task = Task { try await Transmission.send(data:Data([1,2,3,4,5,6]),transport:t,pacing:.init(delay:0.1)) {} }
        while t.output.isEmpty { await Task.yield() }
        task.cancel()
        do { try await task.value; Issue.record("Expected cancellation") }
        catch let error as TransmissionFailure { #expect(error.outcomeUnknown) }
        catch { Issue.record("Wrong failure") }
        #expect(t.output == Data([1,2,3])); #expect(t.released)
    }
}
extension SpoolTests {
    @Test func restartFinishesTerminalPayloadDeletion() throws {
        let s = try temporarySpool(); defer { try? FileManager.default.removeItem(at:s.root) }
        var job = try s.accept(pages:[testPage]); job.state = .cancelled
        let folder = s.root.appendingPathComponent(job.id.uuidString)
        // Crash after durable terminal state, before source-payload deletion.
        try PrivateFiles.write(JSONEncoder().encode(job),to:folder.appendingPathComponent("job.json"))
        let reopened = try Spool(root:s.root); try reopened.recover()
        #expect(!FileManager.default.fileExists(atPath:folder.appendingPathComponent("pages.json").path))
        #expect(try reopened.jobs().first?.bytes == 0)
    }
    @Test func captureIntentSurvivesRestartAndFailedCaptureKeepsPayload() throws {
        let s = try temporarySpool(); defer { try? FileManager.default.removeItem(at:s.root) }
        let job = try s.accept(pages:[testPage],captureOnly:true)
        let reopened = try Spool(root:s.root); try reopened.recover()
        #expect(try reopened.jobs().first?.captureOnly == true)
        try reopened.transition(job.id,to:.failedBeforeSend,error:"Capture quota full")
        #expect(try reopened.pages(for:job.id) == [testPage])
        try reopened.transition(job.id,to:.queued)
        #expect(try reopened.jobs().first?.captureOnly == true)
    }
    @Test func unknownJobCannotBeDeletedToBypassRecovery() throws {
        let s = try temporarySpool(); defer { try? FileManager.default.removeItem(at:s.root) }
        let job = try s.accept(pages:[testPage]); try s.transition(job.id,to:.connecting); try s.transition(job.id,to:.sending); try s.transition(job.id,to:.outcomeUnknown)
        expectThrows(try s.delete(job.id,confirmed:true))
        #expect(try s.pages(for:job.id) == [testPage])
    }
    @Test func rejectsSymlinkSpoolRoot() throws {
        let directory = URL(fileURLWithPath:"/tmp/mb-test-" + UUID().uuidString)
        try PrivateFiles.directory(directory); defer { try? FileManager.default.removeItem(at:directory) }
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:directory)
        expectThrows(try Spool(root:link))
    }
}

extension TransmissionTests {
    @Test @MainActor func wholeDeadlineIncludesPreparationBeforeAnyWrite() async {
        let t = TestTransport(); t.prepareDelay = 800_000_000
        do {
            try await Transmission.send(data:Data([1]),transport:t,
                pacing:.init(delay:0,timeout:2,timeLimit:0.5)) {}
            Issue.record("Expected whole-job timeout")
        } catch let error as TransmissionFailure { #expect(!error.outcomeUnknown) }
        catch { Issue.record("Wrong failure") }
        #expect(t.output.isEmpty); #expect(t.released)
    }
    @Test @MainActor func deadlineDuringFinalPacingCannotReturnSuccess() async {
        let t = TestTransport(); t.writeDelay = 400_000_000
        do {
            try await Transmission.send(data:Data([1]),transport:t,
                pacing:.init(delay:0.2,timeout:2,timeLimit:0.5)) {}
            Issue.record("Expected timeout after last write")
        } catch let error as TransmissionFailure { #expect(error.outcomeUnknown) }
        catch { Issue.record("Wrong failure") }
        #expect(t.output == Data([1])); #expect(t.released)
        #expect(!t.finishedBeforeRelease)
    }
    @Test @MainActor func deadlineDuringFinalSettlingCannotReturnSuccess() async {
        let t = TestTransport(); t.finishDelay = 800_000_000
        do {
            try await Transmission.send(data:Data([1]),transport:t,
                pacing:.init(delay:0,timeout:2,timeLimit:0.5)) {}
            Issue.record("Expected timeout during settling")
        } catch let error as TransmissionFailure { #expect(error.outcomeUnknown) }
        catch { Issue.record("Wrong failure") }
        #expect(t.output == Data([1])); #expect(t.released)
        #expect(t.finishedBeforeRelease)
    }
}
extension TransmissionTests {
    @Test @MainActor func aggregateTimingsDistinguishPacingFromTransportWaits() async throws {
        let t = TestTransport(); t.prepareDelay = 20_000_000; t.writeDelay = 10_000_000
        var reports: [TransmissionMetrics] = []
        try await Transmission.send(data:Data([1,2,3,4]),transport:t,
            pacing:.init(delay:0.01),report:{ reports.append($0) }) {}
        #expect(reports.count == 1)
        let m = try #require(reports.first)
        #expect(m.writeCalls == 2); #expect(m.submittedBytes == 4); #expect(m.chunkBytes == 3)
        #expect(m.prepareSeconds >= 0.02); #expect(m.writeSeconds >= 0.02)
        #expect(m.pacingSeconds >= 0.02)
        #expect(m.elapsedSeconds >= m.prepareSeconds + m.writeSeconds + m.pacingSeconds)
        #expect(t.output == Data([1,2,3,4])); #expect(t.released)
    }
    @Test @MainActor func failedWriteStillReportsTimingWithoutClaimingSubmission() async {
        let t = TestTransport(); t.failAt = 2
        var reports: [TransmissionMetrics] = []
        do {
            try await Transmission.send(data:Data([1,2,3,4]),transport:t,
                pacing:.init(delay:0),report:{ reports.append($0) }) {}
            Issue.record("Expected transmission failure")
        } catch let error as TransmissionFailure { #expect(error.outcomeUnknown) }
        catch { Issue.record("Wrong failure") }
        #expect(reports.count == 1)
        #expect(reports.first?.writeCalls == 2)
        #expect(reports.first?.submittedBytes == 3)
        #expect(t.output == Data([1,2,3])); #expect(t.released)
    }
}
extension SpoolTests {
    @Test func terminalTimingEvidenceSurvivesRestartWithoutPayload() throws {
        let s = try temporarySpool(); defer { try? FileManager.default.removeItem(at:s.root) }
        let job = try s.accept(pages:[testPage])
        try s.transition(job.id,to:.connecting); try s.transition(job.id,to:.sending)
        var metrics = TransmissionMetrics(); metrics.writeCalls = 2; metrics.submittedBytes = 4; metrics.pacingSeconds = 0.02
        try s.transition(job.id,to:.transmitted,metrics:metrics)
        let reopened = try Spool(root:s.root); try reopened.recover()
        let saved = try #require(try reopened.jobs().first)
        #expect(saved.state == .transmitted); #expect(saved.bytes == 0)
        #expect(saved.transmissionMetrics == metrics)
        #expect(!FileManager.default.fileExists(atPath:s.root.appendingPathComponent(job.id.uuidString).appendingPathComponent("pages.json").path))
    }
}
