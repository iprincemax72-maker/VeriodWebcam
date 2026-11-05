import Foundation

enum NetworkInfo {
    /// Returns non-loopback IPv4 addresses for display so the user knows
    /// which IP to type into the phone app.
    static func localIPv4Addresses() -> [String] {
        var results: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            let family = cur.pointee.ifa_addr?.pointee.sa_family

            if (flags & IFF_UP) == IFF_UP,
               (flags & IFF_LOOPBACK) == 0,
               family == UInt8(AF_INET),
               let addr = cur.pointee.ifa_addr {

                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let ok = getnameinfo(
                    addr,
                    socklen_t(cur.pointee.ifa_addr.pointee.sa_len),
                    &host, socklen_t(host.count),
                    nil, 0,
                    NI_NUMERICHOST
                )
                if ok == 0 {
                    let ip = String(cString: host)
                    if !ip.hasPrefix("169.254.") {
                        results.append(ip)
                    }
                }
            }
            ptr = cur.pointee.ifa_next
        }
        return results
    }
}
