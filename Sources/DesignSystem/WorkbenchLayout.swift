import SwiftUI

/// 暖灰工作台的共同对齐线。卡片外边距与内容内边距分开管理，
/// 分栏两侧各留半个间隔，避免嵌套容器再次叠加留白。
public enum WorkbenchLayout {
    public static let pageInset: CGFloat = 14
    public static let cardInset: CGFloat = 20
    public static let sectionGap: CGFloat = 12
    public static let cornerRadius: CGFloat = 14
    public static let titleRowHeight: CGFloat = 32
}
