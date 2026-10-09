import CryptoKit
import Foundation
import Security

/// One iPhone the Mac has paired.  The Mac keeps only a hash of the phone's
/// credential, so the stored list cannot be replayed against the server.
struct CompanionDevice: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// SHA-256 of the device token, as lowercase hex.
    var tokenHash: String
    var pairedAt: Date
    var lastSeenAt: Date?
}

/// The phones allowed to talk to this Mac, one credential each.
///
/// The old design shared one 8 character code between every phone, so a leaked
/// code meant re-pairing everything, and nothing identified which phone did what.
/// Now pairing (typing the code, or approving on the Mac) issues the phone its
/// own long random token.  The Mac stores a hash, lists the phone in Settings,
/// and revoking it cuts off that phone alone.
///
/// Thread safe: the server queue authenticates while the main thread lists and
/// revokes.
final class CompanionDeviceRegistry: @unchecked Sendable {
    static let defaultsKey = "companionDevices"
    /// Most phones remembered.  Past this the least recently seen is dropped.
    static let capacity = 32
    /// How often "last seen" is written to disk, at most.
    static let seenWriteInterval: TimeInterval = 60

    private let lock = NSLock()
    /// Nil keeps the list in memory only (tests, and a bare server).
    private let defaults: UserDefaults?
    private var stored: [CompanionDevice]
    private var lastWrite = Date.distantPast
    private var changeHandler: (@Sendable () -> Void)?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.defaultsKey),
           let decoded = try? CompanionJSON.decoder().decode([CompanionDevice].self, from: data) {
            stored = decoded
        } else {
            stored = []
        }
    }

    /// Called after the list changes (a phone paired, one revoked), on the
    /// thread that changed it.  Not called for "last seen" updates.
    func onChange(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        changeHandler = handler
        lock.unlock()
    }

    var devices: [CompanionDevice] {
        lock.lock()
        defer { lock.unlock() }
        return stored.sorted { $0.pairedAt > $1.pairedAt }
    }

    /// Pairs a phone.  The token is returned once and never stored.
    func issue(name: String, now: Date = Date()) -> (device: CompanionDevice, token: String) {
        let token = Self.makeToken()
        let cleanName = CompanionHTTP.sanitizedDeviceName(name)
        let device = CompanionDevice(
            id: UUID().uuidString,
            name: cleanName.isEmpty ? "An iPhone" : cleanName,
            tokenHash: Self.hash(token),
            pairedAt: now,
            lastSeenAt: now
        )
        lock.lock()
        stored.append(device)
        if stored.count > Self.capacity {
            let drop = stored.sorted { ($0.lastSeenAt ?? $0.pairedAt) < ($1.lastSeenAt ?? $1.pairedAt) }.first?.id
            stored.removeAll { $0.id == drop }
        }
        persistLocked(now: now, force: true)
        let handler = changeHandler
        lock.unlock()
        handler?()
        return (device, token)
    }

    /// True when `token` belongs to a paired phone.  Notes that it was just
    /// seen.  Every stored hash is compared, so the time taken does not say
    /// which phone matched.
    func authenticate(_ token: String, now: Date = Date()) -> Bool {
        guard CompanionToken.isDeviceToken(token) else { return false }
        let presented = Self.hash(token)
        lock.lock()
        defer { lock.unlock() }
        var matched: Int?
        for (index, device) in stored.enumerated() where CompanionToken.matches(presented, device.tokenHash) {
            matched = index
        }
        guard let matched else { return false }
        stored[matched].lastSeenAt = now
        persistLocked(now: now, force: false)
        return true
    }

    /// Cuts off one phone.  Returns false if it was not there.
    @discardableResult
    func revoke(id: String) -> Bool {
        lock.lock()
        let before = stored.count
        stored.removeAll { $0.id == id }
        let changed = stored.count != before
        if changed { persistLocked(now: Date(), force: true) }
        let handler = changeHandler
        lock.unlock()
        if changed { handler?() }
        return changed
    }

    func revokeAll() {
        lock.lock()
        let changed = !stored.isEmpty
        stored.removeAll()
        if changed { persistLocked(now: Date(), force: true) }
        let handler = changeHandler
        lock.unlock()
        if changed { handler?() }
    }

    private func persistLocked(now: Date, force: Bool) {
        guard force || now.timeIntervalSince(lastWrite) >= Self.seenWriteInterval else { return }
        lastWrite = now
        if let data = try? CompanionJSON.encoder().encode(stored) {
            defaults?.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Tokens

    /// `hh1_` plus 32 URL-safe characters from 24 random bytes: 192 bits, far
    /// past guessing, and not something a person types.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Swift's default generator is also cryptographically secure on Apple platforms.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<24).map { _ in UInt8.random(in: 0...255, using: &generator) }
        }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return CompanionToken.devicePrefix + encoded
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
