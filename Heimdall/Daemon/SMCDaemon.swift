import Foundation

class SMCDaemon {
    static let cmdPath = "/tmp/heimdall-smc-cmd"
    static let rspPath = "/tmp/heimdall-smc-rsp"
    static let readyPath = "/tmp/heimdall-smc-ready"
    static let logPath = "/tmp/heimdall-daemon.log"

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

    // MARK: - Command processing

    private static func processCommand(_ line: String, smc: SMCKit) -> String {
        let parts = line.split(separator: " ")
        guard !parts.isEmpty else { return "ERR empty" }

        switch String(parts[0]) {
        case "WRITE":
            guard parts.count >= 3 else { return "ERR write_args" }
            let key = String(parts[1])
            let hexBytes = parts[2...].compactMap { UInt8($0, radix: 16) }
            let result = smc.writeKey(key, bytes: hexBytes)
            return result ? "OK" : "ERR write_failed"

        case "READ":
            guard parts.count >= 2 else { return "ERR read_args" }
            let key = String(parts[1])
            guard let val = smc.readKey(key) else { return "ERR read_nil" }
            let hexBytes = val.bytes.prefix(Int(val.dataSize)).map { String(format: "%02X", $0) }.joined(separator: " ")
            let dt = val.dataType.trimmingCharacters(in: .whitespaces)
            if let decoded = smc.decodeValue(val) {
                return "VAL \(decoded)"
            }
            return "RAW \(dt) \(hexBytes)"

        default:
            return "ERR unknown_cmd"
        }
    }

    // MARK: - Installation

    static func isDaemonRunning() -> Bool {
        FileManager.default.fileExists(atPath: readyPath)
    }

    static func isDaemonInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath)
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
        let line = "\(Date()): \(msg)\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
        }
    }
}
