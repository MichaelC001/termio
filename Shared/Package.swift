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
        .library(name: "TermioSSH", targets: ["TermioSSH"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", "0.13.0" ..< "0.14.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "TermioShared"),
        .target(name: "TermioSSH", dependencies: [
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
    ]
)
