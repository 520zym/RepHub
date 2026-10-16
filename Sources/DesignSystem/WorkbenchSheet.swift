import SwiftUI

public extension View {
    /// 初始尺寸与可缩小边界分开；不限制放大，让 macOS 提供原生 sheet 边缘拖动。
    func workbenchSheet(minWidth: CGFloat, idealWidth: CGFloat,
                        minHeight: CGFloat, idealHeight: CGFloat) -> some View {
        frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: .infinity,
              minHeight: minHeight, idealHeight: idealHeight, maxHeight: .infinity,
              alignment: .topLeading)
            .presentationSizing(.fitted)
    }
}
