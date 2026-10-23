// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BoardProtocol",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "BoardProtocol", targets: ["BoardProtocol"]),
    ],
    dependencies: [
        // scripts/sync-proto.sh builds protoc-gen-swift from this same pin.
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0"),
    ],
    targets: [
        .target(
            name: "BoardProtocol",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .testTarget(
            name: "BoardProtocolTests",
            dependencies: ["BoardProtocol"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
