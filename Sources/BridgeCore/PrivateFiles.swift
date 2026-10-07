import Foundation
import Darwin
public enum PrivateFiles {
    public static func directory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path,&info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else { throw BridgeError.invalid("Private directory has wrong owner or type") }
        } else {
            guard errno == ENOENT else { throw BridgeError.invalid("Cannot inspect private directory") }
            try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true,attributes: [.posixPermissions:0o700])
        }
        guard chmod(url.path,0o700) == 0 else { throw BridgeError.invalid("Cannot restrict private directory") }
    }
    public static func write(_ data: Data,to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        let fd = open(temporary.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw BridgeError.invalid("Cannot create private spool file") }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd,raw.baseAddress!.advanced(by: offset),raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw BridgeError.invalid("Spool write failed") }
                offset += n
            }
        }
        guard fsync(fd) == 0 else { throw BridgeError.invalid("Spool sync failed") }
        // macOS full device flush where supported; fsync remains the baseline contract.
        _ = fcntl(fd,F_FULLFSYNC)
        guard rename(temporary.path,url.path) == 0 else { throw BridgeError.invalid("Spool commit failed") }
        try syncDirectory(url.deletingLastPathComponent())
    }
    public static func read(_ url: URL,maxBytes: Int = 16 * 1024 * 1024) throws -> Data {
        let fd = open(url.path,O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw BridgeError.invalid("Private spool file unavailable") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0,info.st_uid == getuid(),info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,info.st_size <= maxBytes else { throw BridgeError.invalid("Invalid private file") }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.read(fd,raw.baseAddress!.advanced(by: offset),raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw BridgeError.invalid("Private file truncated") }; offset += n
            }
        }
        return data
    }
    public static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path,O_RDONLY | O_NOFOLLOW); guard fd >= 0 else { throw BridgeError.invalid("Cannot open spool directory") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw BridgeError.invalid("Spool directory sync failed") }
    }
}
