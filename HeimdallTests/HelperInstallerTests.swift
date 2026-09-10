import Foundation
import Testing

private func isGroupWritable(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0 && (st.st_mode & S_IWGRP) != 0
}

private struct ScriptResult {
    let status: Int32
    let stderr: String
}

/// Runs the real install script as the current user.
private func runInstallScript(shellOptions: [String] = [], arguments: [String]) throws -> ScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = shellOptions + ["-c", HelperInstaller.installScript, "heimdall-helper-install"] + arguments
    let errorPipe = Pipe()
    process.standardError = errorPipe
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return ScriptResult(status: process.terminationStatus, stderr: stderr)
}

private let validHash = String(repeating: "ab", count: 20)

@Suite("Fan helper installation")
struct HelperInstallerTests {

    // MARK: Root-only paths

    @Test func systemBinariesAreRootOnly() {
        #expect(HelperInstaller.isRootOnly("/usr/bin/true"))
    }

    /// Why the helper is copied at all: anything under a group-writable
    /// /Applications can be renamed away and replaced without root.
    @Test(.enabled(if: isGroupWritable("/Applications")))
    func applicationsIsNotRootOnly() {
        #expect(!HelperInstaller.isRootOnly("/Applications"))
    }

    @Test func userDirectoriesAreNotRootOnly() {
        #expect(!HelperInstaller.isRootOnly(NSTemporaryDirectory()))
        #expect(!HelperInstaller.isRootOnly(NSHomeDirectory()))
    }

    @Test(arguments: ["usr/bin/true", "/usr/bin/../bin/true", "/usr/./bin/true", "", "/usr/bin/does-not-exist"])
    func unresolvedOrMissingPathsAreNotRootOnly(path: String) {
        #expect(!HelperInstaller.isRootOnly(path))
    }

    // MARK: Installed record

    @Test func aRecordIsReadBackFromItsPlist() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heimdall-record-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        let plist: [String: Any] = [
            "Label": HelperInstaller.label,
            "HeimdallDaemonVersion": HelperInstaller.versionTag,
            "HeimdallCDHash": validHash,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)

        #expect(HelperInstaller.Record.load(from: url.path)
                == HelperInstaller.Record(versionTag: HelperInstaller.versionTag, cdhash: validHash))
    }

    /// Plists from earlier layouts carry no cdhash, so they never count as installed
    /// and get replaced.
    @Test func olderPlistsAreNotARecord() {
        #expect(HelperInstaller.Record(plist: ["HeimdallDaemonVersion": "heimdall-daemon-v3"]) == nil)
    }

    @Test func onlyThisLayoutAndThisBuildCountAsInstalled() {
        let current = HelperInstaller.Record(versionTag: HelperInstaller.versionTag, cdhash: validHash)
        #expect(HelperInstaller.isInstalled(forCDHash: validHash, record: current))
        #expect(!HelperInstaller.isInstalled(forCDHash: String(repeating: "cd", count: 20), record: current))
        #expect(!HelperInstaller.isInstalled(forCDHash: validHash,
                                             record: .init(versionTag: "heimdall-daemon-v3", cdhash: validHash)))
        #expect(!HelperInstaller.isInstalled(forCDHash: nil, record: current))
        #expect(!HelperInstaller.isInstalled(forCDHash: validHash, record: nil))
    }

    // MARK: Install script

    @Test func theInstallScriptParses() throws {
        let result = try runInstallScript(shellOptions: ["-n"], arguments: [])
        #expect(result.status == 0, "\(result.stderr)")
    }

    /// Every one of these must be refused by the argument checks, which run before
    /// anything touches the disk.
    @Test(arguments: [
        ("/Applications/Heimdall.app", "not-a-hash"),
        ("/Applications/Heimdall.app", String(repeating: "AB", count: 20)),
        ("/Applications/Heimdall.app", String(repeating: "ab", count: 19)),
        ("/Applications/Heimdall.app", "'; touch /tmp/heimdall-injected; '"),
        ("Heimdall.app", validHash),
        ("/tmp/not-an-app-bundle", validHash),
        ("/nonexistent/Heimdall.app", validHash),
    ])
    func malformedRequestsAreRefusedBeforeAnythingRuns(bundle: String, cdhash: String) throws {
        try #require(getuid() != 0, "the installer tests must never run as root")
        let result = try runInstallScript(arguments: [bundle, cdhash])
        #expect(result.status == 64, "\(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: "/tmp/heimdall-injected"))
    }

    @Test func aWellFormedRequestStillNeedsRoot() throws {
        try #require(getuid() != 0, "the installer tests must never run as root")
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("Heimdall-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let result = try runInstallScript(arguments: [bundle.path, validHash])
        #expect(result.status == 77, "\(result.stderr)")
    }

    @Test func osascriptFailuresBecomeReadableMessages() {
        #expect(HelperInstaller.failureMessage(
            fromOsascriptError: "0:312: execution error: The copied app's code signature is not valid. (65)\n")
            == "The copied app's code signature is not valid.")
        #expect(HelperInstaller.failureMessage(fromOsascriptError: "") == "The helper could not be installed.")
    }
}
