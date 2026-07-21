// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoxHalo",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "VoxHaloKit", targets: ["VoxHaloKit"]),
        .executable(name: "VoxHalo", targets: ["VoxHaloApp"])
    ],
    targets: [
        .target(
            name: "VoxHaloRealtimeAudio",
            path: "Sources/VoxHaloRealtimeAudio",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .target(
            name: "VoxHaloKit",
            dependencies: ["VoxHaloRealtimeAudio"],
            path: "Sources/VoxHaloKit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText")
            ]
        ),
        .executableTarget(
            name: "VoxHaloApp",
            dependencies: ["VoxHaloKit"],
            path: "Sources/VoxHaloApp"
        ),
        .testTarget(
            name: "VoxHaloKitTests",
            dependencies: ["VoxHaloKit"],
            path: "Tests/VoxHaloKitTests",
            linkerSettings: [.linkedFramework("Network")]
        )
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
