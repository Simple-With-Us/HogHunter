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
/// link is the real fix and is tracked as a follow-up.  A Cloudflare Tunnel
/// daemon on this Mac arrives over loopback; `resolvingForwardedClient(in:)`
/// judges those requests by the client the tunnel names, so a phone on a
/// tunnel reads the snapshot like any outside client and controls nothing.
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

    /// Key for a forwarded request whose client address cannot be read.
    static let unreadableForwardedKey = "forwarded"

    /// The IPv6 loopback address (`::1`) as `make(ipv6:)` keys it.
    private static let ipv6LoopbackKey = String(repeating: "0", count: 31) + "1"

    /// Whether the connection came from this Mac itself, which is where a
    /// tunnel daemon such as `cloudflared` connects from.
    var isLoopback: Bool {
        key.hasPrefix("127.") || key == Self.ipv6LoopbackKey
    }

    /// The peer a request should be judged as.  A Cloudflare Tunnel daemon on
    /// this Mac connects over loopback, which would make every tunnel request
    /// look local, so a loopback request that names its client in a forwarded
    /// header is judged by that client instead: a public address is not
    /// trusted and is throttled under its own key.  A loopback request with
    /// tunnel marks but no client address it can read is not trusted either.
    ///
    /// Forwarded headers from any other peer are ignored.  A LAN or Tailscale
    /// phone talks to the Mac directly, and honouring its headers would let it
    /// borrow another address's throttle key (locking that client out) or
    /// rotate keys to dodge the per-address limit on wrong codes.
    func resolvingForwardedClient(in request: Data) -> CompanionPeer {
        guard isLoopback else { return self }
        if let clientIP = CompanionHTTP.forwardedClientIP(in: request) {
            return Self.forwarded(clientIP)
        }
        if CompanionHTTP.isForwardedTunnel(in: request) {
            return CompanionPeer(key: Self.unreadableForwardedKey, isTrusted: false)
        }
        return self
    }

    /// A forwarded client address judged like a direct peer's.  Anything that
    /// is not a bare IPv4 or IPv6 address is not trusted.
    static func forwarded(_ clientIP: String) -> CompanionPeer {
        if let v4 = IPv4Address(clientIP) {
            return make(ipv4: [UInt8](v4.rawValue))
        }
        if let v6 = IPv6Address(clientIP) {
            return make(ipv6: [UInt8](v6.rawValue))
        }
        return CompanionPeer(key: unreadableForwardedKey, isTrusted: false)
    }

    /// Splits an address typed on the phone into a host and an optional port.
    /// `name:port` and `a.b.c.d:port` split on their one colon.  An IPv6
    /// literal takes a port only in brackets (`[fd7a:115c:a1e0::1]:24240`),
    /// because a bare one's last group can be all digits (`fd7a:115c:a1e0::1`)
    /// and would otherwise be read as a port.  The brackets are dropped.
    static func splitHostAndPort(_ raw: String) -> (host: String, port: Int?) {
        if raw.hasPrefix("["), let close = raw.firstIndex(of: "]") {
            let host = String(raw[raw.index(after: raw.startIndex)..<close])
            let rest = raw[raw.index(after: close)...]
            if rest.hasPrefix(":"), let port = Int(rest.dropFirst()) {
                return (host, port)
            }
            return (host, nil)
        }
        let colons = raw.filter { $0 == ":" }.count
        if colons == 1, let colon = raw.firstIndex(of: ":"), let port = Int(raw[raw.index(after: colon)...]) {
            return (String(raw[..<colon]), port)
        }
        return (raw, nil)
    }

    /// Whether the phone should treat the Mac it is about to send a secret to
    /// as being on the local network or Tailscale.  A Bonjour service was found
    /// on the local link; an address is judged like a peer's; a name is trusted
    /// only if it is a MagicDNS, `.local` or `localhost` name, because any other
    /// name can point anywhere.  The port says nothing: 443 proves neither that
    /// the link is encrypted nor who answers, and a tunnel's edge reads what it
    /// carries.  The Mac refuses controls from outside regardless, but it reads
    /// a request before it can refuse it, so a secret must not be sent to a Mac
    /// that is only reachable over the public internet or a tunnel.
    static func isTrustedEndpoint(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .service:
            return true
        case .hostPort(let host, _):
            if case .name(let name, _) = host {
                // A fully qualified name may end in a dot ("studio.local.").  Only
                // that dot is dropped: a leading one is not part of a real name.
                var lowered = name.lowercased()
                if lowered.hasSuffix(".") { lowered.removeLast() }
                return lowered.hasSuffix(".ts.net") || lowered.hasSuffix(".local") || lowered == "localhost"
            }
            return from(endpoint).isTrusted
        default:
            return false
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
