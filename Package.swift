// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YapSketch",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "YapSketch",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/YapSketch",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
                .linkedFramework("Carbon"),
                // Sparkle.framework is embedded in YapSketch.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
