import Foundation
import Testing
import CBridge
import BridgeCore

struct NativeQueueRecoveryTests {
    @Test func requestsSelectBothPrinterAndUserAndOnlyExplicitJobIDs() throws {
        let request = try #require(mb_recovery_jobs_request(QueuePlan.id, "tester")); defer { ippDelete(request) }
        #expect(ippGetOperation(request) == IPP_OP_GET_JOBS)
        #expect(string(request, "printer-uri", IPP_TAG_URI) == "ipp://localhost:631/printers/MUNBYN_ITPP130B_Bluetooth")
        #expect(string(request, "requesting-user-name", IPP_TAG_NAME) == "tester")
        #expect(ippGetBoolean(ippFindAttribute(request, "my-jobs", IPP_TAG_BOOLEAN), 0) == 1)
        #expect(string(request, "which-jobs", IPP_TAG_KEYWORD) == "not-completed")
        let cancel = try #require(mb_recovery_cancel_request(QueuePlan.id, "tester", [42, 43], 2)); defer { ippDelete(cancel) }
        #expect(ippGetOperation(cancel) == IPP_OP_CANCEL_MY_JOBS)
        #expect(string(cancel, "printer-uri", IPP_TAG_URI) == "ipp://localhost:631/printers/MUNBYN_ITPP130B_Bluetooth")
        let selected = try #require(ippFindAttribute(cancel, "job-ids", IPP_TAG_INTEGER))
        #expect(ippGetCount(selected) == 2 && ippGetInteger(selected, 0) == 42 && ippGetInteger(selected, 1) == 43)
        #expect(string(cancel, "requesting-user-name", IPP_TAG_NAME) == "tester")
        #expect(mb_recovery_cancel_request(QueuePlan.id, "tester", [0], 1) == nil)
        #expect(mb_recovery_cancel_request(QueuePlan.id, "tester", nil, 0) == nil)
        #expect(mb_recovery_cancel_request(QueuePlan.id, "tester", [42], 1025) == nil)
        #expect(mb_recovery_jobs_request(QueuePlan.id, "") == nil)
    }
    @Test func structuredResponseUsesQueueAndUserIntersection() throws {
        let response = try #require(ippNew()); defer { ippDelete(response) }
        addJob(response, 11, "tester", "ipp://localhost:631/printers/USB_fixture")
        addJob(response, 12, "someone-else", "ipp://localhost:631/printers/MUNBYN_ITPP130B_Bluetooth")
        addJob(response, 13, "tester", "ipp://localhost/printers/MUNBYN_ITPP130B_Bluetooth")
        addJob(response, 14, "TESTER", "ipp://localhost/printers/MUNBYN_ITPP130B_Bluetooth")
        var ids = [Int32](repeating: 0, count: 4)
        #expect(mb_recovery_job_ids(response, QueuePlan.id, "tester", &ids, ids.count) == 2)
        #expect(ids.prefix(2) == [13, 14])
        let empty = try #require(ippNew()); defer { ippDelete(empty) }
        #expect(mb_recovery_job_ids(empty, QueuePlan.id, "tester", &ids, ids.count) == 0)
    }
    @Test func malformedOrExcessiveResponsesCannotTriggerPartialCancellation() throws {
        let response = try #require(ippNew()); defer { ippDelete(response) }
        addJob(response, 11, "tester", "ipp://localhost/printers/MUNBYN_ITPP130B_Bluetooth")
        addJob(response, 12, "tester", "ipp://localhost/printers/MUNBYN_ITPP130B_Bluetooth")
        var ids = [Int32](repeating: 0, count: 1)
        #expect(mb_recovery_job_ids(response, QueuePlan.id, "tester", &ids, ids.count) == -1)
        let malformed = try #require(ippNew()); defer { ippDelete(malformed) }
        ippAddInteger(malformed, IPP_TAG_JOB, IPP_TAG_INTEGER, "job-id", 9)
        #expect(mb_recovery_job_ids(malformed, QueuePlan.id, "tester", &ids, ids.count) == -1)
    }
    private func string(_ request: OpaquePointer, _ name: String, _ tag: ipp_tag_t) -> String? {
        guard let attr = ippFindAttribute(request, name, tag), let value = ippGetString(attr, 0, nil) else { return nil }
        return String(cString: value)
    }
    private func addJob(_ response: OpaquePointer, _ id: Int32, _ user: String, _ uri: String) {
        ippAddSeparator(response)
        ippAddInteger(response, IPP_TAG_JOB, IPP_TAG_INTEGER, "job-id", id)
        ippAddString(response, IPP_TAG_JOB, IPP_TAG_NAME, "job-originating-user-name", nil, user)
        ippAddString(response, IPP_TAG_JOB, IPP_TAG_URI, "job-printer-uri", nil, uri)
    }
}
