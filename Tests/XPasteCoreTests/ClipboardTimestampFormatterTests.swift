import Foundation
import XCTest
@testable import XPasteCore

final class ClipboardTimestampFormatterTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    func testRelativeTimeBoundaries() throws {
        let now = try date(2026, 8, 1, 15, 0, 0)
        XCTAssertEqual(display(secondsAgo: 0, now: now), "刚刚")
        XCTAssertEqual(display(secondsAgo: 59, now: now), "刚刚")
        XCTAssertEqual(display(secondsAgo: 60, now: now), "1分钟前")
        XCTAssertEqual(display(secondsAgo: 5 * 60 + 42, now: now), "5分钟前")
        XCTAssertEqual(display(secondsAgo: 59 * 60 + 59, now: now), "59分钟前")
        XCTAssertEqual(display(secondsAgo: 60 * 60, now: now), "1小时前")
        XCTAssertEqual(display(secondsAgo: 23 * 60 * 60 + 59, now: now), "23小时前")
    }

    func testOlderDatesUseUsefulCalendarLabels() throws {
        let now = try date(2026, 8, 1, 15, 0, 0)
        XCTAssertEqual(
            ClipboardTimestampFormatter.display(try date(2026, 7, 31, 14, 20, 0), relativeTo: now, calendar: calendar),
            "昨天 14:20"
        )
        XCTAssertEqual(
            ClipboardTimestampFormatter.display(try date(2026, 6, 8, 9, 5, 0), relativeTo: now, calendar: calendar),
            "6月8日 09:05"
        )
        XCTAssertEqual(
            ClipboardTimestampFormatter.display(try date(2025, 12, 31, 23, 4, 0), relativeTo: now, calendar: calendar),
            "2025年12月31日 23:04"
        )
    }

    func testFutureClockSkewAndFullTimestamp() throws {
        let now = try date(2026, 8, 1, 15, 0, 0)
        XCTAssertEqual(
            ClipboardTimestampFormatter.display(now.addingTimeInterval(4 * 60), relativeTo: now, calendar: calendar),
            "刚刚"
        )
        XCTAssertEqual(
            ClipboardTimestampFormatter.display(try date(2026, 8, 2, 9, 30, 0), relativeTo: now, calendar: calendar),
            "8月2日 09:30"
        )
        XCTAssertEqual(
            ClipboardTimestampFormatter.full(try date(2026, 8, 1, 14, 23, 7), calendar: calendar),
            "2026年8月1日 14:23:07"
        )
    }

    private func display(secondsAgo: TimeInterval, now: Date) -> String {
        ClipboardTimestampFormatter.display(
            now.addingTimeInterval(-secondsAgo),
            relativeTo: now,
            calendar: calendar
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ second: Int
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )))
    }
}
