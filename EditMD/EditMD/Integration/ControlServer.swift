import Foundation
import Darwin
import os

/// Unix-domain stream server for the control channel (v38).
///
/// BSD sockets (AF_UNIX) — simple JSON-lines: one request line → one response
/// line. Accept loop on a utility queue; command dispatch on MainActor via
/// `ControlRouter`.
final class ControlServer: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.editmd.control", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private(set) var path: URL?
    private var running = false

    /// Starts listening at `socketPath` (replaces a leftover file).
    func start(socketPath: URL) throws {
        stop()

        let dir = socketPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: socketPath.path) {
            try? FileManager.default.removeItem(at: socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlServerError.socket(errno) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw ControlServerError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in pathBytes.enumerated() {
                buf[i] = UInt8(bitPattern: b)
            }
        }

        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindOK == 0 else {
            let e = errno
            close(fd)
            throw ControlServerError.bind(e)
        }
        guard Darwin.listen(fd, 8) == 0 else {
            let e = errno
            close(fd)
            throw ControlServerError.listen(e)
        }

        // Restrict the socket file to the user.
        chmod(socketPath.path, 0o600)

        listenFD = fd
        path = socketPath
        running = true

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        src.setCancelHandler {
            // FD closed in stop()
        }
        source = src
        src.resume()
        controlLog.info("control socket listening at \(socketPath.path, privacy: .public)")
    }

    func stop() {
        running = false
        source?.cancel()
        source = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        if let path, FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.removeItem(at: path)
        }
        path = nil
    }

    private func acceptOne() {
        guard running, listenFD >= 0 else { return }
        var addr = sockaddr_un()
        var len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let client = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.accept(listenFD, sa, &len)
            }
        }
        guard client >= 0 else { return }
        queue.async { [weak self] in
            self?.serve(client)
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while running {
            let n = read(fd, &tmp, tmp.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            buffer.append(contentsOf: tmp[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let slice = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                guard let line = String(data: slice, encoding: .utf8) else { continue }
                let response: ControlResponse
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                do {
                    let request = try ControlCodec.decodeRequest(line)
                    // Hop to main for router (AppKit / document state).
                    // ControlResponse is Sendable value type — safe across queues.
                    response = Self.handleOnMain(request)
                } catch {
                    response = .failure(id: nil, error: "bad request: \(error)")
                }
                do {
                    let payload = try ControlCodec.encodeResponse(response)
                    let bytes = Array(payload.utf8)
                    var written = 0
                    while written < bytes.count {
                        let w = bytes.withUnsafeBufferPointer { buf in
                            Darwin.write(fd, buf.baseAddress! + written, bytes.count - written)
                        }
                        if w <= 0 { return }
                        written += w
                    }
                } catch {
                    controlLog.error("control encode/send failed: \(String(describing: error), privacy: .public)")
                    return
                }
            }
        }
    }
}

enum ControlServerError: Error, Equatable {
    case socket(Int32)
    case bind(Int32)
    case listen(Int32)
    case pathTooLong
}

extension ControlServer {
    /// Blocks the client-handler queue until MainActor finishes the command.
    nonisolated private static func handleOnMain(_ request: ControlRequest) -> ControlResponse {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { ControlRouter.handle(request) }
        }
        return DispatchQueue.main.sync {
            ControlRouter.handle(request)
        }
    }
}
