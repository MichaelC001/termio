// swift-tools-version: 5.9

// TermioShared: code both the macOS app and the iOS companion compile —
// brand vectors, status semantics, and (soon) the companion wire protocol.
// Keep this package UI-framework-light: SwiftUI is fine, AppKit/UIKit only
// behind canImport conditionals.

import PackageDescription

let package = Package(
    name: "TermioShared",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "TermioShared", targets: ["TermioShared"]),
        // The iOS SSH client engine (Apple swift-nio-ssh). Only the iOS app
        // links it; the macOS app resolves but never builds or links it, so
        // no SSH stack enters the desktop binary.
        .library(name: "TermioSSH", targets: ["TermioSSH"]),
    ],
    dependencies: [
        // Highlightr — the same highlight.js wrapper the macOS editor uses;
        // shared here so the iOS file viewer colors code identically.
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.3.0"),
        // Apple's first-party SSH — no third-party fork, no macOS-min bump
        // (nio-ssh targets macOS 10.15 / iOS 13). Powers TermioSSH only.
        .package(url: "https://github.com/apple/swift-nio-ssh.git", "0.13.0" ..< "0.14.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "TermioShared", dependencies: [
            .product(name: "Highlightr", package: "Highlightr"),
        ]),
        .target(name: "TermioSSH", dependencies: [
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
    ]
)
