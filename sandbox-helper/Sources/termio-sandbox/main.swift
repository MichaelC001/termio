//===----------------------------------------------------------------------===//
// termio-sandbox — the entitled helper that runs a project's sessions inside ONE
// shared Linux micro-VM (per project, not per session).
//
// Two modes:
//   serve  — a daemon (one per VM-project). Boots the container once, optionally
//            installs the agent CLIs into it, keeps it alive (init = sleep infinity),
//            and listens on a unix socket. termio.app spawns one of these when a
//            project is opened in a VM, and tears it down when the project closes.
//   attach — one per terminal session. libghostty's PTY runs this; it connects to
//            the project's serve socket, and the daemon `exec`s the session's command
//            inside the shared container, bridging this PTY's bytes over the socket.
//
// So every session of a project shares the same container: install once, all
// sessions see it. Adapted from Apple's ctr-example/sandboxy (apple/containerization,
// Apache-2.0).
//===----------------------------------------------------------------------===//

import Containerization
import ContainerizationOS
import Foundation
import Darwin

// MARK: - Wire format

/// The header an `attach` client sends first, one JSON line terminated by `\n`,
/// before the socket carries raw PTY bytes.
struct AttachHeader: Codable {
    var cols: UInt16
    var rows: UInt16
    var command: [String]
}

// MARK: - Byte pump

/// Copies bytes from `src` to `dst` until EOF/error, on the calling thread. Used to
/// bridge a PTY master and a socket in each direction.
private func pump(from src: Int32, to dst: Int32) {
    let capacity = 64 * 1024
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
    defer { buffer.deallocate() }
    while true {
        let n = read(src, buffer, capacity)
        if n <= 0 { break }
        var offset = 0
        while offset < n {
            let w = write(dst, buffer + offset, n - offset)
            if w <= 0 { return }
            offset += w
        }
    }
}

private func spawnPump(from src: Int32, to dst: Int32) {
    let thread = Thread { pump(from: src, to: dst) }
    thread.stackSize = 1 << 20
    thread.start()
}

// MARK: - Unix sockets

private func makeUnixSocket() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EINVAL) }
    return fd
}

private func fillSunPath(_ addr: inout sockaddr_un, _ path: String) {
    addr.sun_family = sa_family_t(AF_UNIX)
    // Capacity must be read before taking exclusive access to sun_path below;
    // reading it inside the closure overlaps with the mutable borrow (an
    // exclusivity violation), so hoist it to a local first.
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
            path.withCString { src in _ = strncpy(dst, src, capacity - 1) }
        }
    }
}

private func unixListen(_ path: String) throws -> Int32 {
    unlink(path)
    let fd = try makeUnixSocket()
    var addr = sockaddr_un()
    fillSunPath(&addr, path)
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
    }
    guard bound == 0 else { close(fd); throw POSIXError(.init(rawValue: errno) ?? .EADDRINUSE) }
    guard listen(fd, 16) == 0 else { close(fd); throw POSIXError(.init(rawValue: errno) ?? .EINVAL) }
    return fd
}

private func unixConnect(_ path: String, retryFor seconds: Double) -> Int32? {
    let deadline = seconds
    var waited = 0.0
    while waited <= deadline {
        let fd = (try? makeUnixSocket()) ?? -1
        if fd >= 0 {
            var addr = sockaddr_un()
            fillSunPath(&addr, path)
            let length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
            }
            if connected == 0 { return fd }
            close(fd)
        }
        usleep(200_000)
        waited += 0.2
    }
    return nil
}

/// Reads a single `\n`-terminated line from a socket, byte by byte so no PTY data
/// past the newline is consumed.
private func readLine(_ fd: Int32) -> Data? {
    var data = Data()
    var byte: UInt8 = 0
    while true {
        let n = read(fd, &byte, 1)
        if n <= 0 { return data.isEmpty ? nil : data }
        if byte == 0x0A { return data }
        data.append(byte)
    }
}

// MARK: - main

@main
struct TermioSandbox {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "serve": try await serve(Array(args.dropFirst()))
        case "attach": try attach(Array(args.dropFirst()))
        default:
            FileHandle.standardError.write(Data("usage: termio-sandbox <serve|attach> ...\n".utf8))
            exit(2)
        }
    }

    // MARK: serve

    static func serve(_ args: [String]) async throws {
        let opts = Options.parse(args)
        guard let socketPath = opts.socket else {
            FileHandle.standardError.write(Data("serve: --socket required\n".utf8))
            exit(2)
        }
        let kernelPath = opts.kernelPath ?? "./vmlinux-arm64"

        var manager = try await ContainerManager(
            kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm),
            initfsReference: "ghcr.io/apple/containerization/vminit:0.26.5",
            network: try VmnetNetwork()
        )

        let containerId = "termio-\(ProcessInfo.processInfo.processIdentifier)"
        let workspace = opts.workspace
        let mounts = opts.mounts

        let container = try await manager.create(
            containerId,
            reference: opts.image,
            rootfsSizeInBytes: 16.gib()
        ) { @Sendable config in
            config.cpus = opts.cpus
            config.memoryInBytes = opts.memoryMegabytes * 1024 * 1024
            config.mounts.append(Mount.share(source: workspace, destination: "/workspace"))
            for mount in mounts {
                config.mounts.append(Mount.share(
                    source: mount.host, destination: mount.guest,
                    options: mount.readOnly ? ["ro"] : []))
            }
            // The init process is a parked idle shell: the container stays up for the
            // life of the project while sessions exec into it.
            config.process.arguments = ["/bin/sleep", "infinity"]
            config.process.workingDirectory = "/"
        }

        try await container.create()
        try await container.start()
        defer { try? manager.delete(containerId) }

        // The app stops a project's daemon with SIGTERM (project closed, or app quit).
        // The default action would kill us without running the `defer` above, orphaning
        // the container's multi-gigabyte rootfs under the Containerization image store.
        // So handle termination explicitly: delete the container, then exit. The handler
        // runs on its own queue, unblocked by the `accept` loop below; the sources are
        // kept alive by that loop never returning. (SIGINT covers a standalone run.)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let cleanupQueue = DispatchQueue(label: "termio-sandbox.termination")
        let terminationSources = [SIGTERM, SIGINT].map { signalNumber -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: cleanupQueue)
            source.setEventHandler {
                var manager = manager
                try? manager.delete(containerId)
                exit(0)
            }
            source.resume()
            return source
        }

        if !opts.installCommand.isEmpty {
            log("preparing sandbox — installing agents…")
            try await runToCompletion(in: container, id: "install",
                                      command: ["/bin/sh", "-lc", opts.installCommand])
        }

        let listenFd = try unixListen(socketPath)
        log("sandbox ready")

        // Accept loop: each session connects, we exec its command in the shared
        // container and bridge the PTY over the connection. Wrapping it in
        // `withExtendedLifetime` keeps the termination signal sources alive for as long
        // as the daemon is serving (the loop never returns).
        withExtendedLifetime(terminationSources) {
            while true {
                let conn = accept(listenFd, nil, nil)
                if conn < 0 { continue }
                Task { await handleConnection(conn, in: container) }
            }
        }
    }

    private static func handleConnection(_ conn: Int32, in container: LinuxContainer) async {
        defer { close(conn) }
        guard let headerData = readLine(conn),
              let header = try? JSONDecoder().decode(AttachHeader.self, from: headerData)
        else { return }

        do {
            let size = Terminal.Size(width: header.cols, height: header.rows)
            let (parent, child) = try Terminal.create(initialSize: size)
            try? child.setraw()

            let command = header.command
            let process = try await container.exec("session-\(conn)") { @Sendable config in
                config.setTerminalIO(terminal: child)
                config.arguments = command
                config.workingDirectory = "/workspace"
            }
            try await process.start()

            // Bridge: guest output (on the pty master) → socket, socket → guest input.
            spawnPump(from: parent.handle.fileDescriptor, to: conn)
            spawnPump(from: conn, to: parent.handle.fileDescriptor)

            _ = try await process.wait()
            try? await process.delete()
        } catch {
            let message = "termio-sandbox: \(error)\n"
            _ = message.withCString { write(conn, $0, strlen($0)) }
        }
    }

    private static func runToCompletion(in container: LinuxContainer, id: String, command: [String]) async throws {
        let process = try await container.exec(id) { @Sendable config in
            config.arguments = command
            config.workingDirectory = "/workspace"
        }
        try await process.start()
        _ = try await process.wait()
        try? await process.delete()
    }

    // MARK: attach

    static func attach(_ args: [String]) throws {
        let opts = Options.parse(args)
        guard let socketPath = opts.socket else {
            FileHandle.standardError.write(Data("attach: --socket required\n".utf8))
            exit(2)
        }

        let terminal = try Terminal.current
        let size = (try? terminal.size) ?? Terminal.Size(width: 120, height: 40)

        // The first session of a project waits while the daemon boots the container,
        // pulls the image, and installs the agents (minutes, once). Say so, since the
        // terminal is otherwise blank, and retry long enough to cover that one-time cost.
        let waiting = "Preparing the project's sandbox (first run installs the agents — this can take a few minutes)…\r\n"
        _ = waiting.withCString { write(terminal.handle.fileDescriptor, $0, strlen($0)) }

        guard let conn = unixConnect(socketPath, retryFor: 600) else {
            FileHandle.standardError.write(Data("termio-sandbox: could not reach the project's sandbox\n".utf8))
            exit(1)
        }
        defer { close(conn) }

        let command = opts.command.isEmpty ? ["/bin/sh", "-l"] : opts.command
        let header = AttachHeader(cols: size.width, rows: size.height, command: command)
        var line = (try? JSONEncoder().encode(header)) ?? Data()
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(conn, $0.baseAddress, $0.count) }

        try terminal.setraw()
        defer { terminal.tryReset() }

        // Bridge this PTY to the daemon: keystrokes → socket, socket → screen.
        spawnPump(from: terminal.handle.fileDescriptor, to: conn)
        pump(from: conn, to: terminal.handle.fileDescriptor)  // blocks until the daemon closes (session exit)
    }
}

// MARK: - Options

private struct Options {
    struct ExtraMount { var host: String; var guest: String; var readOnly: Bool }

    var workspace = FileManager.default.currentDirectoryPath
    var kernelPath: String?
    var socket: String?
    var image = "docker.io/library/alpine:3.16"
    var cpus = 4
    var memoryMegabytes: UInt64 = 4096
    var installCommand = ""
    var mounts: [ExtraMount] = []
    var command: [String] = []

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        let valued: Set<String> = ["--workspace", "--kernel", "--socket", "--image", "--cpus", "--memory", "--install", "--mount"]
        while i < args.count {
            let a = args[i]
            if a == "--" { o.command = Array(args[(i + 1)...]); break }
            guard valued.contains(a), i + 1 < args.count else { i += 1; continue }
            let v = args[i + 1]
            switch a {
            case "--workspace": o.workspace = v
            case "--kernel": o.kernelPath = v
            case "--socket": o.socket = v
            case "--image": o.image = v
            case "--cpus": o.cpus = Int(v) ?? o.cpus
            case "--memory": o.memoryMegabytes = UInt64(v) ?? o.memoryMegabytes
            case "--install": o.installCommand = v
            case "--mount":
                let parts = v.split(separator: ":", maxSplits: 2).map(String.init)
                if parts.count >= 2 {
                    o.mounts.append(ExtraMount(host: parts[0], guest: parts[1],
                                               readOnly: parts.count == 3 && parts[2] == "ro"))
                }
            default: break
            }
            i += 2
        }
        return o
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("[termio-sandbox] \(message)\n".utf8))
}
