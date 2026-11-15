// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ResonanceKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecognitionCore", targets: ["RecognitionCore"]),
        .library(name: "RecognitionTestSupport", targets: ["RecognitionTestSupport"]),
    ],
    targets: [
        .target(name: "RecognitionCore"),
        .target(
            name: "RecognitionTestSupport",
            dependencies: ["RecognitionCore"],
            path: "Tests/RecognitionTestSupport"
        ),
        .testTarget(
            name: "RecognitionCoreTests",
            dependencies: ["RecognitionCore", "RecognitionTestSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
