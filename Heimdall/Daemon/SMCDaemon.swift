import Foundation

class SMCDaemon {
    static let cmdPath = "/tmp/heimdall-smc-cmd"
    static let rspPath = "/tmp/heimdall-smc-rsp"
    static let readyPath = "/tmp/heimdall-smc-ready"
    static let logPath = "/var/log/heimdall-daemon.log"

    /// Bumped whenever the installed plist must be replaced (paths, arguments, policy).
    /// `isDaemonInstalled()` compares this against the on-disk plist so upgrades reinstall.
    static let daemonVersion = "2"

    static let daemonLabel = "com.heimdall.smchelper"
    static let plistPath = "/Library/LaunchDaemons/com.heimdall.smchelper.plist"

    // MARK: - Daemon lifecycle

    static func runPersistent() {
        log("Daemon starting — uid=\(getuid()), euid=\(geteuid()), pid=\(getpid())")
        let smc = SMCKit.shared
        log("SMC open: \(smc.isOpen)")

        while true {
            cleanupFIFOs(cmd: cmdPath, rsp: rspPath, ready: readyPath)
            mkfifo(cmdPath, 0o666)
            mkfifo(rspPath, 0o666)
            chmod(cmdPath, 0o666)
            chmod(rspPath, 0o666)
            FileManager.default.createFile(atPath: readyPath, contents: nil)
            log("FIFOs ready, waiting for client...")

            handleSession(cmd: cmdPath, rsp: rspPath, smc: smc)

            log("Client disconnected, waiting for reconnect...")
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    // MARK: - Session handling

    private static func handleSession(cmd cmdPath: String, rsp rspPath: String, smc: SMCKit) {
        let cmdFd = Darwin.open(cmdPath, O_RDONLY)
        guard cmdFd >= 0 else { log("FATAL: cmd FIFO open failed"); return }

        let rspFd = Darwin.open(rspPath, O_WRONLY)
        guard rspFd >= 0 else { log("FATAL: rsp FIFO open failed"); Darwin.close(cmdFd); return }

        log("Client connected")

        var buffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 1024)

        while true {
            let n = Darwin.read(cmdFd, &readBuf, readBuf.count)
            if n <= 0 { break }
            buffer.append(contentsOf: readBuf[0..<n])

            while let nlRange = buffer.range(of: Data([0x0A])) {
                let lineData = buffer[buffer.startIndex..<nlRange.lowerBound]
                buffer.removeSubrange(buffer.startIndex...nlRange.lowerBound)

                guard let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !line.isEmpty else { continue }

                let response = processCommand(line, smc: smc)
                let rspData = (response + "\n").data(using: .utf8)!
                rspData.withUnsafeBytes { ptr in
                    _ = Darwin.write(rspFd, ptr.baseAddress!, ptr.count)
                }
            }
        }

        Darwin.close(cmdFd)
        Darwin.close(rspFd)
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
        FileManager.default.fileExists(atPath: readyPath)
    }

    /// True only when the installed plist matches the current daemon version, so a
    /// stale plist from an older build is treated as "not installed" and gets replaced.
    static func isDaemonInstalled() -> Bool {
        guard let contents = try? String(contentsOfFile: plistPath, encoding: .utf8) else { return false }
        return contents.contains("<string>heimdall-daemon-v\(daemonVersion)</string>")
    }

    static func installDaemon() -> Bool {
        guard let execPath = Bundle.main.executablePath else { return false }

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

    static func cleanupFIFOs(cmd: String, rsp: String, ready: String) {
        unlink(cmd)
        unlink(rsp)
        unlink(ready)
    }

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
