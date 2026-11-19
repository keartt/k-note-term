// swift-tools-version:5.9
import PackageDescription

// 터미널 = libghostty (vendor/ghostty 소스로 빌드한 GhosttyKit.xcframework, ./build.sh 참고)
let package = Package(
    name: "KNoteTerm",
    platforms: [.macOS(.v13)],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "vendor/ghostty/macos/GhosttyKit.xcframework"),
        .executableTarget(
            name: "KNoteTerm",
            dependencies: ["GhosttyKit"],
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreText"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("WebKit"),
                .unsafeFlags(["-Xlinker", "-dead_strip"]),
            ]
        ),
    ]
)
