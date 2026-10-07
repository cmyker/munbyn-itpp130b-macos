import Foundation
import Darwin
public final class SocketListener {
    private var fd: Int32 = -1
    private var active: Int32 = -1
    private var stopping = false
    private let lock = NSLock()
    public private(set) var port: UInt16 = 0
    public init() {}
    /// Acceptance and local shutdown are ordered under one lock. A local EOF is never accepted.
    public func withActiveConnection<T>(_ connection: Int32,_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !stopping,fd >= 0,active == connection else { throw CancellationError() }
        return try body()
    }
    public func startTCP(port: UInt16,handler: @escaping (Int32) -> Void) throws {
        let socketFD = socket(AF_INET,SOCK_STREAM,0)
        guard socketFD >= 0 else { throw BridgeError.invalid("Cannot create print listener") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self,capacity: 1) { bind(socketFD,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { close(socketFD); throw BridgeError.invalid("Loopback port unavailable; another instance or application may own it") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self,capacity: 1) { _ = getsockname(socketFD,$0,&length) } }
        self.port = UInt16(bigEndian: address.sin_port)
        try begin(socketFD: socketFD,handler: handler)
    }
    public func startUnix(path: String,handler: @escaping (Int32) -> Void) throws {
        var address = sockaddr_un(); let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw BridgeError.invalid("Control socket path too long") }
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
        let socketFD = socket(AF_UNIX,SOCK_STREAM,0)
        guard socketFD >= 0 else { throw BridgeError.invalid("Cannot create control socket") }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self,capacity: 1) { bind(socketFD,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { close(socketFD); throw BridgeError.invalid("Cannot bind private control socket") }
        guard chmod(path,0o600) == 0 else { close(socketFD); throw BridgeError.invalid("Cannot restrict control socket") }
        try begin(socketFD: socketFD) { fd in
            var uid: uid_t = 0; var gid: gid_t = 0
            guard getpeereid(fd,&uid,&gid) == 0,uid == getuid() else { return }
            handler(fd)
        }
    }
    private func begin(socketFD: Int32,handler: @escaping (Int32) -> Void) throws {
        guard listen(socketFD,2) == 0 else { close(socketFD); throw BridgeError.invalid("Cannot listen") }
        lock.lock()
        guard fd < 0 else { lock.unlock(); close(socketFD); throw BridgeError.invalid("Listener already started") }
        fd = socketFD; stopping = false; lock.unlock()
        DispatchQueue(label:"bridge.listener.\(socketFD)",qos: .userInitiated).async { [self] in
            while true {
                lock.lock(); let running = fd == socketFD && !stopping; lock.unlock()
                if !running { break }
                var event = pollfd(fd:socketFD,events:Int16(POLLIN),revents:0)
                let ready = poll(&event,1,250)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                if ready < 0 { break }
                let connection = accept(socketFD,nil,nil)
                if connection < 0 { if errno == EINTR { continue }; break }
                lock.lock()
                if stopping || fd != socketFD { lock.unlock(); close(connection); break }
                active = connection; lock.unlock()
                var yes: Int32 = 1
                setsockopt(connection,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout<Int32>.size))
                handler(connection)
                lock.lock(); active = -1; lock.unlock(); close(connection)
            }
            // The worker owns the descriptor until its final accept is finished.
            lock.lock(); close(socketFD); if fd == socketFD { fd = -1 }; lock.unlock()
        }
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        stopping = true
        if active >= 0 { shutdown(active,SHUT_RDWR) }
        if fd >= 0 { shutdown(fd,SHUT_RDWR) }
    }
    deinit { stop() }
}
public enum ControlWire {
    public static func readLine(fd: Int32,timeout: Int = 40) throws -> Data {
        var time = timeval(tv_sec: timeout,tv_usec: 0)
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&time,socklen_t(MemoryLayout<timeval>.size))
        var data = Data(); var byte: UInt8 = 0
        while data.count < 16 * 1024 {
            let n = recv(fd,&byte,1,0)
            guard n == 1 else { throw BridgeError.invalid("Control service unavailable or timed out") }
            if byte == 10 { return data }; data.append(byte)
        }
        throw BridgeError.invalid("Control message too large")
    }
    public static func send(_ data: Data,fd: Int32) throws {
        let message = data + Data([10]); var time = timeval(tv_sec: 5,tv_usec: 0)
        setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&time,socklen_t(MemoryLayout<timeval>.size))
        try message.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.send(fd,raw.baseAddress!.advanced(by: offset),raw.count - offset,0)
                guard n > 0 else { throw BridgeError.invalid("Control write failed") }; offset += n
            }
        }
    }
    public static func request(path: String,data: Data) throws -> Data {
        let fd = socket(AF_UNIX,SOCK_STREAM,0); guard fd >= 0 else { throw BridgeError.invalid("Control socket unavailable") }
        defer { close(fd) }; var yes: Int32 = 1
        setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un(); let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw BridgeError.invalid("Control path too long") }
        addr.sun_family = sa_family_t(AF_UNIX); addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self,capacity: 1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw BridgeError.invalid("Bridge app is not running; open MUNBYN ITPP130B Bridge.app") }
        try send(data,fd: fd); return try readLine(fd: fd)
    }
}
public struct ControlRequest: Codable {
    public var command: String; public var value: String?; public var confirm: Bool
    public init(command: String,value: String? = nil,confirm: Bool = false) { self.command = command; self.value = value; self.confirm = confirm }
}
public enum Paths {
    public static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0].appendingPathComponent("MunbynBridge") }
    public static var control: String { root.appendingPathComponent("control.sock").path }
}
