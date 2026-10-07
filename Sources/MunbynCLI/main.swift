import Foundation
import BridgeCore
let args = Array(CommandLine.arguments.dropFirst())
let help = """
munbyn-bridge COMMAND [VALUE] [--confirm]
Commands contact the running app; this CLI never owns a BLE connection.
  doctor, status, scan
  select SCAN-UUID     Explicitly choose your physical ITPP130B
  connect, release
  test-print [mm100x150|inch4x6]   Consumes one label unless dry run is enabled
  install-queue, uninstall-queue --confirm
  cancel JOB-UUID, retry JOB-UUID
  confirm-recovery JOB-UUID --confirm  Inspect paper and power-cycle first
  reprint JOB-UUID --confirm     Duplicate risk; requires buffer recovery
  delete JOB-UUID --confirm
  dry-run on|off --confirm       Sensitive local captures
  clear-captures --confirm       Ordinary deletion of sensitive captures
  pacing CHUNK,DELAY_SECONDS     Bounded per-run pacing, no automatic tuning
  write-mode with-response|without-response  Selected-printer setting; calibrate on paper
  login on|off, quit [--confirm]
Offline validation: raster-info PATH, capture PATH OUTPUT-DIRECTORY
Capture never accesses Bluetooth; output is sensitive and private.
"""
do {
    guard let command = args.first else { print(help); exit(0) }
    if command == "raster-info" || command == "capture" {
        guard args.count >= 2 else { throw BridgeError.invalid("Raster path required") }
        let fd = open(args[1],O_RDONLY); guard fd >= 0 else { throw BridgeError.invalid("Cannot open raster") }; defer { close(fd) }
        let pages = try RasterReader.read(fd:fd)
        print("Validated \(pages.count) labels")
        for (index,page) in pages.enumerated() { print("\(index+1): \(page.width)x\(page.height), \(page.media.rawValue), \(page.black.count) bitmap bytes") }
        if command == "capture" {
            guard args.count == 3 else { throw BridgeError.invalid("Private output directory required") }
            let directory = URL(fileURLWithPath:args[2]); try PrivateFiles.directory(directory)
            for (index,page) in pages.enumerated() {
                try PrivateFiles.write(page.pbm,to:directory.appendingPathComponent("page-\(index+1).pbm"))
                try PrivateFiles.write(TSPL.encode(page:page),to:directory.appendingPathComponent("page-\(index+1).tspl"))
            }
            print("Sensitive captures written locally; no Bluetooth access")
        }
    } else {
        if command == "help" || command == "--help" { print(help); exit(0) }
        let value = args.dropFirst().first(where: { !$0.hasPrefix("--") })
        let request = ControlRequest(command:command,value:value,confirm:args.contains("--confirm"))
        let reply = try ControlWire.request(path:Paths.control,data:JSONEncoder().encode(request))
        print(String(decoding:reply,as:UTF8.self))
        if let object = try? JSONSerialization.jsonObject(with:reply) as? [String:Any],object["error"] != nil { exit(1) }
    }
} catch { fputs("\(error)\n",stderr); exit(1) }
