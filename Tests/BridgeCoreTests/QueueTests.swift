import Foundation
import Testing
@testable import BridgeCore
struct QueueTests {
    @Test func installationIsNarrowIdempotentAndUnshared() throws {
        let args = try QueuePlan.install(ppd: "/tmp/fixture.ppd",existing: nil,server: "/private/var/run/cupsd")
        #expect(args == ["-h","/private/var/run/cupsd","-p","MUNBYN_ITPP130B_Bluetooth","-D","MUNBYN ITPP130B (Bluetooth)","-L","munbyn-itpp130b-bridge-v1","-v","socket://127.0.0.1:19100/?contimeout=5&waiteof=true","-P","/tmp/fixture.ppd","-E","-o","printer-is-shared=false","-o","printer-error-policy=abort-job","-o","job-sheets-default=none","-o","PageSize=Label100x150"])
        #expect(try QueuePlan.install(ppd: "/tmp/fixture.ppd",existing: .init(location: QueuePlan.marker,uri: QueuePlan.uri),server: "/private/var/run/cupsd") == args)
        #expect(try Array(QueuePlan.install(ppd: "/tmp/fixture.ppd",existing: nil,server: "localhost:631").prefix(2)) == ["-h","localhost:631"])
    }
    @Test func refusesForeignQueueAndNeverDeletesUSB() {
        expectThrows(try QueuePlan.install(ppd: "/tmp/fixture.ppd",existing: .init(location: "unrelated",uri: QueuePlan.uri),server: "localhost:631"))
        expectThrows(try QueuePlan.uninstall(existing: .init(location: QueuePlan.marker,uri: "usb://Printer/ITPP130"),server: "localhost:631"))
    }
    @Test func refusesUnpinnedOrRemoteEndpoints() {
        expectThrows(try QueuePlan.install(ppd: "/tmp/fixture.ppd",existing: nil,server: "localhost"))
        expectThrows(try QueuePlan.install(ppd: "/tmp/fixture.ppd",existing: nil,server: "remote.invalid:631"))
        expectThrows(try QueuePlan.uninstall(existing: nil,server: "localhost"))
    }
    @Test func uninstallOnlyOwnsExactQueue() throws {
        #expect(try QueuePlan.uninstall(existing: nil,server: "localhost:631").isEmpty)
        #expect(try QueuePlan.uninstall(existing: .init(location: QueuePlan.marker,uri: QueuePlan.uri),server: "/private/var/run/cupsd") == ["-h","/private/var/run/cupsd","-x",QueuePlan.id])
        #expect(try QueuePlan.uninstall(existing: .init(location: QueuePlan.marker,uri: QueuePlan.uri),server: "localhost:631") == ["-h","localhost:631","-x",QueuePlan.id])
    }
    @Test func quotesEveryShellMetacharacterAsLiteral() {
        #expect(QueuePlan.shellQuote("a'$(secret)`thing`\n") == "'a'\\''$(secret)`thing`\n'")
    }
}
import CBridge
extension QueueTests {
    @Test func inspectionCannotFollowRemoteServerOrTreatFailureAsAbsence() {
        let previous = String(cString:cupsServer()); cupsSetServer("remote.invalid"); defer { cupsSetServer(previous) }
        #expect(["/private/var/run/cupsd","localhost:631"].contains(String(cString:mb_cups_host())))
        #expect(String(cString:mb_cups_host_for(1)) == "/private/var/run/cupsd")
        #expect(String(cString:mb_cups_host_for(0)) == "localhost:631")
        #expect(QueuePlan.selectServer() == String(cString:mb_cups_host()))
        var location = [CChar](repeating:0,count:64),uri = [CChar](repeating:0,count:64)
        #expect(mb_queue_snapshot("remote.invalid:631",QueuePlan.id,&location,location.count,&uri,uri.count) == -1)
        #expect(mb_queue_snapshot("localhost",QueuePlan.id,&location,location.count,&uri,uri.count) == -1)
        #expect(mb_queue_status(IPP_STATUS_ERROR_SERVICE_UNAVAILABLE,0) == -1)
        #expect(mb_queue_status(IPP_STATUS_ERROR_NOT_FOUND,1) == 0)
        #expect(mb_queue_status(IPP_STATUS_ERROR_NOT_FOUND,0) == 0)
        #expect(mb_queue_status(IPP_STATUS_OK,1) == 1)
    }
    @Test func deviceURIParsesWithApplesCUPSIncludingQuery() {
        var scheme = [CChar](repeating:0,count:64),user = [CChar](repeating:0,count:64),host = [CChar](repeating:0,count:256),resource = [CChar](repeating:0,count:1024),port: Int32 = 0
        let result = httpSeparateURI(HTTP_URI_CODING_ALL,QueuePlan.uri,&scheme,64,&user,64,&host,256,&port,&resource,1024)
        #expect(result.rawValue >= 0)
        #expect(String(cString:host) == "127.0.0.1"); #expect(port == 19100)
        #expect(String(cString:resource).contains("contimeout=5"))
    }
}
