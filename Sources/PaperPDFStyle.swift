import AppKit
import PDFKit
import QuartzCore

/// Changes only the onscreen page presentation. PDFKit continues to own its
/// original pages, text, selection, search, and tiled rendering.
final class PDFPaperAppearance: NSObject, PDFPageOverlayViewProvider {
    private weak var pdfView: PDFView?
    private let overlays = NSHashTable<PaperPageOverlay>.weakObjects()
    private var pageColor: NSColor?

    /// Install before assigning the PDF document. Keep this helper alive for
    /// as long as the PDFView: PDFKit holds its
    /// overlay provider weakly. Keeping the provider installed also lets a
    /// theme change update visible pages without resetting PDFKit's layout.
    func apply(to view: PDFView, theme: PaperTheme) {
        pageColor = theme == .paper ? theme.nsPageColor : nil
        if pdfView !== view {
            if let previous = pdfView, previous.pageOverlayViewProvider === self {
                previous.pageOverlayViewProvider = nil
            }
            pdfView = view
        }
        if view.pageOverlayViewProvider !== self {
            view.pageOverlayViewProvider = self
        }
        for overlay in overlays.allObjects { overlay.setPaperColor(pageColor) }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = PaperPageOverlay(frame: .zero)
        overlay.setPaperColor(pageColor)
        overlays.add(overlay)
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: NSView, for page: PDFPage) {
        (overlayView as? PaperPageOverlay)?.setPaperColor(pageColor)
    }
}

/// One constant-color layer for each page PDFKit is currently displaying.
/// Multiply preserves black ink and modulates the existing color channels;
/// the PDF page itself is never rasterized or rewritten by the application.
private final class PaperPageOverlay: NSView {
    private var paperColor: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setPaperColor(_ color: NSColor?) {
        paperColor = color
        isHidden = color == nil
        updateLayer()
    }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = paperColor?.cgColor
        layer?.compositingFilter = paperColor == nil ? nil : "multiplyBlendMode"
        CATransaction.commit()
    }
}
