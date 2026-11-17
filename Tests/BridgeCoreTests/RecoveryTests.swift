import Foundation
import Testing
@testable import BridgeCore

@MainActor struct RecoveryTests {
    private func fixture() throws -> (URL, Spool, PrintingRecovery) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try PrivateFiles.directory(root)
        let spool = try Spool(root: root.appendingPathComponent("spool"))
        return (root, spool, try PrintingRecovery(spool: spool, stateURL: root.appendingPathComponent("paused.json")))
    }
    @Test func pauseIsDurableBeforeStoppingWorkAndSurvivesRestart() async throws {
        let (root, spool, recovery) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let job = try spool.accept(pages: [testPage])
        try await recovery.begin(stop: {
            let reopened = try PrintingRecovery(spool: spool, stateURL: root.appendingPathComponent("paused.json"))
            #expect(reopened.isPaused)
            #expect(try spool.pages(for: job.id) == [testPage])
        }, cancelNative: {})
        #expect(recovery.isPaused)
        #expect(try spool.jobs().first?.state == .queued)
    }
    @Test func interruptedStartRetainsPauseAndJobsForUserToResume() async throws {
        let (root, spool, recovery) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let job = try spool.accept(pages: [testPage])
        do {
            try await recovery.begin(stop: { throw BridgeError.invalid("Still stopping") }, cancelNative: { Issue.record("Must not cancel native work before stopping") })
            Issue.record("Expected stop failure")
        } catch {}
        let reopened = try PrintingRecovery(spool: spool, stateURL: root.appendingPathComponent("paused.json"))
        #expect(reopened.isPaused)
        #expect(try spool.pages(for: job.id) == [testPage])
    }
    @Test func unknownOutcomeRequiresExplicitPrinterRestartBeforeClearing() async throws {
        let (root, spool, recovery) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let job = try spool.accept(pages: [testPage])
        try spool.transition(job.id, to: .connecting); try spool.transition(job.id, to: .sending)
        try await recovery.begin(stop: { try spool.transition(job.id, to: .outcomeUnknown) }, cancelNative: {})
        #expect(try recovery.needsPrinterRestart())
        do {
            try await recovery.finish(printerRestarted: false, prepare: { Issue.record("No reset before confirmation") }, resume: { Issue.record("Must stay paused") })
            Issue.record("Expected physical recovery requirement")
        } catch {}
        #expect(recovery.isPaused)
        #expect(try spool.pages(for: job.id) == [testPage])
        var resumed = false
        try await recovery.finish(printerRestarted: true, prepare: {
            let jobs = try spool.jobs()
            #expect(recovery.isPaused)
            #expect(jobs.count == 1)
        }, resume: {
            let jobs = try spool.jobs()
            resumed = true; #expect(recovery.isPaused); #expect(jobs.isEmpty)
        })
        #expect(resumed && !recovery.isPaused)
        #expect(try spool.jobs().isEmpty)
        let reopened = try PrintingRecovery(spool: spool, stateURL: root.appendingPathComponent("paused.json"))
        #expect(!reopened.isPaused)
    }
    @Test func finishFailureStaysPausedAndCanBeRepeatedWithoutReplaying() async throws {
        let (root, spool, recovery) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try spool.accept(pages: [testPage])
        try await recovery.begin(stop: {}, cancelNative: {})
        do {
            try await recovery.finish(printerRestarted: false, prepare: { throw BridgeError.invalid("Native queue unavailable") }, resume: {})
            Issue.record("Expected preparation failure")
        } catch {}
        #expect(recovery.isPaused); #expect(try spool.jobs().count == 1)
        do {
            try await recovery.finish(printerRestarted: false, prepare: {}, resume: { throw BridgeError.invalid("Port conflict") })
            Issue.record("Expected resume failure")
        } catch {}
        #expect(recovery.isPaused); #expect(try spool.jobs().isEmpty)
        try await recovery.begin(stop: {}, cancelNative: {})
        try await recovery.finish(printerRestarted: false, prepare: {}, resume: {})
        #expect(!recovery.isPaused)
    }
    @Test func activeSendingCannotBeClearedEvenIfUserConfirmsRestart() async throws {
        let (root, spool, recovery) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let job = try spool.accept(pages: [testPage])
        try spool.transition(job.id, to: .connecting); try spool.transition(job.id, to: .sending)
        try await recovery.begin(stop: {}, cancelNative: {})
        do {
            try await recovery.finish(printerRestarted: true, prepare: { Issue.record("Active sender still owns work") }, resume: {})
            Issue.record("Expected active-work refusal")
        } catch {}
        #expect(recovery.isPaused)
        #expect(try spool.pages(for: job.id) == [testPage])
    }
    @Test func newUncertaintyDuringPreparationCannotBypassRestartConfirmation() async throws {
        let (root, spool, recovery) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let job = try spool.accept(pages: [testPage])
        try await recovery.begin(stop: {}, cancelNative: {})
        do {
            try await recovery.finish(printerRestarted: false, prepare: {
                try spool.transition(job.id, to: .connecting)
                try spool.transition(job.id, to: .sending)
                try spool.transition(job.id, to: .outcomeUnknown)
            }, resume: { Issue.record("Must retain newly uncertain work") })
            Issue.record("Expected new uncertainty to require confirmation")
        } catch {}
        #expect(recovery.isPaused)
        #expect(try spool.jobs().first?.recoveryConfirmed == false)
    }
    @Test func finishCannotRunWhileTheSenderIsStillStopping() async throws {
        let (root, spool, recovery) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let job = try spool.accept(pages: [testPage])
        var stopped: CheckedContinuation<Void, Never>?
        let start = Task {
            try await recovery.begin(stop: { await withCheckedContinuation { stopped = $0 } }, cancelNative: {})
        }
        for _ in 0..<10_000 where stopped == nil { await Task.yield() }
        if stopped == nil { start.cancel(); Issue.record("Recovery did not enter stopping"); return }
        do {
            try await recovery.finish(printerRestarted: false, prepare: { Issue.record("Recovery start still owns work") }, resume: {})
            Issue.record("Expected overlapping finish to stop")
        } catch {}
        #expect(try spool.jobs().first?.id == job.id)
        #expect(recovery.isPaused)
        stopped?.resume()
        try await start.value
    }
}
