import Darwin
import Foundation
import IOSurface

/// Hands a display IOSurface to the app without copying a pixel: the surface's
/// Mach send right goes in one message to the receive right the app checked in
/// under `serviceName`, and the app turns it back into the same surface with
/// `IOSurfaceLookupFromMachPort`. A surface is process-local otherwise, and an
/// encoded video stream is what this exists to avoid.
///
/// The layout below is `SurfaceMessage` in the app's `SimulatorSurfaceReceiver`
/// byte for byte; the two halves of one private wire format.
final class SurfacePort: @unchecked Sendable {
    private let destination: mach_port_t
    private let lock = NSLock()

    init?(serviceName: String) {
        var bootstrap = mach_port_t(MACH_PORT_NULL)
        // TASK_BOOTSTRAP_PORT; the macro does not import.
        guard task_get_special_port(mach_task_self_, 4, &bootstrap) == KERN_SUCCESS else {
            Wire.log("no bootstrap port")
            return nil
        }
        var port = mach_port_t(MACH_PORT_NULL)
        let result = bootstrapLookUp(bootstrap, serviceName, &port)
        guard result == KERN_SUCCESS, port != MACH_PORT_NULL else {
            Wire.log("bootstrap_look_up(\(serviceName)) failed: \(result)")
            return nil
        }
        destination = port
    }

    /// Sends `surface` for display `stream`. The right is moved into the
    /// message, so there is nothing to release here on success; on failure the
    /// kernel hands the right back and it is destroyed instead.
    func send(_ surface: IOSurface, stream: UInt32) {
        let surfacePort = IOSurfaceCreateMachPort(surface)
        guard surfacePort != MACH_PORT_NULL else {
            Wire.log("IOSurfaceCreateMachPort returned no port for stream \(stream)")
            return
        }
        var message = SurfaceMessage()
        message.header.msgh_bits = MACH_MSGH_BITS_COMPLEX
            | mach_msg_bits_t(MACH_MSG_TYPE_COPY_SEND)
        message.header.msgh_size = mach_msg_size_t(MemoryLayout<SurfaceMessage>.size)
        message.header.msgh_remote_port = destination
        message.header.msgh_local_port = mach_port_t(MACH_PORT_NULL)
        message.header.msgh_id = 0x7453_696D  // "tSim"
        message.body.msgh_descriptor_count = 1
        message.surface.name = surfacePort
        message.surface.disposition = mach_msg_type_name_t(MACH_MSG_TYPE_MOVE_SEND)
        message.surface.type = mach_msg_descriptor_type_t(MACH_MSG_PORT_DESCRIPTOR)
        message.stream = stream
        let size = message.header.msgh_size
        let result = lock.withLock {
            withUnsafeMutablePointer(to: &message) { pointer in
                pointer.withMemoryRebound(to: mach_msg_header_t.self, capacity: 1) {
                    mach_msg($0, MACH_SEND_MSG | MACH_SEND_TIMEOUT, size, 0,
                             mach_port_t(MACH_PORT_NULL), 1000, mach_port_t(MACH_PORT_NULL))
                }
            }
        }
        if result != MACH_MSG_SUCCESS {
            Wire.log("sending stream \(stream)'s surface failed: \(result)")
            mach_port_deallocate(mach_task_self_, surfacePort)
        }
    }
}

// `servers/bootstrap.h` is not part of the Darwin module Swift imports.
@_silgen_name("bootstrap_look_up")
private func bootstrapLookUp(
    _ bootstrap: mach_port_t, _ name: UnsafePointer<CChar>, _ port: UnsafeMutablePointer<mach_port_t>
) -> kern_return_t

struct SurfaceMessage {
    var header = mach_msg_header_t()
    var body = mach_msg_body_t()
    var surface = mach_msg_port_descriptor_t()
    var stream: UInt32 = 0
}
