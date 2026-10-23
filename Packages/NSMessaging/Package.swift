// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NSMessaging",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "NSMessaging", targets: ["NSMessaging"]),
    ],
    dependencies: [
        .package(path: "../BoardProtocol"),
    ],
    targets: [
        .target(
            name: "NSMessaging",
            dependencies: [.product(name: "BoardProtocol", package: "BoardProtocol")]
        ),
        .testTarget(
            name: "NSMessagingTests",
            dependencies: ["NSMessaging"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
