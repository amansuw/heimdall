import Foundation

// Handle daemon/helper modes BEFORE SwiftUI initialization.
// SwiftUI's @main tries to initialize NSApplication/GUI which crashes
// when running as a headless LaunchDaemon.

if CommandLine.arguments.contains("--smc-daemon") {
    SMCDaemon.runPersistent()
    // Never returns
}

if CommandLine.arguments.contains("--reset-fans") {
    let smc = SMCKit.shared
    let numFans = smc.getNumberOfFans()
    for i in 0..<numFans {
        _ = smc.setFanMode(fanIndex: i, mode: .automatic)
    }
    if let val = smc.readKey("FS! ") {
        _ = smc.writeKey("FS! ", bytes: [UInt8](repeating: 0, count: Int(val.dataSize)))
    }
    print("Fans reset to automatic.")
    exit(0)
}

// Normal GUI app launch
HeimdallApp.main()
