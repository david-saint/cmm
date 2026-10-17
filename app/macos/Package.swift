// swift-tools-version: 6.0
import PackageDescription

// cmm for macOS: a thin SwiftUI client for the cmm engine (the Go program in the repository root).
// CmmKit holds everything that is not drawing (models, the process client, the view models) so it can be tested
// without a window; Cmm is only the SwiftUI app. No third-party dependencies.
let package = Package(
    name: "CmmApp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmmKit", targets: ["CmmKit"]),
        .executable(name: "Cmm", targets: ["Cmm"]),
    ],
    targets: [
        .target(name: "CmmKit"),
        .executableTarget(name: "Cmm", dependencies: ["CmmKit"]),
        .testTarget(
            name: "CmmKitTests",
            // "Cmm" is here so the window's views can be rendered and checked (see AppViewsTests).
            dependencies: ["CmmKit", "Cmm"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
