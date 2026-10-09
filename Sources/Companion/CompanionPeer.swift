import Foundation
import Network

/// Who is on the other end of a connection, as far as the Mac can tell.
///
/// The companion link is plain HTTP, so anything that changes the Mac or hands
/// out a credential is accepted only from the local network or Tailscale.  A
/// phone reaching the Mac through a forwarded port arrives from a public
/// address and may read the snapshot with a valid token, nothing more.
///
/// This judges the address the connection arrived from.  A router that rewrites
/// forwarded traffic to its own LAN address (SNAT, hairpin NAT) makes that
/// traffic look local, so port forwarding is still not safe.  Encrypting the
/// link is the real fix and is tracked as a follow-up.
struct CompanionPeer: Equatable, Sendable {
    /// The client's address with zone ids and IPv4-in-IPv6 wrapping removed,
    /// so one client is one key.  The auth throttle counts by this.
    var key: String
    /// Loopback, link-local, private (RFC 1918 and unique-local) or Tailscale.
    var isTrusted: Bool

    /// Used when the address cannot be read.  Never trusted.
    static let unknown = CompanionPeer(key: "unknown", isTrusted: false)

    static func from(_ endpoint: NWEndpoint?) -> CompanionPeer {
        guard case let .hostPort(host, _)? = endpoint else { return .unknown }
        switch host {
        case .ipv4(let address):
            return make(ipv4: [UInt8](address.rawValue))
        case .ipv6(let address):
            return make(ipv6: [UInt8](address.rawValue))
        case .name(let name, _):
            // An accepted connection always has a numeric peer; a name means
            // something unexpected, so it is not trusted.
            return CompanionPeer(key: name, isTrusted: false)
        @unknown default:
            return .unknown
        }
    }

    static func make(ipv4 bytes: [UInt8]) -> CompanionPeer {
        guard bytes.count == 4 else { return .unknown }
        return CompanionPeer(key: bytes.map(String.init).joined(separator: "."), isTrusted: isTrustedIPv4(bytes))
    }

    static func make(ipv6 bytes: [UInt8]) -> CompanionPeer {
        guard bytes.count == 16 else { return .unknown }
        if let embedded = mappedIPv4(bytes) {
            return make(ipv4: embedded)
        }
        return CompanionPeer(key: bytes.map { String(format: "%02x", $0) }.joined(), isTrusted: isTrustedIPv6(bytes))
    }

    /// `::ffff:a.b.c.d`, how a dual-stack socket shows an IPv4 client.
    private static func mappedIPv4(_ b: [UInt8]) -> [UInt8]? {
        guard b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff else { return nil }
        return Array(b[12..<16])
    }

    static func isTrustedIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (127, _): return true                         // loopback
        case (10, _): return true                          // RFC 1918
        case (172, 16...31): return true                   // RFC 1918
        case (192, 168): return true                       // RFC 1918
        case (169, 254): return true                       // link-local
        case (100, 64...127): return true                  // carrier-grade NAT range, which Tailscale uses
        default: return false
        }
    }

    static func isTrustedIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if let embedded = mappedIPv4(b) { return isTrustedIPv4(embedded) }
        if b[0..<15].allSatisfy({ $0 == 0 }), b[15] == 1 { return true }   // ::1
        if b[0] == 0xfe, (b[1] & 0xc0) == 0x80 { return true }              // fe80::/10 link-local
        if (b[0] & 0xfe) == 0xfc { return true }                            // fc00::/7 unique-local, includes Tailscale's fd7a:115c:a1e0::/48
        return false
    }
}
