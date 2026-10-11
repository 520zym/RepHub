import VersionControlCore

/// 将按拓扑顺序读取的 Git 提交转换为每一行可绘制的 lane；不为 SVN 调用。
enum GitGraphLayout {
    struct Row {
        let currentLane: Int
        let incomingLaneCount: Int
        let parentLanes: [Int]
        let passThrough: [(source: Int, target: Int)]
        let laneCount: Int
        let hasIncomingCurrent: Bool
        let parentCount: Int
        let outgoingLaneIDs: [String]
    }

    static func rows(for revisions: [Revision]) -> [Row] {
        var lanes: [String] = []
        return revisions.map { revision in
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
            return row
        }
    }
}
