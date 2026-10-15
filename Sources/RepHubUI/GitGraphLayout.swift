import Foundation
import VersionControlCore

/// 将按拓扑顺序读取的 Git 提交转换为每一行可绘制的 lane；不为 SVN 调用。
enum GitGraphLayout {
    struct Row: Sendable {
        let currentLane: Int
        let incomingLaneCount: Int
        let parentLanes: [Int]
        let passThrough: [(source: Int, target: Int)]
        let laneCount: Int
        let hasIncomingCurrent: Bool
        let parentCount: Int
        let outgoingLaneIDs: [String]
    }

    static func rows(for revisions: [Revision], isCancelled: () -> Bool = { false }) -> [Row] {
        var lanes: [String] = []
        var rows: [Row] = []
        rows.reserveCapacity(revisions.count)
        for revision in revisions {
            guard !isCancelled() else { return [] }
            let existingLane = lanes.firstIndex(of: revision.id)
            if existingLane == nil {
                // 与已有分支无父子关系的提交放到尾部，保持已有 lane 的位置。
                lanes.append(revision.id)
            }
            let currentLane = lanes.firstIndex(of: revision.id) ?? 0
            let incomingIDs = lanes

            var nextLanes = incomingIDs
            nextLanes.remove(at: currentLane)
            var insertionIndex = currentLane
            for parent in revision.parents where !nextLanes.contains(parent) {
                nextLanes.insert(parent, at: min(insertionIndex, nextLanes.count))
                insertionIndex += 1
            }

            let parentLanes = revision.parents.compactMap { nextLanes.firstIndex(of: $0) }
            let passThrough: [(source: Int, target: Int)] = incomingIDs.enumerated().compactMap { index, id in
                guard id != revision.id, let target = nextLanes.firstIndex(of: id) else { return nil }
                return (source: index, target: target)
            }
            let row = Row(
                currentLane: currentLane,
                incomingLaneCount: incomingIDs.count,
                parentLanes: parentLanes,
                passThrough: passThrough,
                laneCount: max(incomingIDs.count, nextLanes.count),
                hasIncomingCurrent: existingLane != nil,
                parentCount: revision.parents.count,
                outgoingLaneIDs: nextLanes
            )
            lanes = nextLanes
            rows.append(row)
        }
        return rows
    }
}

/// 图谱保留真实轨道间距，通过共享视口查看超出的轨道，避免挤压提交摘要或把多条线重叠成一条。
struct HistoryGraphViewport {
    static let laneSpacing: CGFloat = 11
    static let inset: CGFloat = 7
    let totalLanes: Int
    let visibleLanes: Int
    let firstLane: Int
    var maximumFirstLane: Int { max(0, totalLanes - visibleLanes) }
    var hasOverflow: Bool { totalLanes > visibleLanes }
    var width: CGFloat { max(26, CGFloat(visibleLanes - 1) * Self.laneSpacing + Self.inset * 2) }

    init(totalLanes: Int, availableWidth: CGFloat, requestedFirstLane: Int = 0) {
        self.totalLanes = max(1, totalLanes)
        // 列表再宽也最多占六条轨道；窄列表给提交文字保留至少约八成空间。
        let budget = min(70, max(26, availableWidth * 0.18))
        visibleLanes = min(self.totalLanes, max(2, Int((budget - Self.inset * 2) / Self.laneSpacing) + 1))
        firstLane = min(max(0, requestedFirstLane), max(0, self.totalLanes - visibleLanes))
    }

    func x(for lane: Int) -> CGFloat { CGFloat(lane - firstLane) * Self.laneSpacing + Self.inset }
    func contains(_ lane: Int) -> Bool { lane >= firstLane && lane < firstLane + visibleLanes }
}
