// swift-tools-version: 6.2
import PackageDescription

// Separate test consumer: keep DEBUG-only neighboring tests out of optimized probes.
// The library under test remains the existing production OpenClawKit package.
let package = Package(
    name: "DiagnosticRecorderProbe",
    platforms: [.iOS(.v18), .macOS(.v15)],
    dependencies: [.package(path: "../../../shared/OpenClawKit")],
    targets: [
        .testTarget(
            name: "DiagnosticRecorderProbeTests",
            dependencies: [.product(name: "OpenClawKit", package: "OpenClawKit")],
            path: "Tests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableExperimentalFeature("SwiftTesting"),
            ]),
    ])
