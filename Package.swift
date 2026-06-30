// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "termio",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Prebuilt libghostty (Ghostty's terminal core) packaged for Apple platforms.
        // Ships a GhosttyKit.xcframework binary target, so no zig toolchain is needed.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.2.0"),
        // Sparkle powers in-app auto-update (the "Check for Updates…" menu item and
        // background update checks). It reads the appcast published with each GitHub
        // release; the matching EdDSA public key is embedded in packaging/Info.plist.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        // Highlightr — a small highlight.js wrapper that syntax-highlights an
        // `NSTextStorage` (`CodeAttributedString`). It powers the file editor that covers
        // the terminal: a plain native `NSTextView` with 180+ languages and built-in
        // themes, and it builds with plain `swift build` (its resources are declared, so
        // no vendoring or Xcode-only steps).
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "termio",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                // The raw libghostty C API. Used by session control to deliver a real
                // Return key event (`ghostty_surface_key`) when driving a sibling — the
                // Swift wrapper for it is `internal`, but the C symbol is public.
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                // Bundled color-scheme catalog (Ghostty's built-in themes), used by
                // the appearance settings to offer a theme picker.
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Highlightr", package: "Highlightr"),
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
