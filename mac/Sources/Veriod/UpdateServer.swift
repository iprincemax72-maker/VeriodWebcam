import Darwin
import Foundation

/// Serves the phone update on port 8765. The installed app already looks
/// here for version.json and the APK. Files live in Application Support.
final class UpdateServer {
    static let port: UInt16 = 8765
    let root: URL
    private let acceptQueue = DispatchQueue(label: "veriod.update.accept")
    private let clientQueue = DispatchQueue(label: "veriod.update.client", attributes: .concurrent)

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Veriod/update", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func start() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            return
        }
        acceptQueue.async { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                self?.clientQueue.async {
                    self?.handle(client)
                }
            }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = buf.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return recv(client, base, raw.count, 0)
        }
        guard n > 0, let req = String(bytes: buf.prefix(n), encoding: .utf8) else { return }
        let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let name: String
        let type: String
        switch path {
        case "/version.json":
            name = "version.json"
            type = "application/json"
        case "/VeriodWebcam.apk":
            name = "VeriodWebcam.apk"
            type = "application/vnd.android.package-archive"
        default:
            let msg = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = msg.withCString { send(client, $0, strlen($0), 0) }
            return
        }
        let file = root.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file) else {
            let msg = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = msg.withCString { send(client, $0, strlen($0), 0) }
            return
        }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        _ = header.withCString { send(client, $0, strlen($0), 0) }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let w = send(client, base.advanced(by: sent), data.count - sent, 0)
                if w <= 0 { break }
                sent += w
            }
        }
    }
}
