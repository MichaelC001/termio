// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "termio",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Prebuilt libghostty (Ghostty's terminal core) packaged for Apple platforms.
        // Ships a GhosttyKit.xcframework binary target, so no zig toolchain is needed.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "termio",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                // Bundled color-scheme catalog (Ghostty's built-in themes), used by
                // the appearance settings to offer a theme picker.
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
            ],
            path: "Sources/termio",
            resources: [
                // Vendor favicons rendered as agent brand marks; see BrandImageAsset.
                .process("Resources"),
            ],
            swiftSettings: [
                // Relax strict concurrency for the AppKit/SwiftUI glue; the app is
                // single-window and main-actor bound in practice.
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
