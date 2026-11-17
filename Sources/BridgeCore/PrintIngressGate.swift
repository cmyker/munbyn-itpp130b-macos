import Foundation

/// Orders background acceptance against the owner's durable recovery pause.
public final class PrintIngressGate {
    private let lock = NSLock()
    private var open: Bool
    public init(isOpen: Bool) { open = isOpen }
    public var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    public func setOpen(_ value: Bool) { lock.lock(); defer { lock.unlock() }; open = value }
    public func withAcceptance<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard open else { throw BridgeError.invalid("Printing is paused for recovery") }
        return try body()
    }
}
