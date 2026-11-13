// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoodTakeKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "GoodTakeCore", targets: ["GoodTakeCore"]),
        .library(name: "GoodTakeVision", targets: ["GoodTakeVision"]),
        .library(name: "GoodTakePhotoKit", targets: ["GoodTakePhotoKit"]),
        .library(name: "GoodTakeUI", targets: ["GoodTakeUI"]),
        .executable(name: "gtscan", targets: ["gtscan"]),
    ],
    targets: [
        // Pure engine: models, grouping, scoring, cache, scanner. No Vision or PhotoKit.
        .target(name: "GoodTakeCore"),
        // On-device analysis with Apple's Vision framework.
        .target(name: "GoodTakeVision", dependencies: ["GoodTakeCore"]),
        // The real photo library.
        .target(name: "GoodTakePhotoKit", dependencies: ["GoodTakeCore"]),
        // A folder of image files as a photo library. Used by gtscan and the tests, never by the app.
        .target(name: "GoodTakeFolderSource", dependencies: ["GoodTakeCore"]),
        // Synthetic scenes for tests and demos.
        .target(name: "GoodTakeTestSupport", dependencies: ["GoodTakeCore"]),
        .target(name: "GoodTakeUI", dependencies: ["GoodTakeCore"]),
        .executableTarget(
            name: "gtscan",
            dependencies: ["GoodTakeCore", "GoodTakeVision", "GoodTakeFolderSource", "GoodTakeTestSupport"]
        ),
        .testTarget(name: "GoodTakeCoreTests", dependencies: ["GoodTakeCore"]),
        .testTarget(name: "GoodTakeVisionTests", dependencies: ["GoodTakeCore", "GoodTakeVision", "GoodTakeTestSupport"]),
        .testTarget(
            name: "GoodTakeScanTests",
            dependencies: ["GoodTakeCore", "GoodTakeVision", "GoodTakeFolderSource", "GoodTakeTestSupport", "GoodTakeUI"]
        ),
    ]
)
