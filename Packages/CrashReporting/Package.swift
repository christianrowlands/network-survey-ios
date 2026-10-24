// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrashReporting",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CrashReporting", targets: ["CrashReporting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.31.0"),
    ],
    targets: [
        .target(
            name: "CrashReporting",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa"),
            ]
        ),
        .testTarget(name: "CrashReportingTests", dependencies: ["CrashReporting"]),
    ]
)
