// swift-tools-version: 6.0
import PackageDescription

// termio-sandbox is built as its own package so it can require macOS 15 (what
// Apple's Containerization needs) without forcing that minimum onto the main termio
// app, which still targets macOS 14. `scripts/build-app.sh` builds this package
// separately, codesigns the binary with the virtualization entitlement, and bundles
// it into termio.app. The sandbox feature itself only runs on macOS 26 at runtime
// (gated app-side), but 15 is the floor the framework will compile against.
let package = Package(
    name: "termio-sandbox",
    // The sandbox runtime (VmnetNetwork, the VM APIs) is macOS 26+. This is a separate
    // package from the app, so requiring 26 here does not raise the app's own floor.
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: "0.33.4"),
    ],
    targets: [
        .executableTarget(
            name: "termio-sandbox",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
            ]
        ),
    ]
)
