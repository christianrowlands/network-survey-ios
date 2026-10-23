// swift-tools-version: 6.0
import PackageDescription

// Local servers for the end-to-end survey test (scripts/e2e.sh): a mosquitto
// broker with a subscriber, an NS Messaging gRPC server and an NS Analytics
// stub, all counting what the app sends. Pins match Packages/Destinations.
let package = Package(
    name: "E2EHarness",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "e2e-harness", targets: ["e2e-harness"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.11.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        .executableTarget(
            name: "e2e-harness",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2TransportServices", package: "grpc-swift-nio-transport"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
    ]
)
