import Foundation
import BridgeCore

enum RecoveryStage { case warning, stopping, printerRestart, finishing, complete, failed }
private struct RecoveryReply: Decodable { var paused: Bool; var needsPrinterRestart: Bool }

@MainActor final class RecoveryModel {
    private let command: (ControlRequest) async throws -> Data
    private(set) var stage = RecoveryStage.warning
    private(set) var isPerforming = false
    private(set) var printerRestarted = false
    private(set) var errorText = ""
    var onChange: (() -> Void)?
    init(command: @escaping (ControlRequest) async throws -> Data) { self.command = command }
    func setPrinterRestarted(_ value: Bool) {
        guard stage == .printerRestart, !isPerforming else { return }
        printerRestarted = value; onChange?()
    }
    func advance() async {
        guard !isPerforming else { return }
        guard stage == .warning || stage == .failed || (stage == .printerRestart && printerRestarted) else { return }
        isPerforming = true; onChange?()
        defer { isPerforming = false; onChange?() }
        do {
            if stage != .printerRestart {
                stage = .stopping; errorText = ""; printerRestarted = false; onChange?()
                let data = try await command(.init(command: "recovery-begin", confirm: true))
                let reply = try JSONDecoder().decode(RecoveryReply.self, from: data)
                guard reply.paused else { throw BridgeError.invalid("Printing did not pause; retry recovery") }
                if reply.needsPrinterRestart { stage = .printerRestart; return }
            }
            stage = .finishing; onChange?()
            let data = try await command(.init(command: "recovery-finish", value: printerRestarted ? "printer-restarted" : nil, confirm: true))
            let reply = try JSONDecoder().decode(RecoveryReply.self, from: data)
            guard !reply.paused else { throw BridgeError.invalid("Recovery is still paused; retry to finish") }
            stage = .complete
        } catch { errorText = String(describing: error); stage = .failed }
    }
}
