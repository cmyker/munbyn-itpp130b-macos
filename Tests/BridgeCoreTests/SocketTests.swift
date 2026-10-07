import Foundation
import Testing
import Darwin
@testable import BridgeCore
final class ResultBox<T> { private let lock = NSLock(); private var result: T?
    func set(_ value: T) { lock.lock(); defer { lock.unlock() }; result = value }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return result }
}
func tcpConnect(_ port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET,SOCK_STREAM,0)
    var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if result != 0 { close(fd); throw BridgeError.invalid("Fixture connect failed") }; return fd
}
struct SocketTests {
    @Test func stoppingWorkerCannotAcceptOnRecycledDescriptor() throws {
        let listener = SocketListener(); defer { listener.stop() }
        let entered = DispatchSemaphore(value:0),resume = DispatchSemaphore(value:0)
        try listener.startTCP(port:0) { _ in entered.signal(); _ = resume.wait(timeout:.now()+2) }
        let first = try tcpConnect(listener.port); defer { close(first) }
        #expect(entered.wait(timeout:.now()+1) == .success)
        listener.stop()
        // A separate raw listener has no worker. An old worker must never accept it.
        let raw = socket(AF_INET,SOCK_STREAM,0); defer { close(raw) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to:&addr) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(raw,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(bound == 0); #expect(listen(raw,1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to:&addr) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { _ = getsockname(raw,$0,&length) } }
        let second = try tcpConnect(UInt16(bigEndian:addr.sin_port)); defer { close(second) }
        var timeout = timeval(tv_sec:0,tv_usec:500000)
        setsockopt(second,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        resume.signal()
        var byte: UInt8 = 0
        #expect(recv(second,&byte,1,0) < 0) // no worker should close/consume this connection
    }
    @Test func localStopCannotAcceptCompletePagePrefixAsJob() throws {
        let listener = SocketListener(); defer { listener.stop() }
        let pageRead = DispatchSemaphore(value:0),done = DispatchSemaphore(value:0)
        let accepted = ResultBox<Bool>()
        try listener.startTCP(port:0) { fd in
            do {
                let pages = try RasterReader.read(fd:fd,timeout:5,onPageRead:{ pageRead.signal() })
                try listener.withActiveConnection(fd) { accepted.set(!pages.isEmpty) }
            } catch { accepted.set(false) }
            done.signal()
        }
        let fd = try tcpConnect(listener.port); defer { close(fd) }
        let twoPages = try rasterFixture()
        let onePage = twoPages.prefix(4 + (twoPages.count - 4)/2)
        onePage.withUnsafeBytes { raw in _ = Darwin.send(fd,raw.baseAddress!,raw.count,0) }
        #expect(pageRead.wait(timeout:.now()+2) == .success)
        listener.stop() // sender deliberately never closes its write side
        #expect(done.wait(timeout:.now()+6) == .success)
        #expect(accepted.get() == false)
    }
    @Test func fragmentedTCPAndHalfCloseProduceOneCompleteJob() throws {
        let listener = SocketListener(); defer { listener.stop() }
        let box = ResultBox<Result<[RasterPage],Error>>(); let done = DispatchSemaphore(value:0)
        try listener.startTCP(port:0) { fd in
            do { box.set(.success(try RasterReader.read(fd:fd,timeout:5))) } catch { box.set(.failure(error)) }; done.signal()
        }
        let conflict = SocketListener(); defer { conflict.stop() }
        expectThrows(try conflict.startTCP(port:listener.port) { _ in })
        let fd = try tcpConnect(listener.port); defer { close(fd) }
        let bytes = try rasterFixture()
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let length = min([1,2,17,4096][offset % 4],raw.count - offset)
                let n = Darwin.send(fd,raw.baseAddress!.advanced(by:offset),length,0)
                guard n > 0 else { throw BridgeError.invalid("Fixture send failed") }; offset += n
            }
        }
        shutdown(fd,SHUT_WR)
        #expect(done.wait(timeout:.now()+6) == .success)
        let result = try #require(box.get()); #expect(try result.get().count == 2)
        var byte: UInt8 = 0; #expect(recv(fd,&byte,1,0) == 0)
    }
    @Test func stalledTCPReceiveIsBounded() throws {
        let listener = SocketListener(); defer { listener.stop() }
        let done = DispatchSemaphore(value:0); let box = ResultBox<Bool>()
        try listener.startTCP(port:0) { fd in
            do { _ = try RasterReader.read(fd:fd,timeout:0.01); box.set(false) } catch { box.set(true) }; done.signal()
        }
        let fd = try tcpConnect(listener.port); defer { close(fd) }
        #expect(done.wait(timeout:.now()+1) == .success); #expect(box.get() == true)
    }
    @Test func privateControlRoundTripAndAbsentApp() throws {
        let root = URL(fileURLWithPath:"/tmp/mb-test-" + UUID().uuidString)
        try PrivateFiles.directory(root); defer { try? FileManager.default.removeItem(at:root) }
        let path = root.appendingPathComponent("control.sock").path
        let server = SocketListener(); defer { server.stop() }
        try server.startUnix(path:path) { fd in
            do { let input = try ControlWire.readLine(fd:fd); try ControlWire.send(input,fd:fd) } catch {}
        }
        let data = Data("{\"command\":\"doctor\"}".utf8)
        #expect(try ControlWire.request(path:path,data:data) == data)
        expectThrows(try ControlWire.request(path:path+"-absent",data:data))
        let attrs = try FileManager.default.attributesOfItem(atPath:path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
