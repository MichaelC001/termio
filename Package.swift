// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "termio",
    platforms: [.macOS(.v14)],
    dependencies: [
        // libghostty (Ghostty's terminal core) for the macOS app via Lakr233's
        // upstream github.com/Lakr233/libghostty-spm. It ships a prebuilt
        // GhosttyKit.xcframework binary target plus the `GhosttyTerminal` Swift
        // wrapper (including the host-managed `.inMemory` backend PTYProcess drives),
        // so there is no zig toolchain here. The Mac app tracks upstream directly
        // rather than a fork; the iOS app keeps using our own fork (which carries the
        // iOS-specific patches) via ios/. See project_termio_libghostty_swift.
        .package(url: "https://github.com/Lakr233/libghostty-spm", from: "1.2.9"),
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
        // swift-markdown — Apple's cmark-gfm wrapper (the parser behind DocC). Parses
        // agent messages for the session trace; `TraceMarkdown` walks the AST and emits
        // escaped HTML. Apache-2.0.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
        // Code shared with the iOS companion app — the companion wire protocol
        // (roster + control messages) lives here so both ends stay in sync.
        .package(path: "Shared"),
    ],
    targets: [
        .executableTarget(
            name: "termio",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                // The raw libghostty C API. Used by session control to deliver a real
                // Return key event (`ghostty_surface_key`) when driving a sibling.
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                // Bundled color-scheme catalog (Ghostty's built-in themes), used by
                // the appearance settings to offer a theme picker.
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "TermioShared", package: "Shared"),
            ],
            path: "Sources/termio",
            resources: [
                // Vendor favicons rendered as agent brand marks; see BrandImageAsset.
                .process("Resources"),
                // Devicon language/tool logos (one SVG per file type), loaded by name
                // for the file tree; see LangIconCatalog / LangIconView. Kept as a
                // folder copy (not `.process`) so the lookup subdirectory survives.
                .copy("LangIcons"),
            ],
            swiftSettings: [
                // Relax strict concurrency for the AppKit/SwiftUI glue; the app is
                // single-window and main-actor bound in practice.
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
