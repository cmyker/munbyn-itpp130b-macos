// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MUNBYNITPP130BBridge", platforms: [.macOS(.v13)],
    products: [.library(name: "BridgeCore", targets: ["BridgeCore"]),
               .executable(name: "MunbynBridge", targets: ["MunbynBridge"]),
               .executable(name: "munbyn-bridge", targets: ["MunbynCLI"])],
    targets: [.target(name: "CBridge", linkerSettings: [.linkedLibrary("cups"), .linkedFramework("Security")]),
              .target(name: "BridgeCore", dependencies: ["CBridge"]),
              .executableTarget(name: "MunbynBridge", dependencies: ["BridgeCore"]),
              .executableTarget(name: "MunbynCLI", dependencies: ["BridgeCore"]),
              .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore", "CBridge"]),
              .testTarget(name: "MunbynUITests", dependencies: ["MunbynBridge", "BridgeCore"])])
