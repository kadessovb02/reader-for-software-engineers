import AppKit
import SwiftUI

enum PracticeSplitAxis {
    /// The divider moves left and right, changing the panes' widths.
    case horizontal
    /// The divider moves up and down, changing the panes' heights.
    case vertical
}

/// A native split with an easy-to-grab divider. The two hosting views live for
/// the lifetime of this representable, so resizing never recreates an editor.
struct PracticeResizableSplit<First: View, Second: View>: NSViewRepresentable {
    var axis: PracticeSplitAxis
    var identifier: String
    var fraction: Double
    var minimumFirst: CGFloat
    var minimumSecond: CGFloat
    private var first: First
    private var second: Second

    init(axis: PracticeSplitAxis, identifier: String, fraction: Double,
         minimumFirst: CGFloat, minimumSecond: CGFloat,
         @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.axis = axis
        self.identifier = identifier
        self.fraction = fraction
        self.minimumFirst = minimumFirst
        self.minimumSecond = minimumSecond
        self.first = first()
        self.second = second()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PracticeNativeSplitView {
        let split = PracticeNativeSplitView(axis: axis, identifier: identifier,
                                           fraction: fraction, minimumFirst: minimumFirst,
                                           minimumSecond: minimumSecond)
        let firstHost = NSHostingView(rootView: AnyView(first.environment(\.self, context.environment)))
        let secondHost = NSHostingView(rootView: AnyView(second.environment(\.self, context.environment)))
        // Size belongs to NSSplitView, not to the content's ideal dimensions.
        // In particular a long code line must not impose a huge minimum width.
        firstHost.sizingOptions = []
        secondHost.sizingOptions = []
        context.coordinator.firstHost = firstHost
        context.coordinator.secondHost = secondHost
        split.addSubview(firstHost)
        split.addSubview(secondHost)
        return split
    }

    func updateNSView(_ split: PracticeNativeSplitView, context: Context) {
        context.coordinator.firstHost?.rootView = AnyView(first.environment(\.self, context.environment))
        context.coordinator.secondHost?.rootView = AnyView(second.environment(\.self, context.environment))
        split.configure(axis: axis, identifier: identifier, fraction: fraction,
                        minimumFirst: minimumFirst, minimumSecond: minimumSecond)
    }

    final class Coordinator {
        var firstHost: NSHostingView<AnyView>?
        var secondHost: NSHostingView<AnyView>?
    }
}

final class PracticeNativeSplitView: NSSplitView, NSSplitViewDelegate {
    static func defaultsKey(_ identifier: String) -> String { "practice.split.\(identifier).fraction" }

    private(set) var splitIdentifier: String
    private(set) var dividerFraction: CGFloat
    private var minimumFirst: CGFloat
    private var minimumSecond: CGFloat
    private var isApplyingLayout = false
    private var isResizingContainer = false
    private var lastLayoutSize = NSSize.zero

    override var isFlipped: Bool { true }
    override var dividerThickness: CGFloat { 8 }

    init(axis: PracticeSplitAxis, identifier: String, fraction: Double,
         minimumFirst: CGFloat, minimumSecond: CGFloat) {
        splitIdentifier = identifier
        dividerFraction = Self.savedFraction(identifier: identifier, fallback: fraction)
        self.minimumFirst = minimumFirst
        self.minimumSecond = minimumSecond
        super.init(frame: .zero)
        isVertical = axis == .horizontal
        dividerStyle = .thin
        delegate = self
        setAccessibilityLabel(Self.dividerLabel(identifier))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(axis: PracticeSplitAxis, identifier: String, fraction: Double,
                   minimumFirst: CGFloat, minimumSecond: CGFloat) {
        var changed = self.minimumFirst != minimumFirst || self.minimumSecond != minimumSecond
        if splitIdentifier != identifier {
            splitIdentifier = identifier
            dividerFraction = Self.savedFraction(identifier: identifier, fallback: fraction)
            setAccessibilityLabel(Self.dividerLabel(identifier))
            changed = true
        }
        if isVertical != (axis == .horizontal) {
            isVertical = axis == .horizontal
            changed = true
        }
        self.minimumFirst = minimumFirst
        self.minimumSecond = minimumSecond
        if changed { layoutPanes() }
    }

    override func layout() {
        super.layout()
        if lastLayoutSize != bounds.size { layoutPanes() }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutPanes() }

    override func setFrameSize(_ newSize: NSSize) {
        let wasResizing = isResizingContainer
        isResizingContainer = true
        super.setFrameSize(newSize)
        isResizingContainer = wasResizing
    }

    private var availableLength: CGFloat {
        max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
    }

    private var allowedFirstLength: ClosedRange<CGFloat> {
        let total = availableLength
        let first = max(0, minimumFirst)
        let second = max(0, minimumSecond)
        // Retain usable panes even if a parent temporarily lays out below its
        // nominal minimum (for example during a window's first layout pass).
        let scale = first + second > total && first + second > 0 ? total / (first + second) : 1
        return (first * scale)...max(first * scale, total - second * scale)
    }

    private func layoutPanes() {
        guard subviews.count == 2, availableLength > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        let range = allowedFirstLength
        let firstLength = min(range.upperBound, max(range.lowerBound, availableLength * dividerFraction))
        let secondOrigin = firstLength + dividerThickness
        if isVertical {
            subviews[0].frame = NSRect(x: 0, y: 0, width: firstLength, height: bounds.height)
            subviews[1].frame = NSRect(x: secondOrigin, y: 0,
                                     width: availableLength - firstLength, height: bounds.height)
        } else {
            subviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: firstLength)
            subviews[1].frame = NSRect(x: 0, y: secondOrigin,
                                     width: bounds.width, height: availableLength - firstLength)
        }
        lastLayoutSize = bounds.size
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { allowedFirstLength.lowerBound }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { allowedFirstLength.upperBound }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView,
                   forDoubleClickOnDividerAt dividerIndex: Int) -> Bool { false }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isApplyingLayout, !isResizingContainer, subviews.count == 2, availableLength > 0,
              bounds.width > 0, bounds.height > 0, lastLayoutSize == bounds.size else { return }
        let firstLength = isVertical ? subviews[0].frame.width : subviews[0].frame.height
        let value = firstLength / availableLength
        guard value.isFinite, value > 0, value < 1 else { return }
        dividerFraction = value
        UserDefaults.standard.set(Double(value), forKey: Self.defaultsKey(splitIdentifier))
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func drawDivider(in rect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.16).setFill()
        rect.fill()
        NSColor.separatorColor.withAlphaComponent(0.65).setFill()
        let line: NSRect
        let grip: NSRect
        if isVertical {
            line = NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height)
            grip = NSRect(x: rect.midX - 1, y: rect.midY - 15, width: 2, height: 30)
        } else {
            line = NSRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1)
            grip = NSRect(x: rect.midX - 15, y: rect.midY - 1, width: 30, height: 2)
        }
        line.fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1, yRadius: 1).fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard subviews.count == 2 else { return }
        let position = isVertical ? subviews[0].frame.maxX : subviews[0].frame.maxY
        let divider = isVertical
            ? NSRect(x: position, y: 0, width: dividerThickness, height: bounds.height)
            : NSRect(x: 0, y: position, width: bounds.width, height: dividerThickness)
        addCursorRect(divider, cursor: isVertical ? .resizeLeftRight : .resizeUpDown)
    }

    private static func savedFraction(identifier: String, fallback: Double) -> CGFloat {
        let value = UserDefaults.standard.object(forKey: defaultsKey(identifier)) as? Double ?? fallback
        return CGFloat(value.isFinite && value > 0 && value < 1 ? value : 0.5)
    }

    private static func dividerLabel(_ identifier: String) -> String {
        if identifier.contains("task") || identifier.contains("columns") { return "Ширина задания и редактора — перетащите границу" }
        if identifier.contains("output") || identifier.contains("console") { return "Высота редактора и результата — перетащите границу" }
        return "Высота редактора и подсказок — перетащите границу"
    }
}
