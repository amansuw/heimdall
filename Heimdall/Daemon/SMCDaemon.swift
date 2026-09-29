import Foundation

class SMCDaemon {
    /// Root-owned directory: /tmp is world-writable, so anything placed there can be
    /// pre-created, symlinked or replaced by an unprivileged process.
    static let socketDir = "/var/run/heimdall"
    static let socketPath = "/var/run/heimdall/smc.sock"
    static let logPath = HelperInstaller.logPath

    static var daemonLabel: String { HelperInstaller.label }
    static var plistPath: String { HelperInstaller.plistPath }

    // MARK: - Daemon lifecycle

    static func runPersistent() {
        log("Daemon starting — uid=\(getuid()), euid=\(geteuid()), pid=\(getpid())")

        // launchd runs this as root, so it must only ever run from the installed copy,
        // where the file and every directory above it are root-only. Anywhere else —
        // an app bundle in /Applications included — could be swapped out underneath it.
        guard let selfPath = currentExecutablePath(),
              selfPath == HelperInstaller.executablePath,
              HelperInstaller.isRootOnly(selfPath) else {
            log("FATAL: refusing to run — not the root-only helper at \(HelperInstaller.executablePath)")
            exit(1)
        }
        // Clients are admitted by code signature: only this exact build may connect.
        guard let ownCDHash = CodeIdentity.currentCDHash() else {
            log("FATAL: refusing to run — the helper has no code signature to admit clients by")
            exit(1)
        }
        log("Admitting clients signed with cdhash \(ownCDHash)")

        let smc = SMCKit.shared
        log("SMC open: \(smc.isOpen)")

        guard let listener = makeListeningSocket() else {
            log("FATAL: could not create listening socket at \(socketPath)")
            exit(1)
        }
        log("Listening on \(socketPath)")

        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                log("accept failed: errno=\(errno)")
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }

            if let reason = rejectionReason(forPeerOf: client, selfPath: selfPath, cdhash: ownCDHash) {
                log("REJECTED connection: \(reason)")
                Darwin.close(client)
                continue
            }

            log("Client accepted")
            sessionForcedFans = false
            handleSession(fd: client, smc: smc)
            Darwin.close(client)
            log("Client disconnected")
            // Energy reporting is for a watching app. Nobody is watching now.
            setEnergyReporting(false)

            // The app normally hands the fans back on quit. If it crashed or was
            // killed it never got the chance, and the SMC would keep running them at
            // whatever was last written — including a speed far below what the
            // machine needs. Nothing else will clean this up, so the daemon does.
            if sessionForcedFans {
                log("Client left fans under manual control — restoring automatic")
                restoreAutomaticFans(smc: smc)
                sessionForcedFans = false
            }
        }
    }

    // MARK: - Socket setup

    private static func makeListeningSocket() -> Int32? {
        // 0755: the directory must be traversable so the client can reach the socket,
        // but only root may create or replace entries inside it.
        mkdir(socketDir, 0o755)
        chmod(socketDir, 0o755)
        chown(socketDir, 0, 0)
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = socketAddress(socketPath)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
        }
        guard bound == 0 else { Darwin.close(fd); return nil }

        // Any local user may connect; authority comes from the peer check, not the mode.
        chmod(socketPath, 0o666)
        guard listen(fd, 4) == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    static func socketAddress(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dest in
                let n = min(bytes.count, capacity - 1)
                for i in 0..<n { dest[i] = CChar(bitPattern: bytes[i]) }
                dest[n] = 0
            }
        }
        return addr
    }

    // MARK: - Peer authorization

    /// Returns nil when the peer may proceed, otherwise why it was refused.
    ///
    /// The app is ad-hoc signed, so there is no Team ID to check. The peer must be
    /// running exactly this build — the helper's own cdhash, since the helper was
    /// copied from the app that installed it — and the helper must still be
    /// root-only. Where the app itself lives does not matter: a replaced or modified
    /// app has a different cdhash.
    private static func rejectionReason(forPeerOf fd: Int32, selfPath: String, cdhash: String) -> String? {
        // Re-check per connection: the helper may have been tampered with since launch.
        guard HelperInstaller.isRootOnly(selfPath) else {
            return "\(selfPath) is no longer root-only"
        }
        return CodeIdentity.rejectionReason(forPeerOf: fd, requiringCDHash: cdhash)
    }

    private static func currentExecutablePath() -> String? {
        var size = UInt32(MAXPATHLEN)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
        var resolved = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard realpath(buf, &resolved) != nil else { return String(cString: buf) }
        return String(cString: resolved)
    }

    // MARK: - Session handling

    private static func handleSession(fd: Int32, smc: SMCKit) {
        var buffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 1024)

        while true {
            let n = Darwin.read(fd, &readBuf, readBuf.count)
            if n <= 0 { break }
            buffer.append(contentsOf: readBuf[0..<n])

            // Refuse to buffer unbounded garbage from a peer that never sends a newline.
            if buffer.count > 64 * 1024 {
                log("Dropping client: oversized command buffer")
                return
            }

            while let nlRange = buffer.range(of: Data([0x0A])) {
                let lineData = buffer[buffer.startIndex..<nlRange.lowerBound]
                buffer.removeSubrange(buffer.startIndex...nlRange.lowerBound)

                guard let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !line.isEmpty else { continue }

                let response = processCommand(line, smc: smc) + "\n"
                guard let out = response.data(using: .utf8) else { continue }
                let written = out.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
                if written <= 0 { return }
            }
        }
    }

    /// Hands every fan back to the firmware. Deliberately best-effort and quiet:
    /// this runs after a client has already gone away.
    ///
    /// Note this does not restore F<n>Mn. The factory minimum is only known to the
    /// app, which re-establishes it on next launch from its stored baseline.
    private static func restoreAutomaticFans(smc: SMCKit) {
        _ = smc.writeKey("Ftst", bytes: [0x00])

        let fanCount = smc.getNumberOfFans()
        for index in 0..<max(fanCount, 0) {
            _ = smc.setFanMode(fanIndex: index, mode: .automatic)
        }
        if let value = smc.readKey("FS! ") {
            _ = smc.writeKey("FS! ", bytes: [UInt8](repeating: 0, count: Int(value.dataSize)))
        }
    }

    // MARK: - Key policy

    // The daemon runs as root and will happily write any SMC key it is asked to.
    // Fan control needs a small, fixed set; everything else is refused so that a
    // compromised or malicious client cannot reach unrelated SMC state.

    /// SMC keys are always 4 bytes, space padded. The command line is split on
    /// spaces, so the padded key "FS! " arrives here as "FS!" — re-pad before matching.
    private static func normalizedKey(_ raw: String) -> String {
        raw.count >= 4 ? String(raw.prefix(4))
                       : raw.padding(toLength: 4, withPad: " ", startingAt: 0)
    }

    /// Per-fan mode/target/minimum, the global force mask, and thermalmonitord's
    /// force-test toggle. Nothing else is fan control.
    private static func isWritable(_ key: String) -> Bool {
        if key == "FS! " || key == "Ftst" { return true }
        let c = Array(key)
        guard c.count == 4, c[0] == "F", c[1].isNumber else { return false }
        return ["Md", "Tg", "Mn"].contains(String(c[2...3]))
    }

    /// Reads are additionally allowed for the fan values the app displays.
    private static func isReadable(_ key: String) -> Bool {
        if isWritable(key) || key == "FNum" { return true }
        let c = Array(key)
        guard c.count == 4, c[0] == "F", c[1].isNumber else { return false }
        return ["Ac", "Mx"].contains(String(c[2...3]))
    }

    // MARK: - Command processing

    /// Set when this session wrote anything that takes fans away from firmware
    /// control, so the daemon knows whether a vanished client left them forced.
    /// Only the single-threaded accept loop touches it.
    nonisolated(unsafe) private static var sessionForcedFans = false

    private static func processCommand(_ line: String, smc: SMCKit) -> String {
        let parts = line.split(separator: " ")
        guard !parts.isEmpty else { return "ERR empty" }

        switch String(parts[0]) {
        case "PING":
            // Lets a client tell an admitted connection from one this helper refused
            // and closed, or from a helper of another version.
            return "PONG \(HelperInstaller.versionTag)"

        case "WRITE":
            guard parts.count >= 3 else { return "ERR write_args" }
            let key = normalizedKey(String(parts[1]))
            guard isWritable(key) else {
                log("REFUSED write to non-fan key \(key)")
                return "ERR key_not_permitted"
            }
            let hexBytes = parts[2...].compactMap { UInt8($0, radix: 16) }
            guard !hexBytes.isEmpty, hexBytes.count <= 32 else { return "ERR write_args" }

            // Any non-zero write to these keys means the fans are no longer under
            // firmware control.
            if key == "Ftst" || key == "FS! " || key.hasSuffix("Md"), hexBytes.contains(where: { $0 != 0 }) {
                sessionForcedFans = true
            }
            return smc.writeKey(key, bytes: hexBytes) ? "OK" : "ERR write_failed"

        case "READ":
            guard parts.count >= 2 else { return "ERR read_args" }
            let key = normalizedKey(String(parts[1]))
            guard isReadable(key) else {
                log("REFUSED read of non-fan key \(key)")
                return "ERR key_not_permitted"
            }
            guard let val = smc.readKey(key) else { return "ERR read_nil" }
            if let decoded = smc.decodeValue(val) { return "VAL \(decoded)" }
            let hexBytes = val.bytes.prefix(Int(val.dataSize)).map { String(format: "%02X", $0) }.joined(separator: " ")
            return "RAW \(val.dataType.trimmingCharacters(in: .whitespaces)) \(hexBytes)"

        case "ENERGY":
            guard parts.count == 2, parts[1] == "ON" || parts[1] == "OFF" else { return "ERR energy_args" }
            return setEnergyReporting(parts[1] == "ON") ? "OK" : "ERR energy_failed"

        default:
            return "ERR unknown_cmd"
        }
    }

    // MARK: - Energy reporting

    /// The power manager only publishes the IOReport CPU and Neural Engine energy
    /// counters while a client holding com.apple.private.pmgr.nrg.reporting is
    /// sampling. No third-party binary can hold that entitlement, root or not;
    /// powermetrics does. While it runs, the counters publish every second for
    /// every process, so the app's unprivileged reader sees live values.
    ///
    /// The command line is fixed and its output discarded: this is a switch, not
    /// a way for a client to run anything. Cost measured on an M3 Max: 0.3% CPU.
    ///
    /// Each ON is a lease: powermetrics exits by itself after `energyLeaseSamples`
    /// seconds, so a helper that dies cannot leave it running. The app renews
    /// well inside that.
    nonisolated(unsafe) private static var energyReporter: Process?
    private static let energyLeaseSamples = 60
    nonisolated(unsafe) private static var energyReporterStarted: Date?

    @discardableResult
    private static func setEnergyReporting(_ on: Bool) -> Bool {
        if !on {
            if let reporter = energyReporter, reporter.isRunning {
                reporter.terminate()
                log("Energy reporting stopped")
            }
            energyReporter = nil
            energyReporterStarted = nil
            return true
        }
        let renewing = energyReporter != nil
        if let reporter = energyReporter, reporter.isRunning {
            // Restart only near the end of the lease, so renewals stay cheap.
            guard let started = energyReporterStarted,
                  Date().timeIntervalSince(started) > TimeInterval(energyLeaseSamples) / 2 else { return true }
            reporter.terminate()
        }

        let reporter = Process()
        reporter.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        reporter.arguments = ["-i", "1000", "-n", "\(energyLeaseSamples)", "--samplers", "cpu_power", "-o", "/dev/null"]
        reporter.standardInput = FileHandle.nullDevice
        reporter.standardOutput = FileHandle.nullDevice
        reporter.standardError = FileHandle.nullDevice
        do {
            try reporter.run()
        } catch {
            log("Energy reporting failed to start: \(error)")
            return false
        }
        energyReporter = reporter
        energyReporterStarted = Date()
        if !renewing { log("Energy reporting started (powermetrics pid \(reporter.processIdentifier))") }
        return true
    }

    // MARK: - Installation

    static func isDaemonRunning() -> Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    /// True only when the installed helper is this layout and this exact build. A
    /// helper from any other build would refuse this app, so it gets reinstalled.
    static func isDaemonInstalled() -> Bool {
        HelperInstaller.isInstalled(forCDHash: CodeIdentity.currentCDHash())
    }

    /// Copies this app into place as the root helper, behind one password prompt.
    static func installDaemon() -> HelperInstaller.Outcome {
        HelperInstaller.install(appBundlePath: Bundle.main.bundlePath, cdhash: CodeIdentity.currentCDHash() ?? "")
    }

    // MARK: - Helpers

    private static func log(_ msg: String) {
        guard let data = "\(Date()): \(msg)\n".data(using: .utf8) else { return }
        // O_NOFOLLOW: refuse to follow a symlink planted at logPath, which would
        // otherwise turn root's log writes into an arbitrary-file append.
        let fd = Darwin.open(logPath, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    }
}
