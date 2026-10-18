import AppKit
import PDFKit
import CoreText
#if TEST_MODULE
@testable import ListReaderCore
#endif

/// From the project directory, compile production Sources except AppMain.swift
/// together with this file, then run the resulting executable. Uses a generated
/// 640-page document and a hidden window; never opens the user's library.
/// This verifies the native overlay lifecycle and PDF behavior. PDFKit's tiles
/// are omitted by cacheDisplay, so visual tint QA requires an onscreen capture.
@main struct PaperPDFSmoke {
    enum Failure: Error { case check(String) }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await run()
                print("PASS PDF paper appearance smoke checks")
                exit(0)
            } catch {
                fputs("FAIL \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        if !condition() { throw Failure.check(description) }
    }

    @MainActor static func pause() async throws {
        try await Task.sleep(nanoseconds: 180_000_000)
    }

    @MainActor static func overlayViews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { child in
            (String(describing: type(of: child)) == "PaperPageOverlay" ? [child] : []) + overlayViews(in: child)
        }
    }

    @MainActor static func run() async throws {
        let (document, sourceURL) = try fixture()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let originalBytes = try Data(contentsOf: sourceURL)
        let originalDocumentReference = document.documentRef
        let originalPage = document.page(at: 317)
        let originalPageReference = originalPage?.pageRef
        let originalText = document.page(at: 317)?.string
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }

        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 680, height: 760))
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        let appearance = PDFPaperAppearance()
        appearance.apply(to: view, theme: .light)
        view.document = document
        window.contentView = view
        view.layoutDocumentView()
        try await pause()
        let initialOverlays = overlayViews(in: view)
        try require(!initialOverlays.isEmpty, "Provider did not produce page overlays")
        try require(initialOverlays.allSatisfy(\.isHidden), "Light theme altered the original page")

        appearance.apply(to: view, theme: .paper)
        try await pause()
        let paperOverlays = overlayViews(in: view)
        try require(Set(paperOverlays.map(ObjectIdentifier.init)) == Set(initialOverlays.map(ObjectIdentifier.init)), "Theme change rebuilt visible overlays")
        try require(paperOverlays.allSatisfy { !$0.isHidden && $0.layer?.compositingFilter as? String == "multiplyBlendMode" }, "Existing page overlays did not enable multiply tint")
        try require(paperOverlays.allSatisfy { $0.hitTest(NSPoint(x: 30, y: 30)) == nil && !$0.acceptsFirstResponder }, "Tint intercepts pointer input or keyboard focus")

        for index in [17, 150, 317, 638] {
            guard let page = document.page(at: index) else { throw Failure.check("Fixture page missing") }
            view.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: 650)))
            try await pause()
            let currentOverlays = overlayViews(in: view)
            try require(!currentOverlays.isEmpty && currentOverlays.count < 20, "Overlay hierarchy is empty or scales with document length")
            try require(currentOverlays.allSatisfy { !$0.isHidden && $0.layer?.compositingFilter as? String == "multiplyBlendMode" }, "Newly displayed pages lost paper tint")
        }
        print("PASS current/future page overlays across 640 pages; visible hierarchy remains bounded")

        let target = document.page(at: 317)!
        view.go(to: PDFDestination(page: target, at: NSPoint(x: 0, y: 650)))
        try await pause()
        guard let destination = view.currentDestination, let selection = target.selection(for: NSRange(location: 0, length: 12)) else { throw Failure.check("Native destination/selection missing") }
        view.setCurrentSelection(selection, animate: false)
        let selectedText = view.currentSelection?.string
        let scale = view.scaleFactor
        for theme in [PaperTheme.light, .dark, .paper, .light] {
            appearance.apply(to: view, theme: theme)
            try await pause()
            try require(view.document === document && view.currentPage === target, "Theme switch changed original document or current page")
            try require(view.currentDestination?.point == destination.point && view.scaleFactor == scale, "Theme switch moved or zoomed the PDF")
            try require(view.currentSelection?.string == selectedText, "Theme switch lost native text selection")
            if theme != .paper {
                try require(overlayViews(in: view).allSatisfy(\.isHidden), "Non-paper theme left a page tint enabled")
            }
        }
        try require(document.findString("selectable text 317", withOptions: []).count == 1, "Native PDF search changed")
        let currentBytes = try Data(contentsOf: sourceURL)
        try require(document.page(at: 317)?.string == originalText && currentBytes == originalBytes, "Appearance modified source PDF file or text")
        try require(document.documentRef === originalDocumentReference && target === originalPage && target.pageRef === originalPageReference && target.annotations.isEmpty, "Appearance replaced or annotated original PDF content")
        print("PASS light/dark restore native presentation; source file/page references, text/search/selection, zoom and destination unchanged")
        withExtendedLifetime(appearance) {}
    }

    @MainActor static func fixture() throws -> (PDFDocument, URL) {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw Failure.check("Unable to create PDF fixture") }
        for index in 0..<640 {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 40, y: 500, width: 80, height: 80))
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 160, y: 500, width: 80, height: 80))
            let text = NSAttributedString(string: "Original selectable text \(index)", attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
            context.textPosition = CGPoint(x: 40, y: 450)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("list-paper-smoke-\(UUID().uuidString).pdf")
        try (data as Data).write(to: url)
        guard let document = PDFDocument(url: url) else {
            try? FileManager.default.removeItem(at: url)
            throw Failure.check("Unable to read PDF fixture")
        }
        return (document, url)
    }
}
