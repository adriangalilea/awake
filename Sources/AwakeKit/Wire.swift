import Foundation

/// One command per connection, one JSON line each way, then close. The CLI never
/// mutates state itself; the daemon is the only brain.
public enum Command: Codable, Sendable {
    case engage(Claim)
    /// nil ends every claim (the human kill switch); a token ends the claims it
    /// names — an owner-label prefix or a watched pid.
    case end(String?)
    case status
    case setFloor(Int)
    case setNotifyCommand(String)
    case setKeepDisplay(Bool)
    /// The human's "let it sleep" switch: claims kept, effect off / back on.
    case suspend
    case resume
}

public struct Reply: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: Status
    /// Undo breadcrumbs ride the wire so the client renders them from ONE round
    /// trip, race-free: the same-key claim an engage refreshed, the claim that
    /// already made it redundant, and everything an end tore down.
    public var replaced: Claim?
    public var coveredBy: Claim?
    public var ended: [Claim]?

    public init(ok: Bool, error: String? = nil, status: Status, replaced: Claim? = nil,
                coveredBy: Claim? = nil, ended: [Claim]? = nil) {
        self.ok = ok
        self.error = error
        self.status = status
        self.replaced = replaced
        self.coveredBy = coveredBy
        self.ended = ended
    }
}

private let maxLine = 64 * 1024

public enum Wire {
    // MARK: - Server (daemon side)

    /// Bind + listen on the state-dir socket. Returns the listening fd; caller wires
    /// it into a DispatchSource and calls `acceptAndServe` on readability.
    public static func listen() -> Int32 {
        Paths.ensureStateDir()
        unlink(Paths.socket.path) // stale socket from a dead daemon
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        // preconditions, not asserts: a daemon that cannot listen must DIE loudly in
        // release (launchd restarts it, the log says why), never run deaf.
        precondition(fd >= 0, "socket() failed: \(String(cString: strerror(errno)))")
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Paths.socket.path
        precondition(path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path),
                     "socket path too long: \(path)")
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8) + [0])
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
        }
        precondition(bound == 0, "bind(\(path)) failed: \(String(cString: strerror(errno)))")
        chmod(path, 0o600)
        let listening = Darwin.listen(fd, 8)
        precondition(listening == 0, "listen failed: \(String(cString: strerror(errno)))")
        return fd
    }

    /// Accept one connection, serve one command, close. Bounded by socket timeouts so
    /// a wedged client can stall the daemon for at most ~2s, never forever.
    public static func acceptAndServe(listenFd: Int32, handle: (Command) -> Reply) {
        let fd = accept(listenFd, nil, nil)
        guard fd >= 0 else {
            log("accept failed: \(String(cString: strerror(errno)))")
            return
        }
        defer { close(fd) }
        setTimeouts(fd)
        guard let line = readLine(fd) else {
            log("client sent no line")
            return
        }
        guard let cmd = try? JSONDecoder().decode(Command.self, from: line) else {
            log("undecodable command: \(String(data: line, encoding: .utf8) ?? "<binary>")")
            return
        }
        let reply = handle(cmd)
        writeLine(fd, try! JSONEncoder().encode(reply))
    }

    // MARK: - Client (CLI side)

    /// One round trip. nil = daemon unreachable (caller decides to kickstart or fail).
    public static func roundTrip(_ cmd: Command) -> Reply? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        setTimeouts(fd)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(Paths.socket.path.utf8) + [0])
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard connected == 0 else { return nil }
        writeLine(fd, try! JSONEncoder().encode(cmd))
        guard let line = readLine(fd) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: line)
    }

    // MARK: - Framing

    private static func setTimeouts(_ fd: Int32) {
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < maxLine {
            let n = read(fd, &byte, 1)
            if n <= 0 { return data.isEmpty ? nil : data }
            if byte == UInt8(ascii: "\n") { return data }
            data.append(byte)
        }
        return data
    }

    private static func writeLine(_ fd: Int32, _ data: Data) {
        var out = data
        out.append(UInt8(ascii: "\n"))
        out.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}
