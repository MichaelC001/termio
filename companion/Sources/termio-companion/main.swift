import Darwin
import Foundation
import Network
import TermioShared

// termio companion server — PoC.
//
// Opens a PTY, spawns a shell/agent in it, and bridges that PTY to a single
// WebSocket client: PTY output → binary frames out, binary frames in → PTY
// input, resize control → TIOCSWINSZ. One client at a time is all the PoC needs.

// Line-buffer stdout so logs flush per line even when redirected to a file.
setvbuf(stdout, nil, _IOLBF, 0)

let defaultPort: UInt16 = 8787
let port = ProcessInfo.processInfo.arguments
    .firstIndex(of: "--port")
    .flatMap { ProcessInfo.processInfo.arguments[safe: $0 + 1] }
    .flatMap { UInt16($0) } ?? defaultPort

let command = ProcessInfo.processInfo.arguments
    .firstIndex(of: "--command")
    .flatMap { ProcessInfo.processInfo.arguments[safe: $0 + 1] } ?? "/bin/zsh"

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - PTY session

/// One PTY with a child process. Reads run on a dispatch source; the owner
/// wires `onOutput` to the WebSocket and calls `write`/`resize`.
final class PTYSession {
    private let masterFD: Int32
    private let process = Process()
    private var readSource: DispatchSourceRead?
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    init?(command: String, cols: Int, rows: Int) {
        var master: Int32 = 0
        var slave: Int32 = 0
        var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &win) == 0 else {
            FileHandle.standardError.write(Data("openpty failed\n".utf8))
            return nil
        }
        masterFD = master

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = command.hasSuffix("zsh") || command.hasSuffix("bash") ? ["-il"] : []
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        process.environment = env
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        process.terminationHandler = { [weak self] p in
            self?.onExit?(p.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("spawn failed: \(error)\n".utf8))
            close(master)
            close(slave)
            return nil
        }
        // The child holds the slave now; the parent only needs the master.
        close(slave)

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(masterFD, &buffer, buffer.count)
            if n > 0 {
                onOutput?(Data(buffer[0 ..< n]))
            } else if n <= 0 {
                readSource?.cancel()
            }
        }
        source.resume()
        readSource = source
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            _ = Darwin.write(masterFD, raw.baseAddress, raw.count)
        }
    }

    func resize(cols: Int, rows: Int) {
        var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &win)
    }

    func stop() {
        readSource?.cancel()
        if process.isRunning { process.terminate() }
        close(masterFD)
    }
}

// MARK: - WebSocket bridge

func handleConnection(_ connection: NWConnection) {
    log("client connected")
    guard let pty = PTYSession(command: command, cols: 80, rows: 24) else {
        connection.cancel()
        return
    }

    pty.onOutput = { data in
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "out", metadata: [meta])
        connection.send(content: data, contentContext: context, completion: .idempotent)
    }
    pty.onExit = { code in
        let control = CompanionControl.exit(code: code).encoded()
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "exit", metadata: [meta])
        connection.send(content: Data(control.utf8), contentContext: context, completion: .idempotent)
        log("child exited (\(code))")
    }

    func receive() {
        connection.receiveMessage { data, context, _, error in
            if let error {
                log("recv error: \(error)")
                pty.stop()
                return
            }
            if let context,
               let meta = context.protocolMetadata(definition: NWProtocolWebSocket.definition)
                   as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .binary:
                    if let data { pty.write(data) }
                case .text:
                    if let data, let text = String(data: data, encoding: .utf8),
                       case .resize(let cols, let rows)? = CompanionControl.decode(text) {
                        pty.resize(cols: cols, rows: rows)
                    }
                case .close:
                    log("client closed")
                    pty.stop()
                    return
                default:
                    break
                }
            }
            receive()
        }
    }

    connection.stateUpdateHandler = { state in
        if case .cancelled = state { pty.stop() }
        if case .failed = state { pty.stop() }
    }
    connection.start(queue: .global())
    receive()
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
}

// MARK: - Listener

let parameters = NWParameters.tcp
let wsOptions = NWProtocolWebSocket.Options()
wsOptions.autoReplyPing = true
parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!) else {
    FileHandle.standardError.write(Data("failed to bind port \(port)\n".utf8))
    exit(1)
}
listener.newConnectionHandler = handleConnection
listener.stateUpdateHandler = { state in
    if case .ready = state {
        log("termio companion listening on ws://localhost:\(port)  (command: \(command))")
    }
}
listener.start(queue: .main)
dispatchMain()
