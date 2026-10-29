import XCTest

final class NotificationValidationTests: XCTestCase {
    private func schedule(_ id: Any, _ after: Any) -> Result<(id: String, afterSec: Int), NotifyFailure> {
        NotifyValidation.parseSchedule(["id": id, "afterSec": after])
    }

    func testIDAccepted() {
        for id in ["a", "A", "0", "_", "-", "gen-123_ABC", String(repeating: "x", count: 64)] {
            XCTAssertEqual(NotifyValidation.parseID(["id": id]), id, id)
        }
    }

    func testIDRejected() {
        let bad: [Any] = ["", String(repeating: "x", count: 65), "a b", "a.b", "a/b", "a:b", "한글", "é", "a\n", "a\u{0}",
                          "🙂", 12, NSNull()]
        for id in bad { XCTAssertNil(NotifyValidation.parseID(["id": id]), "\(id)") }
        XCTAssertNil(NotifyValidation.parseID([:]))
    }

    /// Length is judged in UTF-8 bytes before any character check: a 64-scalar non-ASCII id is >64 bytes.
    func testIDLengthIsBytes() {
        XCTAssertNil(NotifyValidation.parseID(["id": String(repeating: "é", count: 33)]))      // 66 bytes
        XCTAssertNil(NotifyValidation.parseID(["id": String(repeating: "a", count: 1_000_000)]))
    }

    func testAfterSecRange() {
        for ok in [5, 30, 3600] as [Double] {
            if case .success(let r) = schedule("a", ok) { XCTAssertEqual(r.afterSec, Int(ok)) } else { XCTFail("\(ok)") }
        }
        for bad in [4.99, 4.6, 0, -1, 3600.01, 3601, Double.nan, Double.infinity, -Double.infinity] as [Double] {
            XCTAssertEqual(failure(schedule("a", bad)), .invalidArgument, "\(bad)")
        }
    }

    func testFractionalRounding() {
        XCTAssertEqual(afterSec(schedule("a", 5.4)), 5)
        XCTAssertEqual(afterSec(schedule("a", 5.5)), 6)
        XCTAssertEqual(afterSec(schedule("a", 29.49)), 29)
        XCTAssertEqual(afterSec(schedule("a", 3600.0)), 3600)
    }

    func testWrongTypes() {
        XCTAssertEqual(failure(schedule("a", "30")), .invalidArgument)
        XCTAssertEqual(failure(NotifyValidation.parseSchedule(["id": "a"])), .invalidArgument)
        XCTAssertEqual(failure(NotifyValidation.parseSchedule(["afterSec": 30.0])), .invalidArgument)
        XCTAssertEqual(failure(schedule("bad id", 30.0)), .invalidArgument)
    }

    func testExtraFieldsIgnored() {
        let r = NotifyValidation.parseSchedule(["id": "a", "afterSec": 30.0, "title": "secret", "body": "secret"])
        XCTAssertEqual(afterSec(r), 30)
    }

    // MARK: L-7 NSNumber input (WKWebView delivers JS numbers as NSNumber)

    func testNSNumberAfterSec() {
        XCTAssertEqual(afterSec(schedule("a", NSNumber(value: 30))), 30)
        XCTAssertEqual(afterSec(schedule("a", NSNumber(value: 30.0))), 30)
        XCTAssertEqual(afterSec(schedule("a", NSNumber(value: Float(30)))), 30)
        XCTAssertEqual(afterSec(schedule("a", NSNumber(value: 5.5))), 6)
        XCTAssertEqual(afterSec(schedule("a", NSNumber(value: 5))), 5)
        XCTAssertEqual(afterSec(schedule("a", NSNumber(value: 3600))), 3600)
    }

    func testNSNumberAfterSecRejected() {
        let bad: [NSNumber] = [NSNumber(value: 4), NSNumber(value: 0), NSNumber(value: -1), NSNumber(value: 3601),
                               NSNumber(value: 4.6), NSNumber(value: Double.nan), NSNumber(value: Double.infinity),
                               NSNumber(value: -Double.infinity), NSNumber(value: Double.greatestFiniteMagnitude),
                               NSNumber(value: Int.max), NSNumber(value: Int.min), NSNumber(value: UInt64.max),
                               NSNumber(value: true), NSNumber(value: false)]
        for n in bad { XCTAssertEqual(failure(schedule("a", n)), .invalidArgument, "\(n)") }
    }

    func testNSNumberAndNSStringIDs() {
        XCTAssertNil(NotifyValidation.parseID(["id": NSNumber(value: 12)]))
        XCTAssertNil(NotifyValidation.parseID(["id": NSNumber(value: true)]))
        XCTAssertEqual(NotifyValidation.parseID(["id": NSString(string: "gen-1")]), "gen-1")
        XCTAssertNil(NotifyValidation.parseID(["id": NSString(string: "a b")]))
        XCTAssertNil(NotifyValidation.parseID(["id": NSNull()]))
        XCTAssertNil(NotifyValidation.parseID(["id": NSArray()]))
        XCTAssertNil(NotifyValidation.parseID(["id": NSDictionary()]))
    }

    func testNSNumberWrongContainerTypes() {
        XCTAssertEqual(failure(schedule("a", NSString(string: "30"))), .invalidArgument)
        XCTAssertEqual(failure(schedule("a", NSNull())), .invalidArgument)
        XCTAssertEqual(failure(schedule("a", NSArray(object: NSNumber(value: 30)))), .invalidArgument)
    }

    private func failure(_ r: Result<(id: String, afterSec: Int), NotifyFailure>) -> NotifyFailure? {
        if case .failure(let f) = r { return f }
        return nil
    }
    private func afterSec(_ r: Result<(id: String, afterSec: Int), NotifyFailure>) -> Int? {
        if case .success(let v) = r { return v.afterSec }
        return nil
    }
}
