import Foundation

class SMCDaemon {
    /// Root-owned directory: /tmp is world-writable, so anything placed there can be
    /// pre-created, symlinked or replaced by an unprivileged process.
    static let socketDir = "/var/run/heimdall"
    static let socketPath = "/var/run/heimdall/smc.sock"
    static let logPath = "/var/log/heimdall-daemon.log"

    /// Bumped whenever the installed plist must be replaced (paths, arguments, policy).
    /// `isDaemonInstalled()` compares this against the on-disk plist so upgrades reinstall.
    static let daemonVersion = "3"

    static let daemonLabel = "com.heimdall.smchelper"
    static let plistPath = "/Library/LaunchDaemons/com.heimdall.smchelper.plist"

    // MARK: - Daemon lifecycle

    static func runPersistent() {
        log("Daemon starting — uid=\(getuid()), euid=\(geteuid()), pid=\(getpid())")

        // The whole peer check below rests on this binary living somewhere only root
        // can write. If it does not, any local user could replace it and be trusted.
        guard let selfPath = currentExecutablePath(), isRootOwnedAndNotUserWritable(selfPath) else {
            log("FATAL: refusing to run — executable is missing or user-writable")
            exit(1)
        }
        log("Authorized client path: \(selfPath)")

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

            if let reason = rejectionReason(forPeerOf: client, expecting: selfPath) {
                log("REJECTED connection: \(reason)")
                Darwin.close(client)
                continue
            }

            log("Client accepted")
            sessionForcedFans = false
            handleSession(fd: client, smc: smc)
            Darwin.close(client)
            log("Client disconnected")

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
    /// The app is distributed unsigned, so there is no Team ID to check. Instead the
    /// peer must be running the *same* executable this daemon was launched from, and
    /// that file must be root-owned and not user-writable — a condition an
    /// unprivileged attacker cannot manufacture.
    private static func rejectionReason(forPeerOf fd: Int32, expecting expectedPath: String) -> String? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 else {
            return "could not determine peer pid"
        }

        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return "could not resolve path of pid \(pid)" }
        let peerPath = String(cString: buf)

        guard peerPath == expectedPath else {
            return "pid \(pid) is \(peerPath), expected \(expectedPath)"
        }
        // Re-check ownership per connection: the binary may have been swapped since launch.
        guard isRootOwnedAndNotUserWritable(peerPath) else {
            return "\(peerPath) is no longer root-owned and write-protected"
        }
        return nil
    }

    private static func isRootOwnedAndNotUserWritable(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        guard st.st_uid == 0 else { return false }
        return (st.st_mode & S_IWGRP) == 0 && (st.st_mode & S_IWOTH) == 0
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
    private static var sessionForcedFans = false

    private static func processCommand(_ line: String, smc: SMCKit) -> String {
        let parts = line.split(separator: " ")
        guard !parts.isEmpty else { return "ERR empty" }

        switch String(parts[0]) {
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

        default:
            return "ERR unknown_cmd"
        }
    }

    // MARK: - Installation

    static func isDaemonRunning() -> Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    /// True only when the installed plist matches the current daemon version, so a
    /// stale plist from an older build is treated as "not installed" and gets replaced.
    static func isDaemonInstalled() -> Bool {
        guard let contents = try? String(contentsOfFile: plistPath, encoding: .utf8) else { return false }
        return contents.contains("<string>heimdall-daemon-v\(daemonVersion)</string>")
    }

    /// The peer check only means something if the app binary cannot be replaced by
    /// an unprivileged process. Installing from ~/Downloads would have launchd run a
    /// user-writable binary as root at every boot.
    static func isInstallLocationAcceptable() -> Bool {
        guard let execPath = Bundle.main.executablePath else { return false }
        var st = stat()
        guard lstat(execPath, &st) == 0 else { return false }
        return st.st_uid == 0 && (st.st_mode & S_IWGRP) == 0 && (st.st_mode & S_IWOTH) == 0
    }

    static func installDaemon() -> Bool {
        guard let execPath = Bundle.main.executablePath else { return false }

        guard isInstallLocationAcceptable() else {
            log("Refusing to install: \(execPath) is user-writable. Move Heimdall to /Applications first.")
            return false
        }

        let plistContent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>\(daemonLabel)</string>
    <key>HeimdallDaemonVersion</key>
    <string>heimdall-daemon-v\(daemonVersion)</string>
    <key>ProgramArguments</key>
    <array>
        <string>\(execPath)</string>
        <string>--smc-daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>\(logPath)</string>
    <key>StandardErrorPath</key>
    <string>\(logPath)</string>
</dict>
</plist>
"""

        let tmpPlist = NSTemporaryDirectory() + "com.heimdall.smchelper.plist"
        try? plistContent.write(toFile: tmpPlist, atomically: true, encoding: .utf8)

        let script = """
        do shell script "cp '\(tmpPlist)' '\(plistPath)' && \
        chmod 644 '\(plistPath)' && \
        launchctl bootout system/\(daemonLabel) 2>/dev/null; \
        launchctl bootstrap system '\(plistPath)'" with administrator privileges
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]

        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
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
