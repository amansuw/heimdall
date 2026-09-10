import Foundation

/// Whether this build can update itself.
///
/// In-app updates need a feed and the EdDSA public key that every update is
/// verified against before it is installed. Release builds get the key from the
/// release workflow; builds from source have none, and for them the updater stays
/// off instead of failing every scheduled check.
struct UpdateConfiguration: Equatable, Sendable {
    let feedURL: URL
    let publicKey: String

    init?(infoDictionary: [String: Any]) {
        guard let feed = (infoDictionary["SUFeedURL"] as? String).flatMap(URL.init(string:)),
              feed.scheme == "https",
              let key = (infoDictionary["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces),
              // An Ed25519 public key is 32 bytes; anything else cannot verify an update.
              let decoded = Data(base64Encoded: key), decoded.count == 32
        else { return nil }
        feedURL = feed
        publicKey = key
    }

    static var current: UpdateConfiguration? {
        UpdateConfiguration(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }
}
