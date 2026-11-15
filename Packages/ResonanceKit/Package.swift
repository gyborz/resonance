// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ResonanceKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecognitionCore", targets: ["RecognitionCore"]),
        .library(name: "SystemAudioCapture", targets: ["SystemAudioCapture"]),
        .library(name: "RecognitionTestSupport", targets: ["RecognitionTestSupport"]),
        .library(name: "ShazamRecognition", targets: ["ShazamRecognition"]),
        .library(name: "ShazamFixtureSupport", targets: ["ShazamFixtureSupport"]),
    ],
    targets: [
        .target(name: "RecognitionCore"),
        .target(name: "CaptureRing"),
        .target(name: "SystemAudioCapture", dependencies: ["RecognitionCore", "CaptureRing"]),
        .testTarget(name: "SystemAudioCaptureTests", dependencies: ["SystemAudioCapture", "RecognitionCore"]),
        .target(name: "ShazamRecognition", dependencies: ["RecognitionCore"]),
        .target(
            name: "ShazamFixtureSupport",
            dependencies: ["RecognitionCore"],
            path: "Tests/ShazamFixtureSupport"
        ),
        .testTarget(
            name: "ShazamRecognitionTests",
            dependencies: ["RecognitionCore", "ShazamRecognition", "ShazamFixtureSupport"]
        ),
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
