import Foundation
import Security

/// Who is running, by code signature.
///
/// Heimdall is ad-hoc signed, so its signature names no developer. What it does
/// pin is the cdhash: a hash over the executable and every bundle resource the
/// signature seals. Two processes with the same valid cdhash are running the same
/// build, byte for byte — the question the fan helper needs answered about
/// whoever connects to it.
enum CodeIdentity {

    /// The running process's cdhash as 40 lowercase hex digits, or nil if the
    /// process is not signed.
    static func currentCDHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// Exactly 40 lowercase ASCII hex digits. Anything else is refused before it
    /// can reach a code-signing requirement string or a root shell argument.
    static func isWellFormedCDHash(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// nil when the process on the other end of a connected local socket is validly
    /// signed with exactly `cdhash`; otherwise the reason it is not.
    ///
    /// The peer is identified by the connection's audit token, not its pid: a pid
    /// can be reused between connecting and being checked, an audit token cannot.
    static func rejectionReason(forPeerOf fd: Int32, requiringCDHash cdhash: String) -> String? {
        guard isWellFormedCDHash(cdhash) else { return "the expected cdhash is malformed" }

        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else {
            return "could not read the peer's audit token (errno \(errno))"
        }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }

        var guest: SecCode?
        var status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &guest)
        guard status == errSecSuccess, let guest else { return "could not resolve the peer's code (\(status))" }

        var requirement: SecRequirement?
        status = SecRequirementCreateWithString("cdhash H\"\(cdhash)\"" as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { return "could not build the signing requirement (\(status))" }

        status = SecCodeCheckValidity(guest, [], requirement)
        switch status {
        case errSecSuccess: return nil
        case errSecCSReqFailed: return "the peer is not this build of Heimdall"
        default: return "the peer's code signature is not valid (\(status))"
        }
    }
}
