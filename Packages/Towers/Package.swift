// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Towers",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Towers", targets: ["Towers"]),
    ],
    targets: [
        .target(name: "Towers"),
        .testTarget(name: "TowersTests", dependencies: ["Towers"]),
    ]
)
