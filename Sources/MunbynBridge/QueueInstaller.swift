import Foundation
import CBridge
import BridgeCore
enum QueueInstaller {
    static func snapshot(server: String) throws -> QueueSnapshot? {
        var location = [CChar](repeating: 0,count: 1024),uri = [CChar](repeating: 0,count: 2048)
        let result = mb_queue_snapshot(server,QueuePlan.id,&location,location.count,&uri,uri.count)
        guard result >= 0 else { throw BridgeError.invalid("Local CUPS ownership inspection failed; refusing queue changes") }
        guard result == 1 else { return nil }
        return .init(location: String(cString:location),uri: String(cString:uri))
    }
    static func run(_ executable: String,_ args: [String],server: String) throws -> (Int32,String) {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardOutput = output; process.standardError = output
        process.environment = ["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LANG":"C","CUPS_SERVER":server]
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus,String(decoding: data,as: UTF8.self))
    }
    static func execute(_ args: [String],server: String) throws {
        guard !args.isEmpty else { return }
        // argv carries the endpoint so the auth retry reuses it as is
        guard args.count >= 2,args[0] == "-h",args[1] == server else { throw BridgeError.invalid("Queue operation endpoint mismatch") }
        let (code,message) = try run("/usr/sbin/lpadmin",args,server: server)
        if code == 0 { return }
        guard ["forbidden","unauthorized","not authorized","password"].contains(where: { message.lowercased().contains($0) }) else {
            throw BridgeError.invalid("CUPS queue operation failed: \(message.prefix(1024))")
        }
        // Fixed system executable and validated argument vector; never a shell command.
        let allocated = args.map { strdup($0)! }; defer { allocated.forEach { free($0) } }
        var pointers: [UnsafeMutablePointer<CChar>?] = allocated.map { $0 } + [nil]
        let result = mb_lpadmin_authorized(&pointers)
        guard result == 0 else { throw BridgeError.invalid("Administrator authorization denied or queue operation unavailable (\(result))") }
    }
    static func install() throws {
        guard let ppd = Bundle.main.path(forResource: "ITPP130B",ofType: "ppd") else { throw BridgeError.invalid("Bundled PPD missing") }
        let server = QueuePlan.selectServer() // one endpoint for the whole install
        let (code,_) = try run("/usr/bin/cupstestppd",["-q",ppd],server: server)
        guard code == 0 else { throw BridgeError.invalid("Bundled PPD validation failed") }
        try execute(QueuePlan.install(ppd: ppd,existing: snapshot(server: server),server: server),server: server)
        guard let queue = try snapshot(server: server),queue.location == QueuePlan.marker,queue.uri == QueuePlan.uri else { throw BridgeError.invalid("Queue installation not confirmed; use Repair Printer Queue") }
    }
    static func uninstall() throws {
        let server = QueuePlan.selectServer() // one endpoint for the whole rm
        if try snapshot(server: server) != nil {
            let (_,pending) = try run("/usr/bin/lpstat",["-h",server,"-o",QueuePlan.id],server: server)
            guard pending.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw BridgeError.invalid("Review/cancel this project's pending Print Center jobs before uninstalling") }
        }
        try execute(QueuePlan.uninstall(existing: snapshot(server: server),server: server),server: server)
        guard try snapshot(server: server) == nil else { throw BridgeError.invalid("Queue removal not confirmed") }
    }
}
