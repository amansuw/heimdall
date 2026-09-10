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

/// Throughput counters are used only on the monitor's fast queue. The public-IP
/// schedule is also touched from URLSession's callbacks, so it sits behind a lock.
final class NetworkReader: @unchecked Sendable {
    private var prevBytesIn: UInt64 = 0
    private var prevBytesOut: UInt64 = 0
    private var prevTimestamp: Date?

    private struct PublicIPSchedule {
        var isFetching = false
        var nextAllowedFetch: Date = .distantPast
        var consecutiveFailures = 0
    }
    private let publicIPLock = NSLock()
    private var publicIPSchedule = PublicIPSchedule()

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

    func fetchPublicIP(completion: @escaping @Sendable (String?, String?) -> Void) {
        let now = Date()
        let mayFetch = publicIPLock.withLock { () -> Bool in
            guard !publicIPSchedule.isFetching, now >= publicIPSchedule.nextAllowedFetch else { return false }
            publicIPSchedule.isFetching = true
            return true
        }
        guard mayFetch else {
            completion(nil, nil)
            return
        }

        let results = PublicIPResults()
        let group = DispatchGroup()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 4
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        group.enter()
        session.dataTask(with: URL(string: "https://api.ipify.org")!) { data, _, _ in
            defer { group.leave() }
            if let data {
                results.setIPv4(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.resume()

        group.enter()
        session.dataTask(with: URL(string: "https://api64.ipify.org")!) { data, _, _ in
            defer { group.leave() }
            if let data {
                let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.contains(":") { results.setIPv6(trimmed) }
            }
        }.resume()

        // Release the session once both requests finish. Every call used to leave one
        // behind for the life of the app.
        session.finishTasksAndInvalidate()

        group.notify(queue: .global(qos: .utility)) { [self] in
            let (ipv4, ipv6) = results.values
            let hadAnyResult = (ipv4?.isEmpty == false) || (ipv6?.isEmpty == false)
            publicIPLock.withLock {
                if hadAnyResult {
                    publicIPSchedule.consecutiveFailures = 0
                    publicIPSchedule.nextAllowedFetch = Date().addingTimeInterval(55)
                } else {
                    publicIPSchedule.consecutiveFailures += 1
                    let backoff = min(pow(2.0, Double(max(0, publicIPSchedule.consecutiveFailures - 1))) * 60.0, 30 * 60.0)
                    publicIPSchedule.nextAllowedFetch = Date().addingTimeInterval(backoff)
                }
                publicIPSchedule.isFetching = false
            }
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

/// Collects the two public-IP lookups, which complete on URLSession's callback queue.
private final class PublicIPResults: @unchecked Sendable {
    private let lock = NSLock()
    private var ipv4: String?
    private var ipv6: String?

    func setIPv4(_ value: String?) { lock.withLock { ipv4 = value } }
    func setIPv6(_ value: String?) { lock.withLock { ipv6 = value } }
    var values: (String?, String?) { lock.withLock { (ipv4, ipv6) } }
}
