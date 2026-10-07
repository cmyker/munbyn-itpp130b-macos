import Foundation
import AppKit
import ServiceManagement
import BridgeCore
@MainActor final class Coordinator {
    let spool: Spool
    let printer = BLEPrinter()
    let listener = SocketListener()
    let control = SocketListener()
    private let captureMode: PrintMode
    var dryRun: Bool { didSet { captureMode.set(dryRun) } }
    var pacing = Pacing()
    var status = "Starting"
    var onChange: (() -> Void)?
    var devices: [DiscoveredPrinter] = []
    private var lastJobTimings: [String:Double] = [:]
    private var lastTransmissionMetrics: TransmissionMetrics?
    private var task: Task<Void,Never>?
    private var busy = false
    private var suspended = false
    private var current: UUID?
    private var instanceFD: Int32 = -1
    private var observers: [NSObjectProtocol] = []
    init(dryRun: Bool) throws {
        try PrivateFiles.directory(Paths.root)
        let settings = Paths.root.appendingPathComponent("capture-setting.json")
        let saved = FileManager.default.fileExists(atPath:settings.path) ? try JSONDecoder().decode(Bool.self,from:PrivateFiles.read(settings,maxBytes:128)) : false
        self.dryRun = dryRun || saved
        captureMode = PrintMode(dryRun || saved)
        instanceFD = open(Paths.root.appendingPathComponent("instance.lock").path,O_CREAT | O_RDWR | O_NOFOLLOW,0o600)
        guard instanceFD >= 0,flock(instanceFD,LOCK_EX | LOCK_NB) == 0 else { if instanceFD >= 0 { close(instanceFD) }; throw BridgeError.invalid("Bridge is already running") }
        spool = try Spool(root: Paths.root.appendingPathComponent("spool")); try spool.recover()
        let profileURL = Paths.root.appendingPathComponent("printer.json")
        if FileManager.default.fileExists(atPath: profileURL.path) { printer.profile = try JSONDecoder().decode(PrinterProfile.self,from: PrivateFiles.read(profileURL,maxBytes: 8192)) }
        printer.onChange = { [weak self] in self?.onChange?() }
    }
    func start() throws {
        var info = stat()
        if lstat(Paths.control,&info) == 0 {
            guard info.st_uid == getuid(),info.st_mode & S_IFMT == S_IFSOCK else { throw BridgeError.invalid("Unexpected control socket owner/type") }
            unlink(Paths.control)
        }
        try control.startUnix(path: Paths.control) { [weak self] fd in
            do {
                let data = try ControlWire.readLine(fd: fd,timeout: 5)
                guard data.count <= 4096 else { throw BridgeError.invalid("Control request too large") }
                let request = try JSONDecoder().decode(ControlRequest.self,from: data)
                let semaphore = DispatchSemaphore(value: 0)
                let box = ReplyBox()
                Task { @MainActor in
                    if let self { do { box.data = try await self.command(request) } catch { box.data = Self.json(["error":String(describing: error)]) } }
                    semaphore.signal()
                }
                guard semaphore.wait(timeout: .now() + 45) == .success else { throw BridgeError.invalid("Control action timed out") }
                try ControlWire.send(box.data,fd: fd)
            } catch { try? ControlWire.send(Self.json(["error":String(describing:error)]),fd: fd) }
        }
        let spool = self.spool
        let incoming = listener, mode = captureMode
        try listener.startTCP(port: 19100) { [weak self] fd in
            do {
                let pages = try RasterReader.read(fd: fd)
                _ = try incoming.withActiveConnection(fd) { try spool.accept(pages: pages,captureOnly:mode.get()) }
                // Handler returns only after durable validation. TCP close remains unacknowledged to CUPS.
                Task { @MainActor in self?.status = "Job durably queued"; self?.process() }
            } catch { Task { @MainActor in self?.status = "Incoming job rejected: \(error)"; self?.onChange?() } }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.suspended = true; self?.task?.cancel(); self?.printer.releaseLink(); self?.status = "Paused for sleep" }
        })
        observers.append(workspace.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.suspended = false; self?.status = "Awake; pending jobs retained"; self?.process() }
        })
        status = dryRun ? "DRY RUN — sensitive local captures, no Bluetooth" : "Ready; owning user must remain logged in"
        process()
    }
    nonisolated static func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object,options:[.sortedKeys])) ?? Data("{}".utf8) }
    func jobs() -> [Job] {
        do { return try spool.jobs() } catch { suspended = true; status = "Private spool unreadable; review required"; return [] }
    }
    var blocked: Bool { jobs().contains { $0.state == .outcomeUnknown && !$0.recoveryConfirmed } }
    func process() {
        if blocked {
            status = "Printing blocked: inspect outcome-unknown job and recover printer"
            onChange?(); return
        }
        onChange?()
        guard task == nil,!busy,!suspended,!printer.scanning else { return }
        guard let job = jobs().first(where: { $0.state == .queued }) else { return }
        guard job.captureOnly == true || printer.profile != nil else { return }
        current = job.id
        task = Task(priority:.userInitiated) { [weak self] in
            guard let self else { return }
            defer { task = nil; current = nil; onChange?(); process() }
            // Scoped to active user work; idle/sleep behavior and BLE ownership stay separate.
            let activity = ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"Sending a requested thermal label job")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let clock = ContinuousClock()
            func elapsed(_ started: ContinuousClock.Instant) -> Double {
                let value = started.duration(to:clock.now).components
                return Double(value.seconds) + Double(value.attoseconds) / 1e18
            }
            let began = clock.now
            lastJobTimings = ["queueWaitWallSeconds":max(0,Date().timeIntervalSince(job.created))]
            lastTransmissionMetrics = nil
            var metrics: TransmissionMetrics?
            @MainActor func finish(_ state: JobState,error: String? = nil) throws {
                let started = clock.now
                defer { lastJobTimings["terminalPersistenceSeconds"] = elapsed(started) }
                try spool.transition(job.id,to:state,error:error,metrics:metrics)
            }
            do {
                let pages = try spool.pages(for: job.id)
                if job.captureOnly == true {
                    let directory = Paths.root.appendingPathComponent("diagnostics").appendingPathComponent(job.id.uuidString)
                    let diagnostics = directory.deletingLastPathComponent()
                    try PrivateFiles.directory(diagnostics)
                    let previous = try FileManager.default.contentsOfDirectory(at:diagnostics,includingPropertiesForKeys:nil)
                    var captureBytes = 0
                    if let files = FileManager.default.enumerator(at:diagnostics,includingPropertiesForKeys:[.fileSizeKey]) {
                        for case let file as URL in files { captureBytes += (try file.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0 }
                    }
                    let projected = pages.reduce(0) { $0 + $1.black.count * 2 + 8192 }
                    guard previous.count < 32,captureBytes + projected <= 128 * 1024 * 1024 else { throw BridgeError.invalid("Sensitive capture storage full; explicitly delete captures first") }
                    try PrivateFiles.directory(directory)
                    for (index,page) in pages.enumerated() {
                        try PrivateFiles.write(page.pbm,to: directory.appendingPathComponent("page-\(index+1).pbm"))
                        try PrivateFiles.write(TSPL.encode(page: page),to: directory.appendingPathComponent("page-\(index+1).tspl"))
                    }
                    try spool.transition(job.id,to: .captured)
                    status = "Captured \(pages.count) labels locally; no BLE writes"
                } else {
                    let encoded = try pages.map { try TSPL.encode(page: $0) }
                    lastJobTimings["loadAndEncodeSeconds"] = elapsed(began)
                    let connecting = clock.now
                    try spool.transition(job.id,to: .connecting); status = "Connecting for \(pages.count) labels"; onChange?()
                    lastJobTimings["connectingPersistenceSeconds"] = elapsed(connecting)
                    try await Transmission.send(pages: encoded,transport: printer,pacing: pacing,report:{ metrics = $0; self.lastTransmissionMetrics = $0 }) {
                        try self.spool.transition(job.id,to: .sending); self.status = "Sending — physical outcome unacknowledged"; self.onChange?()
                    }
                    try finish(.transmitted)
                    status = "Transmitted \(pages.count) labels; physical print not acknowledged"
                }
            } catch {
                do {
                    let state = try spool.jobs().first { $0.id == job.id }?.state
                    if state == .sending { try finish(.outcomeUnknown,error:"Transmission interrupted; duplicates possible; recover printer buffer before continuing") }
                    else if state == .connecting { try finish(Task.isCancelled ? .cancelled : .failedBeforeSend,error:String(describing:error)) }
                    else if state == .queued { try finish(.failedBeforeSend,error:"Stored job/capture failed: \(error); payload retained for review/retry") }
                } catch { status = "Spool failure; quit/restart requires review: \(error)"; suspended = true; return }
                status = "Job stopped: \(error)"
            }
        }
    }
    func command(_ request: ControlRequest) async throws -> Data {
        switch request.command {
        case "status","doctor":
            let inspection = await Task.detached { Result { try QueueInstaller.snapshot() } }.value
            let snapshot = (try? inspection.get()) ?? nil
            var inspectionDescription = "inspected localhost:631"
            if case .failure = inspection { inspectionDescription = "unavailable; ownership unknown" }
            var transmission: Any = NSNull()
            if let metrics = lastTransmissionMetrics,let data = try? JSONEncoder().encode(metrics),let object = try? JSONSerialization.jsonObject(with:data) { transmission = object }
            return Self.json(["application":"MUNBYN ITPP130B Bridge","version":"0.1.0-alpha.3","mode":dryRun ? "dry-run" : "BLE", "status":status,"bluetooth":printer.stateDescription,"bleStatus":printer.status,"bleTransport":printer.observedTransport,"pacingChunkCap":pacing.chunkCap,"pacingDelaySeconds":pacing.delay,"printerSelected":printer.profile != nil,"uncertainOutcomeBlocksPrinting":blocked,"loopback":"127.0.0.1:19100","queueInspection":inspectionDescription,"queueInstalled":snapshot != nil,"queueOwned":snapshot?.location == QueuePlan.marker && snapshot?.uri == QueuePlan.uri,"login":loginStatus,"lastJobTimingSeconds":lastJobTimings,"lastTransmissionMetrics":transmission,"jobs":jobs().map { ["id":$0.id.uuidString,"state":$0.state.rawValue,"pages":$0.pages] as [String:Any] }])
        case "scan":
            guard task == nil,!busy else { throw BridgeError.invalid("Printing/setup active") }
            busy = true; defer { busy = false; process() }
            devices = try await printer.scan(); onChange?()
            return try JSONEncoder().encode(devices)
        case "select":
            guard task == nil,!busy,let value = request.value,let id = UUID(uuidString:value) else { throw BridgeError.invalid("Select requires an explicit scan identifier while idle") }
            busy = true; defer { busy = false; process() }
            let profile = try await printer.select(id)
            try PrivateFiles.write(JSONEncoder().encode(profile),to: Paths.root.appendingPathComponent("printer.json"))
            printer.profile = profile; status = "Selected peripheral verified; physical calibration still required"; onChange?()
        case "connect":
            guard task == nil,!busy else { throw BridgeError.invalid("Printing/setup active") }
            busy = true; defer { busy = false; process() }
            try await printer.prepare()
            Task { @MainActor [weak self] in try? await Task.sleep(nanoseconds: 10_000_000_000); if self?.task == nil { self?.printer.releaseLink() } }
        case "release": task?.cancel(); printer.releaseLink()
        case "test-print":
            guard let media = Media(rawValue: request.value ?? "mm100x150") else { throw BridgeError.invalid("Unknown test media") }
            _ = try spool.accept(pages: [Calibration.page(media: media)],captureOnly:dryRun); process()
        case "install-queue":
            guard !busy,task == nil else { throw BridgeError.invalid("Printing/setup active") }
            busy = true; defer { busy = false; process() }
            try await Task.detached { try QueueInstaller.install() }.value
            status = "Project printer queue installed; default printer unchanged"
        case "uninstall-queue":
            guard request.confirm,task == nil,try spool.jobs().allSatisfy({ [.transmitted,.captured,.cancelled].contains($0.state) }) else { throw BridgeError.invalid("Review pending/uncertain jobs and pass explicit confirmation before uninstalling") }
            try await Task.detached { try QueueInstaller.uninstall() }.value
        case "cancel":
            guard let id = request.value.flatMap(UUID.init(uuidString:)) else { throw BridgeError.invalid("Job ID required") }
            if id == current { task?.cancel(); printer.releaseLink() }
            else { try spool.transition(id,to: .cancelled) }
        case "retry":
            guard let id = request.value.flatMap(UUID.init(uuidString:)) else { throw BridgeError.invalid("Job ID required") }
            try spool.transition(id,to: .queued); process()
        case "confirm-recovery":
            guard request.confirm,let id = request.value.flatMap(UUID.init(uuidString:)) else { throw BridgeError.invalid("Confirm paper inspection and printer-buffer recovery first") }
            try spool.confirmRecovery(id); process()
        case "reprint":
            guard let id = request.value.flatMap(UUID.init(uuidString:)) else { throw BridgeError.invalid("Job ID required") }
            _ = try spool.reprint(id,duplicateConfirmed: request.confirm); process()
        case "delete":
            guard let id = request.value.flatMap(UUID.init(uuidString:)) else { throw BridgeError.invalid("Job ID required") }
            try spool.delete(id,confirmed: request.confirm)
        case "clear-jobs":
            guard request.confirm, task == nil, !busy else { throw BridgeError.invalid("Clear All Jobs requires confirmation while printing/setup is idle") }
            try spool.clearAll(confirmed: true)
            status = "Bridge jobs cleared; no printer data sent"
        case "dry-run":
            guard task == nil,request.confirm else { throw BridgeError.invalid("Confirm sensitive capture mode while idle") }
            guard request.value == "on" || request.value == "off" else { throw BridgeError.invalid("dry-run requires on/off") }
            let enabled = request.value == "on"
            try PrivateFiles.write(JSONEncoder().encode(enabled),to:Paths.root.appendingPathComponent("capture-setting.json"))
            dryRun = enabled; status = dryRun ? "DRY RUN — sensitive captures enabled" : "BLE printing enabled"; process()
        case "clear-captures":
            guard request.confirm,task == nil else { throw BridgeError.invalid("Confirm ordinary deletion of sensitive captures while idle") }
            let captures = Paths.root.appendingPathComponent("diagnostics")
            if FileManager.default.fileExists(atPath:captures.path) { try FileManager.default.removeItem(at:captures) }
        case "pacing":
            guard task == nil,let value = request.value else { throw BridgeError.invalid("Pacing requires CHUNK,DELAY_SECONDS while idle") }
            let fields = value.split(separator:",")
            guard fields.count == 2,let cap = Int(fields[0]),let delay = Double(fields[1]),(20...512).contains(cap),delay.isFinite,(0.001...0.2).contains(delay) else { throw BridgeError.invalid("Pacing range: 20...512 bytes, 0.001...0.2 seconds") }
            pacing = Pacing(chunkCap:cap,delay:delay)
            status = "Pacing changed for this run; hardware measurements still required"
        case "write-mode":
            guard task == nil,!busy,let value = request.value,let preference = BLEWritePreference(rawValue:value),
                  var profile = printer.profile else { throw BridgeError.invalid("Select a printer and set with-response/without-response while idle") }
            profile.writePreference = preference
            try PrivateFiles.write(JSONEncoder().encode(profile),to:Paths.root.appendingPathComponent("printer.json"))
            printer.releaseLink(); printer.profile = profile
            status = "Write mode saved; properties will be verified on connection. Physical calibration required"
        case "login":
            if request.value == "on" { try SMAppService.mainApp.register() }
            else if request.value == "off" {
                // A fresh installation can report notFound before its first registration.
                // There is no login service to remove in either absent state.
                if ![SMAppService.Status.notRegistered,.notFound].contains(SMAppService.mainApp.status) {
                    try await SMAppService.mainApp.unregister()
                }
            } else { throw BridgeError.invalid("login requires on/off") }
        case "quit":
            guard request.confirm || jobs().allSatisfy({ [.transmitted,.captured,.cancelled].contains($0.state) }) else { throw BridgeError.invalid("Pending jobs retained; explicit quit confirmation needed") }
            suspended = true
            let activeTask = task; activeTask?.cancel(); printer.releaseLink()
            await activeTask?.value
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.2) { NSApp.terminate(nil) }
        default: throw BridgeError.invalid("Unknown control command")
        }
        onChange?(); return Self.json(["ok":true,"status":status])
    }
    var loginStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval in System Settings"
        case .notRegistered: return "not registered"
        case .notFound: return "login service not found"
        @unknown default: return "unknown"
        }
    }
    func stop() { task?.cancel(); printer.releaseLink(); listener.stop(); control.stop(); unlink(Paths.control); if instanceFD >= 0 { close(instanceFD); instanceFD = -1 } }
}
private final class ReplyBox { var data = Data("{}".utf8) }
private final class PrintMode {
    private let lock = NSLock(); private var capture: Bool
    init(_ value: Bool) { capture = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return capture }
    func set(_ value: Bool) { lock.lock(); defer { lock.unlock() }; capture = value }
}
