// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BoardKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "BoardKit", targets: ["BoardKit"]),
    ],
    dependencies: [
        .package(path: "../BoardProtocol"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0"),
    ],
    targets: [
        .target(
            name: "BoardKit",
            dependencies: [
                .product(name: "BoardProtocol", package: "BoardProtocol"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "BoardKitTests",
            dependencies: ["BoardKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
