import Foundation

/// Error codes of the notify_* bridge messages (the raw value is sent as `error_code`).
enum NotifyFailure: String, Error {
    case invalidArgument = "invalid_argument"
    case permissionDenied = "permission_denied"
    case limitReached = "limit_reached"
    case failed = "notify_failed"
}

/// Pure validation of notify_* payloads (Foundation only, covered by EveLogicTests).
enum NotifyValidation {
    static let idPrefix = "eve.notify."
    static let maxIDBytes = 64
    static let minAfterSec = 5
    static let maxAfterSec = 3600
    static let maxPending = 8

    /// `id`: 1-64 bytes of [A-Za-z0-9_-] (ASCII only, so bytes == characters).
    /// The byte length is checked first, so an oversized string is rejected before any per-character work.
    static func parseID(_ payload: [String: Any]) -> String? {
        guard let id = payload["id"] as? String else { return nil }
        let n = id.utf8.count
        guard n >= 1, n <= maxIDBytes else { return nil }
        for b in id.utf8 {
            switch b {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2D: continue   // 0-9 A-Z a-z _ -
            default: return nil
            }
        }
        return id
    }

    /// `afterSec`: a finite number in 5...3600. A fractional value is rounded to the nearest whole second
    /// (halves away from zero) AFTER the range check, so 4.6 is rejected and 5.4 becomes 5.
    static func parseSchedule(_ payload: [String: Any]) -> Result<(id: String, afterSec: Int), NotifyFailure> {
        guard let id = parseID(payload) else { return .failure(.invalidArgument) }
        guard let n = payload["afterSec"] as? Double, n.isFinite,
              n >= Double(minAfterSec), n <= Double(maxAfterSec) else { return .failure(.invalidArgument) }
        return .success((id, Int(n.rounded())))
    }
}
