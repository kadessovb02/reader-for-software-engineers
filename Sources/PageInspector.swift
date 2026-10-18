import AppKit
import PDFKit

/// A temporary, independent view of one PDF page. The reader's document and
/// saved position stay untouched when this window rotates or zooms the page.
@MainActor final class PageInspectorController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let inspectionDocument = PDFDocument()
    let inspectionPage: PDFPage
    let pdfView = PDFView()
    private var followsWindowSize = true
    private weak var presentingWindow: NSWindow?
    private var refitWork: DispatchWorkItem?

    init(sourcePage: PDFPage, pageNumber: Int, bookTitle: String) {
        // PDFPage's copy preserves its original PDF drawing and searchable text.
        // Inserting the source itself would move it out of the book document.
        guard let copy = sourcePage.copy() as? PDFPage else {
            preconditionFailure("PDFKit could not copy the selected page")
        }
        inspectionPage = copy
        copy.rotation = Self.normalizedRotation(sourcePage.rotation + 90)
        inspectionDocument.insert(copy, at: 0)

        let panel = PageInspectorPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740),
                                       styleMask: [.titled, .closable, .resizable],
                                       backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Страница \(pageNumber) · \(bookTitle)"
        panel.titleVisibility = .visible
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 600, height: 420)
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.toolbarStyle = .unifiedCompact
        panel.delegate = self
        panel.setAccessibilityLabel("Просмотр страницы \(pageNumber)")
        panel.onRotateClockwise = { [weak self] in self?.rotateClockwise(nil) }
        panel.onRotateCounterclockwise = { [weak self] in self?.rotateCounterclockwise(nil) }
        panel.onZoomIn = { [weak self] in self?.zoomIn(nil) }
        panel.onZoomOut = { [weak self] in self?.zoomOut(nil) }
        panel.onFit = { [weak self] in self?.fitPage(nil) }

        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = false
        pdfView.displayBox = .cropBox
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.autoScales = false
        pdfView.minScaleFactor = 0.05
        pdfView.maxScaleFactor = 8
        pdfView.document = inspectionDocument
        pdfView.setAccessibilityLabel("Страница книги. R — повернуть вправо; Shift-R — влево; Escape — закрыть")
        panel.contentView = pdfView

        let toolbar = NSToolbar(identifier: "PageInspector.Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        panel.toolbar = toolbar
        panel.makeFirstResponder(pdfView)
    }

    required init?(coder: NSCoder) { nil }

    func present(relativeTo parent: NSWindow?) {
        guard let window else { return }
        if let oldParent = window.parent, oldParent !== parent {
            oldParent.removeChildWindow(window)
        }
        presentingWindow = parent
        let screen = parent?.screen ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(width: min(1000, available.width - 40), height: min(740, available.height - 40))
        let anchor = parent?.frame ?? available
        let origin = NSPoint(x: min(max(anchor.midX - size.width / 2, available.minX + 12), available.maxX - size.width - 12),
                             y: min(max(anchor.midY - size.height / 2, available.minY + 12), available.maxY - size.height - 12))
        window.setFrame(NSRect(origin: origin, size: size), display: false)
        if let parent, window.parent !== parent {
            parent.addChildWindow(window, ordered: .above)
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(pdfView)
        fitPage(nil)
        // PDFKit creates its internal scroll view during its first layout.
        // One coalesced follow-up uses the final content size after the toolbar.
        scheduleRefit()
    }

    @objc func rotateClockwise(_ sender: Any?) { rotate(by: 90) }
    @objc func rotateCounterclockwise(_ sender: Any?) { rotate(by: -90) }

    private func rotate(by degrees: Int) {
        inspectionPage.rotation = Self.normalizedRotation(inspectionPage.rotation + degrees)
        followsWindowSize = true
        fitPage(nil)
        scheduleRefit()
    }

    static func normalizedRotation(_ degrees: Int) -> Int { (degrees % 360 + 360) % 360 }

    @objc func fitPage(_ sender: Any?) {
        followsWindowSize = true
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        pdfView.layoutDocumentView()
        let fit = pdfView.scaleFactorForSizeToFit
        if fit.isFinite, fit > 0 { pdfView.scaleFactor = max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, fit)) }
        pdfView.layoutDocumentView()
        pdfView.go(to: inspectionPage)
    }

    @objc func zoomIn(_ sender: Any?) { zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: 0.8) }

    private func zoom(by multiplier: CGFloat) {
        refitWork?.cancel()
        followsWindowSize = false
        pdfView.scaleFactor = max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, pdfView.scaleFactor * multiplier))
    }

    func windowDidResize(_ notification: Notification) {
        if followsWindowSize { scheduleRefit() }
    }

    func windowWillClose(_ notification: Notification) {
        refitWork?.cancel()
        if let parent = window?.parent, let window { parent.removeChildWindow(window) }
        presentingWindow?.makeKeyAndOrderFront(nil)
    }

    private func scheduleRefit() {
        refitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.followsWindowSize else { return }
            self.fitPage(nil)
        }
        refitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    private static let rotateLeftID = NSToolbarItem.Identifier("PageInspector.RotateLeft")
    private static let rotateRightID = NSToolbarItem.Identifier("PageInspector.RotateRight")
    private static let zoomOutID = NSToolbarItem.Identifier("PageInspector.ZoomOut")
    private static let zoomInID = NSToolbarItem.Identifier("PageInspector.ZoomIn")
    private static let fitID = NSToolbarItem.Identifier("PageInspector.Fit")
    private static let closeID = NSToolbarItem.Identifier("PageInspector.Close")

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.rotateLeftID, Self.rotateRightID, .flexibleSpace, Self.zoomOutID, Self.zoomInID, Self.fitID, Self.closeID]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let details: (String, String, String, Selector)
        switch id {
        case Self.rotateLeftID: details = ("Повернуть влево", "rotate.left", "Повернуть влево на 90° (⇧R)", #selector(rotateCounterclockwise(_:)))
        case Self.rotateRightID: details = ("Повернуть вправо", "rotate.right", "Повернуть вправо на 90° (R)", #selector(rotateClockwise(_:)))
        case Self.zoomOutID: details = ("Уменьшить", "minus.magnifyingglass", "Уменьшить (⌘−)", #selector(zoomOut(_:)))
        case Self.zoomInID: details = ("Увеличить", "plus.magnifyingglass", "Увеличить (⌘+)", #selector(zoomIn(_:)))
        case Self.fitID: details = ("Вписать страницу", "arrow.up.left.and.arrow.down.right", "Вписать страницу в окно (0)", #selector(fitPage(_:)))
        case Self.closeID: details = ("Закрыть", "xmark", "Вернуться к чтению (Esc)", #selector(closeInspector(_:)))
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = details.0
        item.paletteLabel = details.0
        item.toolTip = details.2
        item.image = NSImage(systemSymbolName: details.1, accessibilityDescription: details.0)
        item.target = self
        item.action = details.3
        return item
    }

    @objc private func closeInspector(_ sender: Any?) { close() }
}

@MainActor private final class PageInspectorPanel: NSPanel {
    var onRotateClockwise: (() -> Void)?
    var onRotateCounterclockwise: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onFit: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.option) {
            if characters == "=" || characters == "+" { onZoomIn?(); return true }
            if characters == "-" { onZoomOut?(); return true }
            if characters == "0" { onFit?(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
        if event.keyCode == 53 { performClose(nil); return }
        // Hardware key codes also work while the Russian keyboard layout is active.
        if event.keyCode == 15 {
            if modifiers.contains(.shift) { onRotateCounterclockwise?() } else { onRotateClockwise?() }
            return
        }
        if event.keyCode == 29 { onFit?(); return }
        super.keyDown(with: event)
    }
}
