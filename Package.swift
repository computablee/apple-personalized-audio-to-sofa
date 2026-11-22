// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HRTFToSOFA",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HRTFKit", targets: ["HRTFKit"]),
        .executable(name: "hrtf2sofa", targets: ["hrtf2sofa"]),
        .executable(name: "HRTFToSOFA", targets: ["HRTFToSOFA"]),
    ],
    targets: [
        // DSP/analysis is far too slow unoptimized; optimize it even in debug builds.
        .target(name: "HRTFKit", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .target(name: "HRTFViz", dependencies: ["HRTFKit"]),
        .executableTarget(name: "hrtf2sofa", dependencies: ["HRTFKit", "HRTFViz"]),
        .executableTarget(name: "HRTFToSOFA", dependencies: ["HRTFKit", "HRTFViz"]),
    ]
)
