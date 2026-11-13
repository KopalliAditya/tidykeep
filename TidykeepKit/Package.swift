// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TidykeepKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "TidykeepCore", targets: ["TidykeepCore"]),
        .library(name: "TidykeepVision", targets: ["TidykeepVision"]),
        .library(name: "TidykeepPhotoKit", targets: ["TidykeepPhotoKit"]),
        .library(name: "TidykeepUI", targets: ["TidykeepUI"]),
        .executable(name: "tkscan", targets: ["tkscan"]),
    ],
    targets: [
        // Pure engine: models, grouping, scoring, cache, scanner. No Vision or PhotoKit.
        .target(name: "TidykeepCore"),
        // On-device analysis with Apple's Vision framework and the bundled DINOv2-small model.
        // The model ships compiled (.mlmodelc), so it is copied as is: compiling an .mlpackage
        // here would need Xcode's model compiler. Its Apache-2.0 license and notice ship with it.
        .target(
            name: "TidykeepVision",
            dependencies: ["TidykeepCore"],
            resources: [
                .copy("Resources/DINOv2Small.mlmodelc"),
                .copy("Resources/DINOv2-LICENSE.txt"),
                .copy("Resources/DINOv2-NOTICE.txt"),
            ]
        ),
        // The real photo library.
        .target(name: "TidykeepPhotoKit", dependencies: ["TidykeepCore"]),
        // A folder of image files as a photo library. Used by tkscan and the tests, never by the app.
        .target(name: "TidykeepFolderSource", dependencies: ["TidykeepCore"]),
        // Synthetic scenes for tests and demos.
        .target(name: "TidykeepTestSupport", dependencies: ["TidykeepCore"]),
        .target(name: "TidykeepUI", dependencies: ["TidykeepCore"]),
        .executableTarget(
            name: "tkscan",
            dependencies: ["TidykeepCore", "TidykeepVision", "TidykeepFolderSource", "TidykeepTestSupport"]
        ),
        .testTarget(name: "TidykeepCoreTests", dependencies: ["TidykeepCore"]),
        .testTarget(name: "TidykeepVisionTests", dependencies: ["TidykeepCore", "TidykeepVision", "TidykeepTestSupport"]),
        .testTarget(
            name: "TidykeepScanTests",
            dependencies: ["TidykeepCore", "TidykeepVision", "TidykeepFolderSource", "TidykeepTestSupport", "TidykeepUI"]
        ),
    ]
)
