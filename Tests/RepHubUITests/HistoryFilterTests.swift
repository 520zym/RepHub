import Foundation
import XCTest
@testable import RepHubUI
import VersionControlCore

final class HistoryFilterTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testDateRangeIncludesEntireEndDay() {
        let filter = HistoryFilter(startDate: date(2026, 10, 11, 0, 0), endDate: date(2026, 10, 11, 0, 0))
        let revisions = [
            revision("late", author: "zym", date: date(2026, 10, 11, 23, 59)),
            revision("next", author: "zym", date: date(2026, 10, 12, 0, 0)),
            revision("previous", author: "zym", date: date(2026, 10, 10, 23, 59)),
        ]

        XCTAssertEqual(filter.filtered(revisions, search: "", calendar: calendar).map(\.id), ["late"])
    }

    func testAuthorAndDateFiltersComposeWithSearch() {
        let filter = HistoryFilter(author: "zhang", startDate: date(2026, 10, 10, 0, 0), endDate: date(2026, 10, 12, 0, 0))
        let revisions = [
            revision("one", author: "ZhangYiming", date: date(2026, 10, 11, 12, 0), message: "修复同步"),
            revision("two", author: "ZhangYiming", date: date(2026, 10, 13, 12, 0), message: "修复同步"),
            revision("three", author: "other", date: date(2026, 10, 11, 12, 0), message: "修复同步"),
            revision("four", author: "ZhangYiming", date: date(2026, 10, 11, 12, 0), message: "新增功能"),
        ]

        XCTAssertEqual(filter.filtered(revisions, search: "同步", calendar: calendar).map(\.id), ["one"])
    }

    func testNoMatchInLoadedPageCanMatchWhenOlderPageIsAppended() {
        let filter = HistoryFilter(author: "legacy")
        let firstLoadedPage = [revision("new", author: "current", date: date(2026, 10, 12, 10, 0))]
        let olderPage = [revision("old", author: "legacy maintainer", date: date(2026, 10, 1, 10, 0))]

        XCTAssertTrue(filter.filtered(firstLoadedPage, search: "", calendar: calendar).isEmpty)
        XCTAssertEqual(filter.filtered(firstLoadedPage + olderPage, search: "", calendar: calendar).map(\.id), ["old"])
    }

    private func revision(_ id: String, author: String, date: Date, message: String = "提交") -> Revision {
        Revision(id: id, author: author, date: date, message: message)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
