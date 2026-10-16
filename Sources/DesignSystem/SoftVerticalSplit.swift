import AppKit
import SwiftUI

/// 使用相邻背景色分区，保留透明拖拽热区的纵向分栏。
public struct SoftVerticalSplit<Top: View, Bottom: View>: View {
    private let fixedSide: VerticalEdge
    private let minimumFixed: CGFloat
    private let flexibleMinimum: CGFloat
    private let storageKey: String?
    private let storage: SplitLayoutStore
    private let top: () -> Top
    private let bottom: () -> Bottom

    @State private var height: CGFloat
    @State private var dragOrigin: CGFloat?
    @State private var isHoveringHandle = false

    public init(
        fixedSide: VerticalEdge = .top,
        initialHeight: CGFloat,
        minimumFixed: CGFloat = 100,
        flexibleMinimum: CGFloat,
        storageKey: String? = nil,
        storage: SplitLayoutStore = SplitLayoutStore(),
        @ViewBuilder top: @escaping () -> Top,
        @ViewBuilder bottom: @escaping () -> Bottom
    ) {
        self.fixedSide = fixedSide
        self.minimumFixed = minimumFixed
        self.flexibleMinimum = flexibleMinimum
        self.storageKey = storageKey
        self.storage = storage
        self.top = top
        self.bottom = bottom
        let restoredHeight = storageKey.flatMap { storage.value(for: $0) } ?? initialHeight
        _height = State(initialValue: restoredHeight)
    }

    public var body: some View {
        GeometryReader { proxy in
            let bounds = resolvedBounds(for: proxy.size.height)
            let fixedHeight = clamp(height, to: bounds)
            let flexibleHeight = max(0, proxy.size.height - fixedHeight)

            VStack(alignment: .leading, spacing: 0) {
                if fixedSide == .top {
                    top().frame(width: proxy.size.width, height: fixedHeight, alignment: .topLeading).clipped()
                    bottom().frame(width: proxy.size.width, height: flexibleHeight, alignment: .topLeading).clipped()
                } else {
                    top().frame(width: proxy.size.width, height: flexibleHeight, alignment: .topLeading).clipped()
                    bottom().frame(width: proxy.size.width, height: fixedHeight, alignment: .topLeading).clipped()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .overlay(alignment: fixedSide == .top ? .top : .bottom) {
                resizeHandle(bounds: bounds)
                    .offset(y: fixedSide == .top ? fixedHeight - 5 : -fixedHeight + 5)
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
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let origin = dragOrigin ?? clamp(height, to: bounds)
                        if dragOrigin == nil { dragOrigin = origin }
                        let delta = fixedSide == .top ? value.translation.height : -value.translation.height
                        height = clamp(origin + delta, to: bounds)
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        persistHeight()
                    }
            )
            .onHover { hovering in
                guard hovering != isHoveringHandle else { return }
                isHoveringHandle = hovering
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("调整分栏高度")
            .accessibilityValue("\(Int(clamp(height, to: bounds))) 点")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    height = clamp(height + 16, to: bounds)
                    persistHeight()
                case .decrement:
                    height = clamp(height - 16, to: bounds)
                    persistHeight()
                @unknown default: break
                }
            }
    }

    private func resolvedBounds(for availableHeight: CGFloat) -> ClosedRange<CGFloat> {
        let available = max(0, availableHeight)
        let upper = max(0, available - max(0, flexibleMinimum))
        let lower = min(max(0, minimumFixed), upper)
        return lower...upper
    }

    private func clamp(_ value: CGFloat, to bounds: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, bounds.lowerBound), bounds.upperBound)
    }

    private func persistHeight() {
        guard let storageKey else { return }
        storage.save(height, for: storageKey)
    }
}
