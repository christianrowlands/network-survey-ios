// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Command line tool for testing boards from a Mac, over Bluetooth or against
// simulated boards. The embedded Info.plist carries the Bluetooth usage string
// macOS asks for (the permission prompt is attributed to the terminal app).
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path

let package = Package(
    name: "BoardCLI",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "boardcli", targets: ["boardcli"]),
    ],
    dependencies: [
        .package(path: "../../Packages/BoardKit"),
        .package(path: "../../Packages/BoardProtocol"),
    ],
    targets: [
        .executableTarget(
            name: "boardcli",
            dependencies: [
                .product(name: "BoardKit", package: "BoardKit"),
                .product(name: "BoardProtocol", package: "BoardProtocol"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        ),
    ]
)
