// swift-tools-version: 5.9

// The termio companion server: runs on the Mac, owns a PTY with an agent/shell
// in it, and serves that PTY over a WebSocket so the iOS app can drive it. v1
// binds ws://localhost for the local PoC; production fronts it with a tunnel
// (`tunelo port <n>`).

import PackageDescription

let package = Package(
    name: "TermioCompanion",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../Shared"),
    ],
    targets: [
        .executableTarget(
            name: "termio-companion",
            dependencies: [
                .product(name: "TermioShared", package: "Shared"),
            ]
        ),
    ]
)
