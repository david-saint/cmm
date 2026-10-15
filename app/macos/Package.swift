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
    ],
    targets: [
        .target(name: "CmmKit"),
        .testTarget(
            name: "CmmKitTests",
            dependencies: ["CmmKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
