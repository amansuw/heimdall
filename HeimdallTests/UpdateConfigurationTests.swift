import Foundation
import Testing

private let releaseFeed = "https://github.com/amansuw/heimdall/releases/latest/download/appcast.xml"
private let validKey = Data(repeating: 7, count: 32).base64EncodedString()

@Suite("Update configuration")
struct UpdateConfigurationTests {

    @Test func aFeedAndAKeyEnableUpdates() throws {
        let configuration = try #require(UpdateConfiguration(infoDictionary: [
            "SUFeedURL": releaseFeed,
            "SUPublicEDKey": validKey,
        ]))
        #expect(configuration.feedURL.absoluteString == releaseFeed)
        #expect(configuration.publicKey == validKey)
    }

    /// Source builds leave the key empty, which must switch updates off rather
    /// than start an updater that can never verify anything.
    @Test(arguments: [
        "", "   ", "not base64!",
        Data(repeating: 1, count: 16).base64EncodedString(),
        Data(repeating: 1, count: 64).base64EncodedString(),
        "$(SPARKLE_PUBLIC_KEY)",
    ])
    func withoutAUsableKeyUpdatesStayOff(key: String) {
        #expect(UpdateConfiguration(infoDictionary: ["SUFeedURL": releaseFeed, "SUPublicEDKey": key]) == nil)
    }

    @Test func aMissingKeyOrFeedSwitchesUpdatesOff() {
        #expect(UpdateConfiguration(infoDictionary: ["SUFeedURL": releaseFeed]) == nil)
        #expect(UpdateConfiguration(infoDictionary: ["SUPublicEDKey": validKey]) == nil)
    }

    @Test func aPlainHTTPFeedIsRefused() {
        let feed = releaseFeed.replacingOccurrences(of: "https://", with: "http://")
        #expect(UpdateConfiguration(infoDictionary: ["SUFeedURL": feed, "SUPublicEDKey": validKey]) == nil)
    }

    /// The committed Info.plist must take the key from the build setting the release
    /// workflow fills in, and never carry a key of its own.
    @Test func theInfoPlistTakesTheKeyFromTheBuild() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Heimdall/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        #expect(plist["SUFeedURL"] as? String == releaseFeed)
        #expect(plist["SUPublicEDKey"] as? String == "$(SPARKLE_PUBLIC_KEY)")
        #expect(plist["CFBundleVersion"] as? String == "$(CURRENT_PROJECT_VERSION)")
        #expect(plist["CFBundleShortVersionString"] as? String == "$(MARKETING_VERSION)")
    }
}
