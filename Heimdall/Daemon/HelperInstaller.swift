import Foundation

/// Installs, and describes, the root fan helper.
///
/// launchd runs the helper as root, so what it executes must sit where only root
/// can write: the file and every directory above it. The app bundle cannot be that
/// place. /Applications is root:admin 775, so any process running as an admin user
/// can rename Heimdall.app away and put something else at the same path, and
/// launchd would run that as root at the next boot. Installation therefore copies
/// the signed bundle into /Library/PrivilegedHelperTools and points the
/// LaunchDaemon at the copy.
///
/// The helper admits only a client with its own cdhash (see CodeIdentity), so the
/// app is trusted wherever it lives, and a modified or substituted app is not. The
/// same rule means an updated app needs the helper reinstalled to match it.
enum HelperInstaller {
    static let label = "com.heimdall.smchelper"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    static let bundlePath = "/Library/PrivilegedHelperTools/\(label).app"
    static let executablePath = "\(bundlePath)/Contents/MacOS/Heimdall"
    static let logPath = "/var/log/heimdall-daemon.log"

    /// Bumped whenever the installed layout, arguments or trust policy change, so an
    /// install from an older build is replaced rather than trusted.
    static let version = "4"
    static let versionTag = "heimdall-daemon-v\(version)"

    // MARK: - Installed record

    /// What the installed LaunchDaemon plist says about the helper.
    struct Record: Equatable {
        let versionTag: String
        let cdhash: String

        init(versionTag: String, cdhash: String) {
            self.versionTag = versionTag
            self.cdhash = cdhash
        }

        init?(plist: [String: Any]) {
            guard let tag = plist["HeimdallDaemonVersion"] as? String,
                  let hash = plist["HeimdallCDHash"] as? String else { return nil }
            self.init(versionTag: tag, cdhash: hash)
        }

        static func load(from path: String = HelperInstaller.plistPath) -> Record? {
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return Record(plist: plist)
        }
    }

    /// True when the installed helper is this layout and exactly this build. Any
    /// other helper would refuse the app, so it counts as not installed.
    static func isInstalled(forCDHash cdhash: String?, record: Record? = Record.load()) -> Bool {
        guard let cdhash, let record else { return false }
        return record == Record(versionTag: versionTag, cdhash: cdhash)
    }

    // MARK: - Root-only paths

    /// True when `path` and every directory above it are owned by root, writable by
    /// no one else, and not symlinks. Owning the file alone is not enough: a parent
    /// directory others can write lets the file be renamed away and replaced.
    static func isRootOnly(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }

        var current = path
        while true {
            var st = stat()
            guard lstat(current, &st) == 0,
                  st.st_uid == 0,
                  (st.st_mode & S_IFMT) != S_IFLNK,
                  (st.st_mode & (S_IWGRP | S_IWOTH)) == 0 else { return false }
            if current == "/" { return true }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    // MARK: - Installation

    enum Outcome: Equatable {
        case installed
        case cancelled
        case failed(String)
    }

    /// Copies `appBundlePath` into place as root and loads the LaunchDaemon, behind
    /// one administrator password prompt. Blocks until the prompt is answered, so
    /// call it off the main thread.
    static func install(appBundlePath: String, cdhash: String) -> Outcome {
        guard CodeIdentity.isWellFormedCDHash(cdhash) else {
            return .failed("This copy of Heimdall is not code signed, so the helper cannot verify it.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = osascriptLines.flatMap { ["-e", $0] }
            + [installScript, appBundlePath, cdhash, "Heimdall needs to install its fan control helper."]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failed("The installer could not be started: \(error.localizedDescription)")
        }
        // Drain before waiting, so a long failure message cannot fill the pipe and hang.
        let output = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        if process.terminationStatus == 0 { return .installed }
        // A dismissed password prompt is AppleScript error -128, "User canceled."
        if output.contains("(-128)") { return .cancelled }
        return .failed(failureMessage(fromOsascriptError: output))
    }

    /// osascript reports a failed shell script as "…execution error: <stderr> (<status>)".
    static func failureMessage(fromOsascriptError output: String) -> String {
        var message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let marker = message.range(of: "execution error: ") {
            message = String(message[marker.upperBound...])
        }
        if message.hasSuffix(")"), let open = message.range(of: " (", options: .backwards) {
            message = String(message[..<open.lowerBound])
        }
        return message.isEmpty ? "The helper could not be installed." : message
    }

    /// `do shell script` receives a fixed command line. The script and its arguments
    /// travel as osascript arguments and are quoted by AppleScript itself, so nothing
    /// dynamic is ever spliced into AppleScript or shell source.
    static let osascriptLines = [
        "on run argv",
        #"do shell script "/bin/sh -c " & quoted form of (item 1 of argv) & " heimdall-helper-install " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) with prompt (item 4 of argv) with administrator privileges"#,
        "end run",
    ]

    /// Runs as root. $1 is the app bundle to copy, $2 the cdhash that app reported
    /// for itself. It generates the LaunchDaemon plist itself rather than accepting
    /// one: a plist written by the app would sit in a user-writable temp directory
    /// between the password prompt and this script reading it.
    static let installScript = #"""
    set -eu

    # Validate first — before the root check and before anything touches the disk —
    # so a malformed request does nothing at all.
    src=${1-}
    expected=${2-}
    case "$expected" in
      ''|*[!0-9a-f]*) echo "The app reported a malformed code signature hash." >&2; exit 64 ;;
    esac
    if [ "${#expected}" -ne 40 ]; then
      echo "The app reported a malformed code signature hash." >&2; exit 64
    fi
    case "$src" in
      /*.app) ;;
      *) echo "The helper can only be installed from an app bundle." >&2; exit 64 ;;
    esac
    if [ ! -d "$src" ]; then
      echo "The app to install the helper from no longer exists." >&2; exit 64
    fi
    if [ "$(/usr/bin/id -u)" -ne 0 ]; then
      echo "Installing the helper requires administrator privileges." >&2; exit 77
    fi

    label='\#(label)'
    dest='\#(bundlePath)'
    plist='\#(plistPath)'
    log='\#(logPath)'

    # Stage inside the root-only directory, so nothing unprivileged can reach the
    # copy between verifying it and using it.
    /bin/mkdir -p /Library/PrivilegedHelperTools
    stage=$(/usr/bin/mktemp -d "/Library/PrivilegedHelperTools/.$label.XXXXXX")
    trap '/bin/rm -rf "$stage"' EXIT

    /usr/bin/ditto "$src" "$stage/helper.app"
    /usr/bin/xattr -cr "$stage/helper.app"
    /usr/sbin/chown -R root:wheel "$stage/helper.app"
    /bin/chmod -R go-w "$stage/helper.app"

    # The copy must be the build that asked to be installed: validly signed, with
    # the cdhash that app reported. A bundle swapped or modified after the password
    # prompt fails here.
    if ! /usr/bin/codesign --verify --strict --deep "$stage/helper.app" 2>/dev/null; then
      echo "The copied app's code signature is not valid." >&2; exit 65
    fi
    actual=$(/usr/bin/codesign -dvvv "$stage/helper.app" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')
    if [ "$actual" != "$expected" ]; then
      echo "The copied app is not the build that requested installation." >&2; exit 65
    fi

    /bin/launchctl bootout "system/$label" 2>/dev/null || true
    /bin/rm -rf "$dest"
    /bin/mv "$stage/helper.app" "$dest"

    /bin/cat > "$stage/daemon.plist" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>$label</string>
        <key>HeimdallDaemonVersion</key>
        <string>\#(versionTag)</string>
        <key>HeimdallCDHash</key>
        <string>$expected</string>
        <key>ProgramArguments</key>
        <array>
            <string>$dest/Contents/MacOS/Heimdall</string>
            <string>--smc-daemon</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardOutPath</key>
        <string>$log</string>
        <key>StandardErrorPath</key>
        <string>$log</string>
    </dict>
    </plist>
    PLIST
    /usr/bin/install -m 644 -o root -g wheel "$stage/daemon.plist" "$plist"
    /bin/launchctl bootstrap system "$plist"
    """#
}
