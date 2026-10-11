import AppKit
import SwiftUI

/// 使用相邻背景色分区，保留透明拖拽热区的横向分栏。
public struct SoftHorizontalSplit<Leading: View, Trailing: View>: View {
    private let fixedSide: HorizontalEdge
    private let range: ClosedRange<CGFloat>
    private let flexibleMinimum: CGFloat
    private let leading: () -> Leading
    private let trailing: () -> Trailing

    @State private var width: CGFloat
    @State private var dragOrigin: CGFloat?
    @State private var isHoveringHandle = false

    public init(
        fixedSide: HorizontalEdge = .leading,
        initialWidth: CGFloat,
        range: ClosedRange<CGFloat>,
        flexibleMinimum: CGFloat,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.fixedSide = fixedSide
        self.range = range
        self.flexibleMinimum = flexibleMinimum
        self.leading = leading
        self.trailing = trailing
        _width = State(initialValue: initialWidth)
    }

    public var body: some View {
        GeometryReader { proxy in
            let bounds = resolvedBounds(for: proxy.size.width)
            let fixedWidth = clamp(width, to: bounds)
            let flexibleWidth = max(0, proxy.size.width - fixedWidth)

            HStack(spacing: 0) {
                if fixedSide == .leading {
                    leading()
                        .frame(width: fixedWidth)
                    trailing()
                        .frame(width: flexibleWidth)
                } else {
                    leading()
                        .frame(width: flexibleWidth)
                    trailing()
                        .frame(width: fixedWidth)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .overlay(alignment: fixedSide == .leading ? .leading : .trailing) {
                resizeHandle(bounds: bounds)
                    .offset(x: fixedSide == .leading ? fixedWidth - 5 : -fixedWidth + 5)
            }
            .onChange(of: proxy.size.width) { _, newWidth in
                width = clamp(width, to: resolvedBounds(for: newWidth))
            }
        }
        .onDisappear {
            if isHoveringHandle {
                isHoveringHandle = false
                NSCursor.pop()
            }
        }
    }

    private func resizeHandle(bounds: ClosedRange<CGFloat>) -> some View {
        Color.clear
            .frame(width: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let origin = dragOrigin ?? width
                        if dragOrigin == nil {
                            dragOrigin = origin
                        }
                        let delta = fixedSide == .leading ? value.translation.width : -value.translation.width
                        width = clamp(origin + delta, to: bounds)
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                    }
            )
            .onHover { hovering in
                guard hovering != isHoveringHandle else { return }
                isHoveringHandle = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("调整分栏宽度")
            .accessibilityValue("\(Int(clamp(width, to: bounds))) 点")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    width = clamp(width + 16, to: bounds)
                case .decrement:
                    width = clamp(width - 16, to: bounds)
                @unknown default:
                    break
                }
            }
    }

    private func resolvedBounds(for availableWidth: CGFloat) -> ClosedRange<CGFloat> {
        let available = max(0, availableWidth)
        let requestedLower = max(0, range.lowerBound)
        let requestedUpper = max(requestedLower, range.upperBound)
        let maximumForFlexibleSide = max(0, available - max(0, flexibleMinimum))
        let upper = min(requestedUpper, maximumForFlexibleSide)
        let lower = min(requestedLower, upper)
        return lower...upper
    }

    private func clamp(_ value: CGFloat, to bounds: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, bounds.lowerBound), bounds.upperBound)
    }
}
