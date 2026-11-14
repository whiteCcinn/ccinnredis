// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CcinnRedis",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RESPWire", targets: ["RESPWire"]),
        .library(name: "RedisKit", targets: ["RedisKit"]),
        .library(name: "CcinnRedisKit", targets: ["CcinnRedisKit"]),
        .executable(name: "CcinnRedis", targets: ["CcinnRedis"]),
    ],
    targets: [
        // RESP2/RESP3 value model, incremental bounded parser and command encoder. No I/O.
        .target(name: "RESPWire", swiftSettings: settings),
        // Transport, connections, pools, handshake, capabilities, cluster/sentinel/proxy routing, typed APIs.
        .target(name: "RedisKit", dependencies: ["RESPWire"], swiftSettings: settings),
        // UI-independent app logic: profiles, key tree, console, completion, analysis, export.
        .target(name: "CcinnRedisKit", dependencies: ["RESPWire", "RedisKit"], swiftSettings: settings),
        // SwiftUI/AppKit application.
        .executableTarget(name: "CcinnRedis", dependencies: ["RESPWire", "RedisKit", "CcinnRedisKit"], swiftSettings: settings),

        .testTarget(name: "RESPWireTests", dependencies: ["RESPWire"], swiftSettings: settings),
        .testTarget(name: "RedisKitTests", dependencies: ["RESPWire", "RedisKit"], swiftSettings: settings),
        .testTarget(name: "CcinnRedisKitTests", dependencies: ["RESPWire", "RedisKit", "CcinnRedisKit"], swiftSettings: settings),
        .testTarget(name: "IntegrationTests", dependencies: ["RESPWire", "RedisKit", "CcinnRedisKit"], swiftSettings: settings),
    ],
    swiftLanguageModes: [.v6]
)
