import Foundation
import CoreBluetooth
import BridgeCore
struct PrinterProfile: Codable {
    var identifier: UUID; var service: String; var characteristic: String
    var writePreference: BLEWritePreference? = nil
}
struct DiscoveredPrinter: Codable {
    var identifier: UUID; var name: String; var rssi: Int
}
/// One owner on the main run loop. No persistent connection or fallback device selection.
@MainActor final class BLEPrinter: NSObject,PrinterTransport,@preconcurrency CBCentralManagerDelegate,@preconcurrency CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var disconnecting: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var continuation: CheckedContinuation<Void,Error>?
    private var timeout: DispatchWorkItem?
    private var currentOperation = ""
    private var devices: [UUID:(CBPeripheral,DiscoveredPrinter)] = [:]
    private var pendingServices = 0
    private var candidates: [CBCharacteristic] = []
    private var probing = false
    private var writeMode: CBCharacteristicWriteType = .withResponse
    private var finalWriteAcknowledged = false
    private(set) var observedTransport: [String:String] = [:]
    var profile: PrinterProfile?
    var onChange: (() -> Void)?
    private(set) var status = "Bluetooth not initialized"
    private(set) var scanning = false
    var maximumChunk: Int {
        guard let p = peripheral else { return 0 }
        // The unchanged last chunk uses a request, so it must fit both modes.
        return min(p.maximumWriteValueLength(for:writeMode),p.maximumWriteValueLength(for:.withResponse))
    }
    var stateDescription: String {
        guard central != nil else { return "not initialized" }
        switch central.state {
        case .poweredOn: return "available"
        case .poweredOff: return "disabled"
        case .unauthorized: return "permission denied"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        default: return "initializing"
        }
    }
    private func initialize() {
        if central == nil { central = CBCentralManager(delegate: self,queue: .main,options: [CBCentralManagerOptionShowPowerAlertKey:false]) }
    }
    private func update(_ value: String) { status = value; onChange?() }
    private func wait(seconds: Double = 15,operation: String,start: () -> Void) async throws {
        try Task.checkCancellation()
        guard continuation == nil else { throw BridgeError.invalid("Another BLE operation is active") }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void,Error>) in
                continuation = c; currentOperation = operation
                let task = DispatchWorkItem { [weak self] in self?.finish(.failure(BridgeError.invalid("\(operation) timed out"))) }
                timeout = task; DispatchQueue.main.asyncAfter(deadline: .now() + seconds,execute: task)
                start()
            }
        },onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } })
    }
    private func finish(_ result: Result<Void,Error>) {
        timeout?.cancel(); timeout = nil
        let c = continuation; continuation = nil; currentOperation = ""; c?.resume(with: result)
    }
    private func poweredOn() async throws {
        initialize()
        if central.state == .unknown || central.state == .resetting {
            try await wait(seconds: 10,operation: "Bluetooth availability") {}
        }
        guard central.state == .poweredOn else { throw BridgeError.invalid("Bluetooth \(stateDescription)") }
    }
    func scan() async throws -> [DiscoveredPrinter] {
        guard peripheral == nil else { throw BridgeError.invalid("Release printer before scanning") }
        try await poweredOn(); devices.removeAll(); scanning = true; update("Scanning for 12 seconds")
        central.scanForPeripherals(withServices: nil,options: [CBCentralManagerScanOptionAllowDuplicatesKey:false])
        defer { central.stopScan(); scanning = false; update("Scan finished: \(devices.count) nearby devices") }
        try await Task.sleep(nanoseconds: 12_000_000_000)
        guard central.state == .poweredOn else { throw BridgeError.invalid("Bluetooth \(stateDescription)") }
        return devices.values.map { $0.1 }.sorted { $0.name < $1.name }
    }
    func select(_ identifier: UUID) async throws -> PrinterProfile {
        guard peripheral == nil else { throw BridgeError.invalid("Release printer before changing selection") }
        try await poweredOn(); probing = true; defer { probing = false; releaseLink() }
        guard let device = devices[identifier]?.0 ?? central.retrievePeripherals(withIdentifiers: [identifier]).first else { throw BridgeError.invalid("Selected printer not found; it may be connected elsewhere") }
        try await connect(device)
        guard let c = characteristic, let service = c.service else { throw BridgeError.invalid("Required writable FFF2 characteristic missing") }
        return PrinterProfile(identifier: identifier,service: service.uuid.uuidString,characteristic: c.uuid.uuidString)
    }
    func prepare() async throws {
        guard !scanning else { throw BridgeError.invalid("Printer discovery is active") }
        try await poweredOn()
        if let old = disconnecting {
            if old.state == .disconnected { disconnecting = nil }
            else { try await wait(operation: "Previous link release") {} }
        }
        guard let profile else { throw BridgeError.invalid("Select and verify an ITPP130B first") }
        if let p = peripheral,p.state == .connected,characteristic != nil { return }
        guard let p = central.retrievePeripherals(withIdentifiers: [profile.identifier]).first else {
            throw BridgeError.invalid("Selected printer not found; it may be powered off or connected elsewhere")
        }
        try await connect(p)
    }
    private func connect(_ p: CBPeripheral) async throws {
        peripheral = p; p.delegate = self; characteristic = nil; finalWriteAcknowledged = false
        update("Connecting to selected printer")
        do {
            try await wait(operation: "Printer connection") { central.connect(p,options: nil) }
            try await wait(operation: "Service/characteristic discovery") {
                p.discoverServices(probing ? nil : profile.map { [CBUUID(string:$0.service)] })
            }
            update("Connected (no print acknowledgement)")
        } catch { releaseLink(); throw error }
    }
    func waitUntilReady() async throws {
        guard let p = peripheral,p.state == .connected,characteristic != nil else { throw BridgeError.invalid("Printer disconnected") }
        if writeMode == .withoutResponse && !p.canSendWriteWithoutResponse {
            try await wait(operation:"Bluetooth write readiness") {
                if p.canSendWriteWithoutResponse { finish(.success(())) }
            }
        }
    }
    func write(_ data: Data) async throws {
        try Task.checkCancellation()
        guard let p = peripheral,p.state == .connected,let c = characteristic,data.count <= maximumChunk else { throw BridgeError.invalid("BLE link unavailable or invalid chunk") }
        finalWriteAcknowledged = false
        if writeMode == .withResponse {
            try await wait(operation: "Bluetooth write response") { p.writeValue(data,for: c,type: .withResponse) }
        } else {
            guard p.canSendWriteWithoutResponse else { throw BridgeError.invalid("Bluetooth backpressure changed") }
            p.writeValue(data,for: c,type: .withoutResponse)
        }
    }
    func writeFinal(_ data: Data) async throws {
        try Task.checkCancellation()
        guard let p = peripheral,p.state == .connected,let c = characteristic,
              c.properties.contains(.write),!data.isEmpty,data.count <= maximumChunk else {
            throw BridgeError.invalid("Final data chunk requires a connected response-capable characteristic")
        }
        finalWriteAcknowledged = false
        try await wait(operation:"Bluetooth write response") { p.writeValue(data,for:c,type:.withResponse) }
        try Task.checkCancellation()
        guard p === peripheral,p.state == .connected else { throw BridgeError.invalid("Disconnected during final write acknowledgement") }
        finalWriteAcknowledged = true
    }
    func finishTransmission() async throws {
        guard finalWriteAcknowledged else { throw BridgeError.invalid("Final data chunk was not acknowledged; delivery is uncertain") }
        if writeMode == .withoutResponse {
            try await waitUntilReady()
            // Keep the empirically tested settling interval after the final GATT
            // response. Neither the response nor readiness acknowledges paper output.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await waitUntilReady()
        }
        try Task.checkCancellation()
        guard peripheral?.state == .connected else { throw BridgeError.invalid("Disconnected before transmission settled") }
    }
    func releaseLink() {
        finish(.failure(CancellationError()))
        if central != nil { central.stopScan() }
        scanning = false
        if let p = peripheral { disconnecting = p; central?.cancelPeripheralConnection(p) }
        peripheral = nil; characteristic = nil; finalWriteAcknowledged = false; update("Release requested; no idle reconnect")
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        update("Bluetooth \(stateDescription)")
        if currentOperation == "Bluetooth availability" {
            if central.state == .poweredOn { finish(.success(())) }
            else if central.state != .unknown && central.state != .resetting { finish(.failure(BridgeError.invalid("Bluetooth \(stateDescription)"))) }
        } else if central.state != .poweredOn { finish(.failure(BridgeError.invalid("Bluetooth \(stateDescription)"))) }
    }
    func centralManager(_ central: CBCentralManager,didDiscover p: CBPeripheral,advertisementData: [String:Any],rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "Unnamed device"
        devices[p.identifier] = (p,.init(identifier:p.identifier,name:name,rssi:RSSI.intValue))
    }
    func centralManager(_ central: CBCentralManager,didConnect p: CBPeripheral) {
        guard p === peripheral else { central.cancelPeripheralConnection(p); return }
        if currentOperation == "Printer connection" { finish(.success(())) }
    }
    func centralManager(_ central: CBCentralManager,didFailToConnect p: CBPeripheral,error: Error?) {
        guard p === peripheral else { return }
        finish(.failure(BridgeError.invalid("Printer connection failed; it may be connected elsewhere")))
    }
    func centralManager(_ central: CBCentralManager,didDisconnectPeripheral p: CBPeripheral,error: Error?) {
        if p === disconnecting {
            disconnecting = nil
            if currentOperation == "Previous link release" { finish(.success(())) }
            update("Link released; phone may connect"); return
        }
        guard p === peripheral else { return }
        characteristic = nil; update("Selected printer disconnected")
        finish(.failure(BridgeError.invalid("Printer disconnected")))
    }
    func peripheral(_ p: CBPeripheral,didDiscoverServices error: Error?) {
        guard p === peripheral else { return }
        guard error == nil,let services = p.services,!services.isEmpty else { finish(.failure(BridgeError.invalid("Required printer service missing"))); return }
        candidates = []; pendingServices = services.count
        for service in services { p.discoverCharacteristics(nil,for: service) }
    }
    func peripheral(_ p: CBPeripheral,didDiscoverCharacteristicsFor service: CBService,error: Error?) {
        guard p === peripheral,currentOperation == "Service/characteristic discovery" else { return }
        guard error == nil else { finish(.failure(BridgeError.invalid("Characteristic discovery failed"))); return }
        for c in service.characteristics ?? [] {
            let expected = probing ? CBUUID(string:"FFF2") : CBUUID(string: profile!.characteristic)
            if c.uuid == expected && (c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)) { candidates.append(c) }
        }
        pendingServices -= 1
        if pendingServices == 0 {
            guard candidates.count == 1 else { finish(.failure(BridgeError.invalid("Exactly one verified writable FFF2 characteristic required"))); return }
            characteristic = candidates[0]
            do {
                let preference = try BLEWritePreference.choose(preferred: probing ? nil : profile?.writePreference,
                    withResponse:candidates[0].properties.contains(.write),
                    withoutResponse:candidates[0].properties.contains(.writeWithoutResponse))
                writeMode = preference == .withResponse ? .withResponse : .withoutResponse
            } catch { finish(.failure(error)); return }
            observedTransport = ["service":service.uuid.uuidString,"characteristic":candidates[0].uuid.uuidString,
                "properties":String(candidates[0].properties.rawValue),"writeMode":writeMode == .withResponse ? "with-response" : "without-response",
                "maximumWriteValueLength":String(p.maximumWriteValueLength(for:writeMode)),
                "maximumWithResponse":String(p.maximumWriteValueLength(for:.withResponse)),
                "maximumWithoutResponse":String(p.maximumWriteValueLength(for:.withoutResponse)),
                "finalWriteMode":"with-response"]
            finish(.success(()))
        }
    }
    func peripheral(_ p: CBPeripheral,didWriteValueFor c: CBCharacteristic,error: Error?) {
        guard p === peripheral,c === characteristic,currentOperation == "Bluetooth write response" else { return }
        if error != nil { finish(.failure(BridgeError.invalid("Bluetooth write failed"))) } else { finish(.success(())) }
    }
    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        if p === peripheral,currentOperation == "Bluetooth write readiness" { finish(.success(())) }
    }
    func peripheral(_ p: CBPeripheral,didModifyServices invalidatedServices: [CBService]) {
        if p === peripheral { characteristic = nil; finish(.failure(BridgeError.invalid("Printer services changed; select/verify again"))) }
    }
}
