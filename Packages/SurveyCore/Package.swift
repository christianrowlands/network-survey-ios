// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SurveyCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SurveyCore", targets: ["SurveyCore"]),
    ],
    dependencies: [
        .package(path: "../BoardProtocol"),
        .package(path: "../BoardKit"),
        .package(path: "../NSMessaging"),
        .package(path: "../Destinations"),
        .package(path: "../Towers"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "SurveyCore",
            dependencies: [
                .product(name: "BoardProtocol", package: "BoardProtocol"),
                .product(name: "BoardKit", package: "BoardKit"),
                .product(name: "NSMessaging", package: "NSMessaging"),
                .product(name: "Destinations", package: "Destinations"),
                .product(name: "Towers", package: "Towers"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "SurveyCoreTests", dependencies: ["SurveyCore"]),
    ]
)
