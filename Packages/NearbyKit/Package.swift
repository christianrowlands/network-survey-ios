// swift-tools-version: 6.0
import PackageDescription

// Nearby Bluetooth: what this iPhone's own radio hears. Deliberately has no
// dependency on SurveyCore, NSMessaging or Destinations, so nothing it hears can
// reach a survey, a file, NS Analytics, MQTT or gRPC.
let package = Package(
    name: "NearbyKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "NearbyKit", targets: ["NearbyKit"]),
    ],
    targets: [
        .target(name: "NearbyKit"),
        .testTarget(name: "NearbyKitTests", dependencies: ["NearbyKit"]),
    ]
)
