import Foundation
import Testing

@Suite("Code identity")
struct CodeIdentityTests {

    @Test func theRunningProcessHasACDHash() throws {
        let hash = try #require(CodeIdentity.currentCDHash())
        #expect(CodeIdentity.isWellFormedCDHash(hash))
    }

    @Test(arguments: [
        "", "abc",
        String(repeating: "AB", count: 20),
        String(repeating: "ab", count: 21),
        String(repeating: "g0", count: 20),
        #"0000000000000000000000000000000000000" or anchor apple"#,
    ])
    func malformedHashesAreRejected(value: String) {
        #expect(!CodeIdentity.isWellFormedCDHash(value))
    }

    /// The helper's admission test, run over a real connection whose peer is this
    /// process.
    @Test func aPeerIsAcceptedOnlyWithItsOwnCDHash() throws {
        let own = try #require(CodeIdentity.currentCDHash())
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }

        #expect(CodeIdentity.rejectionReason(forPeerOf: fds[0], requiringCDHash: own) == nil)
        #expect(CodeIdentity.rejectionReason(forPeerOf: fds[0], requiringCDHash: String(repeating: "0", count: 40)) != nil)
        #expect(CodeIdentity.rejectionReason(forPeerOf: fds[0], requiringCDHash: "not a hash") != nil)
    }

    @Test func anUnconnectedSocketHasNoPeerToTrust() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(CodeIdentity.rejectionReason(forPeerOf: fd, requiringCDHash: String(repeating: "0", count: 40)) != nil)
    }
}
