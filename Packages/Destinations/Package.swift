// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Destinations",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Destinations", targets: ["Destinations"]),
    ],
    dependencies: [
        .package(path: "../BoardProtocol"),
        .package(path: "../NSMessaging"),
        // Exact pins. scripts/gen-ns-messaging-grpc.sh builds the code
        // generators from these same versions.
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.5.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.11.0"),
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", exact: "2.13.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        // Already required by the packages above; listed for their modules.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.20.0"),
    ],
    targets: [
        .target(
            name: "Destinations",
            dependencies: [
                .product(name: "BoardProtocol", package: "BoardProtocol"),
                .product(name: "NSMessaging", package: "NSMessaging"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                // Network.framework transport only: no BoringSSL in the app.
                .product(name: "GRPCNIOTransportHTTP2TransportServices", package: "grpc-swift-nio-transport"),
                .product(name: "MQTTNIO", package: "mqtt-nio"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ]
        ),
        .testTarget(
            name: "DestinationsTests",
            dependencies: [
                "Destinations",
                .product(name: "MQTTNIO", package: "mqtt-nio"),
                .product(name: "GRPCNIOTransportHTTP2TransportServices", package: "grpc-swift-nio-transport"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
