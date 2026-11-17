import Foundation
import Darwin
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
    @Test func storageFailureStillStopsThisProcessAndRetainsItsJobs() async throws {
        let (root, spool, recovery) = try fixture()
        defer { chmod(root.path, 0o700); try? FileManager.default.removeItem(at: root) }
        _ = try spool.accept(pages: [testPage]); var stopped = false
        #expect(chmod(root.path, 0o500) == 0)
        do {
            try await recovery.begin(stop: { stopped = true }, cancelNative: { Issue.record("Do not mutate CUPS without a saved pause") })
            Issue.record("Expected pause persistence failure")
        } catch {}
        #expect(stopped && recovery.isPaused && !recovery.ingress.isOpen)
        #expect(try spool.jobs().count == 1)
    }
    @Test func listenerCannotAcceptBeforeDurableUnpauseAndStopsIfThatWriteFails() async throws {
        let (root, spool, recovery) = try fixture()
        defer { chmod(root.path, 0o700); try? FileManager.default.removeItem(at: root) }
        try await recovery.begin(stop: {}, cancelNative: {})
        let listener = SocketListener(); defer { listener.stop() }
        let gate = recovery.ingress
        let rejected = DispatchSemaphore(value: 0)
        let accepted = ResultBox<Bool>()
        do {
            try await recovery.finish(printerRestarted: false, prepare: {}, resume: {
                try listener.startTCP(port: 0) { fd in
                    do {
                        try listener.withActiveConnection(fd) {
                            try gate.withAcceptance { _ = try spool.accept(pages: [testPage]) }
                        }
                        accepted.set(true)
                    } catch { accepted.set(false) }
                    rejected.signal()
                }
                let client = try tcpConnect(listener.port); defer { close(client) }
                #expect(rejected.wait(timeout: .now() + 2) == .success)
                // Fail the real final file creation after binding succeeds.
                #expect(chmod(root.path, 0o500) == 0)
            }, stopIngress: { listener.stop() })
            Issue.record("Expected durable unpause failure")
        } catch {}
        #expect(accepted.get() == false)
        #expect(recovery.isPaused && !recovery.ingress.isOpen)
        #expect(try spool.jobs().isEmpty)
        for _ in 0..<500 where !listener.isStopped { try await Task.sleep(for: .milliseconds(10)) }
        #expect(listener.isStopped)
        #expect(chmod(root.path, 0o700) == 0)
        let reopened = try PrintingRecovery(spool: spool, stateURL: root.appendingPathComponent("paused.json"))
        #expect(reopened.isPaused && !reopened.ingress.isOpen)
        try await recovery.finish(printerRestarted: false, prepare: {}, resume: {})
        #expect(recovery.ingress.isOpen)
        _ = try recovery.ingress.withAcceptance { try spool.accept(pages: [testPage]) }
        #expect(try spool.jobs().count == 1)
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
