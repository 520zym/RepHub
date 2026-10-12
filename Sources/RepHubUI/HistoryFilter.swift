import Foundation
import VersionControlCore

/// 仅用于已经读取到客户端的提交记录；不会改变版本控制工具的历史读取范围。
struct HistoryFilter: Equatable {
    var author = ""
    var startDate: Date?
    var endDate: Date?

    var isActive: Bool {
        !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || startDate != nil || endDate != nil
    }

    var hasInvalidDateRange: Bool {
        guard let startDate, let endDate else { return false }
        return startDate > endDate
    }

    mutating func clear() {
        author = ""
        startDate = nil
        endDate = nil
    }

    func matches(_ revision: Revision, calendar: Calendar = .current) -> Bool {
        let authorQuery = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if !authorQuery.isEmpty, !revision.author.localizedCaseInsensitiveContains(authorQuery) {
            return false
        }
        if let startDate, revision.date < calendar.startOfDay(for: startDate) {
            return false
        }
        if let endDate {
            guard let firstMomentAfterEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) else {
                return false
            }
            if revision.date >= firstMomentAfterEnd { return false }
        }
        return true
    }

    func filtered(_ revisions: [Revision], search: String, calendar: Calendar = .current) -> [Revision] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return revisions.filter { revision in
            matches(revision, calendar: calendar) && (query.isEmpty || matchesSearch(revision, query: query))
        }
    }

    private func matchesSearch(_ revision: Revision, query: String) -> Bool {
        revision.subject.localizedCaseInsensitiveContains(query)
            || revision.author.localizedCaseInsensitiveContains(query)
            || revision.id.localizedCaseInsensitiveContains(query)
            || revision.references.joined(separator: " ").localizedCaseInsensitiveContains(query)
    }
}

extension HistoryFilter {
    var dateRangeDescription: String? {
        guard startDate != nil || endDate != nil else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        switch (startDate, endDate) {
        case let (.some(start), .some(end)): return "\(formatter.string(from: start)) 至 \(formatter.string(from: end))"
        case let (.some(start), nil): return "自 \(formatter.string(from: start))"
        case let (nil, .some(end)): return "截至 \(formatter.string(from: end))"
        case (nil, nil): return nil
        }
    }
}
