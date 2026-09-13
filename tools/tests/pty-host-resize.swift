// Run from the repo root:
// swiftc Sources/termio/Log.swift Sources/termio/PTYProcess.swift tools/tests/pty-host-resize.swift -o /tmp/termio-pty-host-resize
// /tmp/termio-pty-host-resize
import Foundation

@main
enum HostResizeRegression {
    static func main() {
        let output = Output()
        guard let pty = PTYProcess(
            argv: ["/bin/sh", "-c", "stty -echo; echo READY; while read line; do stty size; done"],
            cwd: "/tmp", env: ["PATH": "/usr/bin:/bin"], cols: 80, rows: 24
        ) else { fatalError("Could not create test PTY") }
        defer { pty.terminate() }
        pty.addSink(replayingBuffer: true) { output.receive($0) }
        output.expect("READY")

        // Keep the main runloop blocked so input arrives before the 50ms
        // coalescing callback, just as typing during a layout transition can.
        pty.resizeFromHost(cols: 120, rows: 40)
        pty.claimHostOwnership()
        pty.write(Data("size\n".utf8))
        output.expect("40 120")

        // Companion ownership must survive a background host layout change.
        pty.resizeFromCompanion(cols: 60, rows: 20)
        pty.resizeFromHost(cols: 100, rows: 35)
        pty.write(Data("size\n".utf8))
        output.expect("20 60")
        pty.claimHostOwnership()
        pty.write(Data("size\n".utf8))
        output.expect("35 100")
        print("PASS: host input uses the current grid; companion ownership is preserved")
    }

    final class Output: @unchecked Sendable {
        let lock = NSCondition()
        var text = ""

        func receive(_ data: Data) {
            lock.lock()
            text += String(decoding: data, as: UTF8.self)
            lock.broadcast()
            lock.unlock()
        }

        func expect(_ expected: String) {
            lock.lock()
            defer { lock.unlock() }
            let deadline = Date().addingTimeInterval(3)
            while !text.contains(expected) {
                guard lock.wait(until: deadline) else {
                    fatalError("Expected \(expected.debugDescription), received \(text.debugDescription)")
                }
            }
            text = ""
        }
    }
}
