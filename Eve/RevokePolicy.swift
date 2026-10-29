import Foundation

// Pure logic for the pending session revoke (no Keychain, no network, Foundation only) so it can be unit-tested
// in the EveLogicTests target (this file is compiled into both the app and the tests).

enum RevokePolicy {
    static let maxAge: TimeInterval = 30 * 24 * 3600        // matches the server's 30-day idle expiry
    static let maxFutureSkew: TimeInterval = 24 * 3600      // a savedAt further in the future means the clock moved
    static let maxPermanentResponses = 3
    static let maxFailedResponses = 10
    static let maxBackoff: TimeInterval = 6 * 3600

    enum Outcome: Equatable { case done, permanent, transient }

    /// 204/200: revoked. 401: session already invalid. 5xx/408/429: try again later. Anything else
    /// (403 origin/identity rejection, 404, 3xx because redirects are not followed, other 4xx): permanent.
    static func outcome(forStatus code: Int) -> Outcome {
        switch code {
        case 200, 204, 401: return .done
        case 408, 429, 500...599: return .transient
        default: return .permanent
        }
    }

    enum Expiry: Equatable { case fresh, expired, clockSkew }

    /// An entry past the TTL, or saved "in the future" (clock moved back), is due for one last attempt and deletion.
    static func expiry(savedAt: TimeInterval, now: TimeInterval) -> Expiry {
        if savedAt > now + maxFutureSkew { return .clockSkew }
        if now - savedAt >= maxAge { return .expired }
        return .fresh
    }

    static func minInterval(attempts: Int) -> TimeInterval {
        min(30 * pow(2, Double(min(max(attempts, 0), 20))), maxBackoff)
    }

    /// True while a non-forced attempt must still wait. A `lastAttempt` in the future (clock moved back) is treated
    /// as "never attempted", so a wrong clock cannot block retries.
    static func shouldWait(lastAttempt: TimeInterval, attempts: Int, now: TimeInterval) -> Bool {
        guard lastAttempt <= now else { return false }
        return now - lastAttempt < minInterval(attempts: attempts)
    }

    static func shouldGiveUp(attempts: Int, permanentFailures: Int) -> Bool {
        permanentFailures >= maxPermanentResponses || attempts >= maxFailedResponses
    }
}

struct PendingEntry: Codable, Equatable {
    var token: String
    var savedAt: TimeInterval
    var lastAttempt: TimeInterval = 0
    var attempts: Int = 0
    var permanentFailures: Int = 0

    init(token: String, savedAt: TimeInterval) {
        self.token = token
        self.savedAt = savedAt
    }

    // Bookkeeping fields are optional on decode, so later versions can add fields without invalidating old items.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        savedAt = try c.decode(TimeInterval.self, forKey: .savedAt)
        lastAttempt = try c.decodeIfPresent(TimeInterval.self, forKey: .lastAttempt) ?? 0
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        permanentFailures = try c.decodeIfPresent(Int.self, forKey: .permanentFailures) ?? 0
    }
}

/// A small bounded list of pending revokes (one Keychain item holds the whole list).
struct PendingList: Codable, Equatable {
    static let schemaVersion = 1
    static let maxEntries = 3

    var v: Int = PendingList.schemaVersion
    var entries: [PendingEntry] = []

    var isEmpty: Bool { entries.isEmpty }

    /// Adds `token`. The same token again changes nothing (savedAt and counters are kept). When the list is full the
    /// oldest entry is dropped; the number of dropped entries is returned so the caller can tell the user.
    @discardableResult
    mutating func add(token: String, now: TimeInterval) -> Int {
        guard !token.isEmpty, !entries.contains(where: { $0.token == token }) else { return 0 }
        entries.append(PendingEntry(token: token, savedAt: now))
        var dropped = 0
        while entries.count > Self.maxEntries { entries.removeFirst(); dropped += 1 }
        return dropped
    }

    /// Removes only the entry holding exactly `token` (compare-and-clear).
    mutating func remove(token: String) { entries.removeAll { $0.token == token } }

    /// Replaces bookkeeping of the entry with the same token, keeping its original savedAt. No-op if it is gone.
    mutating func update(_ entry: PendingEntry) {
        guard let i = entries.firstIndex(where: { $0.token == entry.token }) else { return }
        var next = entry
        next.savedAt = entries[i].savedAt
        entries[i] = next
    }

    /// Returns nil for anything that is not a valid current-version list (a bare token string, other JSON, a newer
    /// schema). Callers must delete such an item; it is never interpreted as a token. The only accepted older shape
    /// is the single structured `PendingEntry` JSON written by the first 0.1.1 builds, which is migrated to a list.
    static func decode(_ data: Data) -> PendingList? {
        let dec = JSONDecoder()
        if let list = try? dec.decode(PendingList.self, from: data) {
            guard list.v == schemaVersion, list.entries.count <= maxEntries,
                  !list.entries.contains(where: { $0.token.isEmpty }) else { return nil }
            return list
        }
        if let legacy = try? dec.decode(PendingEntry.self, from: data), !legacy.token.isEmpty {
            return PendingList(entries: [legacy])
        }
        return nil
    }

    func encode() -> Data? { try? JSONEncoder().encode(self) }
}
