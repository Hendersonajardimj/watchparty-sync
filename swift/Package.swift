// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "WatchPartySync",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SyncCore", targets: ["SyncCore"]), .executable(name: "sync-demo", targets: ["SyncDemo"])],
    targets: [.target(name: "SyncCore"), .executableTarget(name: "SyncDemo", dependencies: ["SyncCore"]), .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"])])
