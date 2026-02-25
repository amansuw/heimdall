import Foundation
import SystemConfiguration

struct NetworkReaderResult: Sendable {
    let dlSpeed: UInt64
    let ulSpeed: UInt64
    let totalIn: UInt64
    let totalOut: UInt64
    let activeIface: NetworkInterface?
    let snapshot: NetworkSnapshot
}

class NetworkReader {
    private var prevBytesIn: UInt64 = 0
    private var prevBytesOut: UInt64 = 0
    private var prevTimestamp: Date?

    func read() -> NetworkReaderResult {
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var activeIface: NetworkInterface?

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            let now = Date()
            return NetworkReaderResult(dlSpeed: 0, ulSpeed: 0, totalIn: 0, totalOut: 0, activeIface: nil,
                                       snapshot: NetworkSnapshot(timestamp: now, downloadBytesPerSec: 0, uploadBytesPerSec: 0))
        }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = ptr {
            let name = String(cString: addr.pointee.ifa_name)
            let flags = Int32(addr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK) && !isLoopback {
                addr.pointee.ifa_data.withMemoryRebound(to: if_data.self, capacity: 1) { data in
                    totalIn += UInt64(data.pointee.ifi_ibytes)
                    totalOut += UInt64(data.pointee.ifi_obytes)
                }
            }

            if addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) && isUp && !isLoopback {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr.pointee.ifa_addr, socklen_t(addr.pointee.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)

                if !ip.isEmpty && ip != "127.0.0.1" && activeIface == nil {
                    var iface = NetworkInterface(id: name)
                    iface.localIP = ip
                    iface.isUp = isUp
                    iface.displayName = interfaceDisplayName(name)
                    iface.macAddress = getMACAddress(for: name, firstAddr: firstAddr)
                    getLinkSpeed(for: name, firstAddr: firstAddr, iface: &iface)
                    activeIface = iface
                }
            }

            if addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET6) && isUp && !isLoopback {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr.pointee.ifa_addr, socklen_t(addr.pointee.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let ip6 = String(cString: hostname)
                if !ip6.hasPrefix("fe80") && !ip6.isEmpty {
                    activeIface?.ipv6 = ip6
                }
            }

            ptr = addr.pointee.ifa_next
        }

        let now = Date()
        var dlSpeed: UInt64 = 0
        var ulSpeed: UInt64 = 0

        if let prevTime = prevTimestamp {
            let elapsed = now.timeIntervalSince(prevTime)
            if elapsed > 0 && totalIn >= prevBytesIn && totalOut >= prevBytesOut {
                dlSpeed = UInt64(Double(totalIn - prevBytesIn) / elapsed)
                ulSpeed = UInt64(Double(totalOut - prevBytesOut) / elapsed)
            }
        }

        prevBytesIn = totalIn
        prevBytesOut = totalOut
        prevTimestamp = now

        return NetworkReaderResult(
            dlSpeed: dlSpeed, ulSpeed: ulSpeed,
            totalIn: totalIn, totalOut: totalOut,
            activeIface: activeIface,
            snapshot: NetworkSnapshot(timestamp: now, downloadBytesPerSec: dlSpeed, uploadBytesPerSec: ulSpeed)
        )
    }

    func fetchDNSServers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "Heimdall" as CFString, nil, nil) else { return [] }
        let key = "State:/Network/Global/DNS" as CFString
        guard let dnsDict = SCDynamicStoreCopyValue(store, key) as? [String: Any],
              let addresses = dnsDict["ServerAddresses"] as? [String] else { return [] }
        return addresses
    }

    func fetchPublicIP(completion: @escaping (String?, String?) -> Void) {
        let url = URL(string: "https://api.ipify.org")!
        var ipv4: String?
        var ipv6: String?
        let group = DispatchGroup()

        group.enter()
        URLSession.shared.dataTask(with: url) { data, _, _ in
            defer { group.leave() }
            if let data = data { ipv4 = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        }.resume()

        group.enter()
        let url6 = URL(string: "https://api64.ipify.org")!
        URLSession.shared.dataTask(with: url6) { data, _, _ in
            defer { group.leave() }
            if let data = data {
                let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.contains(":") { ipv6 = trimmed }
            }
        }.resume()

        group.notify(queue: .global(qos: .utility)) {
            completion(ipv4, ipv6)
        }
    }

    private func interfaceDisplayName(_ name: String) -> String {
        if name.hasPrefix("en0") { return "Wi-Fi" }
        if name.hasPrefix("en") { return "Ethernet (\(name))" }
        if name.hasPrefix("utun") { return "VPN (\(name))" }
        if name.hasPrefix("bridge") { return "Bridge (\(name))" }
        return name
    }

    private func getMACAddress(for interfaceName: String, firstAddr: UnsafeMutablePointer<ifaddrs>) -> String {
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = ptr {
            let name = String(cString: addr.pointee.ifa_name)
            if name == interfaceName && addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                let mac = addr.pointee.ifa_addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { sdl -> String in
                    let addrLen = Int(sdl.pointee.sdl_alen)
                    guard addrLen == 6 else { return "" }
                    let dataStart = withUnsafePointer(to: &sdl.pointee.sdl_data) { ptr in
                        UnsafeRawPointer(ptr).advanced(by: Int(sdl.pointee.sdl_nlen))
                    }
                    let bytes = dataStart.bindMemory(to: UInt8.self, capacity: 6)
                    return (0..<6).map { String(format: "%02x", bytes[$0]) }.joined(separator: ":")
                }
                return mac
            }
            ptr = addr.pointee.ifa_next
        }
        return ""
    }

    private func getLinkSpeed(for interfaceName: String, firstAddr: UnsafeMutablePointer<ifaddrs>, iface: inout NetworkInterface) {
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = ptr {
            let name = String(cString: addr.pointee.ifa_name)
            if name == interfaceName && addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                addr.pointee.ifa_data.withMemoryRebound(to: if_data.self, capacity: 1) { data in
                    let baudrate = data.pointee.ifi_baudrate
                    if baudrate > 0 { iface.speed = "\(baudrate / 1_000_000) Mbit" }
                }
                return
            }
            ptr = addr.pointee.ifa_next
        }
    }
}
