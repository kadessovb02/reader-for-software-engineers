import AppKit
import Foundation
import PDFKit
import CoreText
#if TEST_MODULE
@testable import ListReaderCore
#endif

/// Uses only synthetic books in a disposable directory. No network or real library writes.
@main struct ChatBookSearchSmoke {
    enum Failure: Error { case check(String) }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.check(message) }
    }

    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatBookSearchSmoke-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await textTests(root)
            try await pdfTests(root)
            try await headingTests(root)
            try await cancellationTest(root)
            print("PASS chat book search: chapter/book limits, visible anchor, balanced overview, PDF boundaries/cache, cancellation")
        } catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }

    static func textTests(_ root: URL) async throws {
        let intro = (0..<1500).map { "Paragraph \($0). Introduction context and the introduction's central argument. Unique marker INDEX\($0)." }.joined(separator: "\n\n")
        let chapter = "ALREADYREAD. Cache fundamentals.\n\nVISIBLEANCHOR is the final visible paragraph with a specific signature.\n\nUNREADCURRENT must only appear for whole chapter scope."
        let content = ImportedBook(title: "Synthetic", author: "Test", chapters: [
            ImportedChapter(title: "Introduction", html: "", text: intro, basePath: nil),
            ImportedChapter(title: "Chapter 1 Cache", html: "", text: chapter, basePath: nil),
            ImportedChapter(title: "Chapter 2 Secret", html: "", text: "FUTURECHAPTER secret token", basePath: nil)
        ])
        let url = root.appendingPathComponent("text.txt")
        try Data("source identity".utf8).write(to: url)
        let record = BookRecord(id: "text", title: "Synthetic", format: "txt", chapter: 1, progress: 0.99)
        let visible = "VISIBLEANCHOR is the final visible paragraph with a specific signature."
        let session = ChatBookSearchSession(book: record, sourceURL: url, cacheDirectory: root.appendingPathComponent("text-cache"), content: content, visibleText: visible)
        let current = try await session.retrieve(ChatSearchRequest(scope: "chapter", query: "UNREADCURRENT"))
        try require(current.sources.contains(where: { $0.text.contains("UNREADCURRENT") }), "Chapter scope omitted current chapter's later text")
        try require(current.sources.allSatisfy { $0.chapter == 1 }, "Chapter search crossed into a different chapter")
        let earlier = try await session.retrieve(ChatSearchRequest(scope: "book", query: "UNREADCURRENT FUTURECHAPTER"))
        try require(earlier.sources.allSatisfy { !$0.text.contains("UNREADCURRENT") && !$0.text.contains("FUTURECHAPTER") }, "Book scope leaked unread text")
        let anchor = try await session.retrieve(ChatSearchRequest(scope: "book", query: "VISIBLEANCHOR"))
        try require(anchor.sources.contains(where: { $0.text.contains("VISIBLEANCHOR") }), "Book scope omitted visible text")
        let overview = try await session.retrieve(ChatSearchRequest(scope: "book", query: "Summarize introduction", mode: "overview", section: "Introduction"))
        try require(overview.sources.count <= 32 && overview.sources.reduce(0) { $0 + $1.text.count } <= 40_000, "Overview exceeded its budget")
        try require(overview.sources.first?.text.contains("INDEX0") == true && overview.sources.last?.text.contains("INDEX1499") == true, "Long overview omitted beginning or ending")
        try require(overview.sources.contains(where: { $0.text.contains("INDEX749") || $0.text.contains("INDEX750") }), "Long overview omitted middle")
        try require(overview.note.contains("выборка") && overview.sources.allSatisfy { intro.contains($0.text) && $0.chapter == 0 }, "Overview did not disclose clipping or changed source excerpts")
        let noAnchor = ChatBookSearchSession(book: record, sourceURL: url, cacheDirectory: root.appendingPathComponent("text-cache"), content: content, visibleText: "not present in book")
        let conservative = try await noAnchor.retrieve(ChatSearchRequest(scope: "book", query: "VISIBLEANCHOR ALREADYREAD"))
        try require(conservative.sources.allSatisfy { $0.chapter != 1 } && conservative.note.contains("текущая глава исключена"), "Unanchored viewport guessed unread text using percentage")
        let wrongSection = try await session.retrieve(ChatSearchRequest(scope: "chapter", query: "Summarize introduction", mode: "overview", section: "Introduction"))
        try require(wrongSection.sources.isEmpty && wrongSection.note.contains("scope=book"), "Current chapter search silently widened to earlier introduction")
        do {
            _ = try await session.retrieve(ChatSearchRequest(scope: "all", query: "secret"))
            throw Failure.check("Invalid unbounded scope accepted")
        } catch ChatBookSearchError.invalidScope { }
    }

    static func createPDF(_ url: URL, texts: [String], outline: [(Int, String)], nested: Bool = false) throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw Failure.check("PDF context") }
        for text in texts {
            context.beginPDFPage(nil)
            for (index, lineText) in text.components(separatedBy: "\n").enumerated() {
                context.textPosition = CGPoint(x: 35, y: 740 - index * 18)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: lineText, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 11, nil)]))
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else { throw Failure.check("PDF decode") }
        if !outline.isEmpty {
            let root = PDFOutline()
            for (page, title) in outline {
                let node = PDFOutline(); node.label = title
                node.destination = PDFDestination(page: document.page(at: page)!, at: .zero)
                if nested, page + 1 < document.pageCount {
                    let child = PDFOutline(); child.label = "1.1 Nested section"
                    child.destination = PDFDestination(page: document.page(at: page + 1)!, at: .zero)
                    node.insertChild(child, at: 0)
                }
                root.insertChild(node, at: root.numberOfChildren)
            }
            document.outlineRoot = root
        }
        try require(document.write(to: url), "PDF save")
    }

    static func pdfTests(_ root: URL) async throws {
        let url = root.appendingPathComponent("outlined.pdf")
        try createPDF(url, texts: (0..<10).map { "Page \($0 + 1) cache UNIQUE\($0)" }, outline: [(0, "Introduction"), (3, "Chapter 1 Reliability"), (8, "Chapter 2 Secret")], nested: true)
        let record = BookRecord(id: "pdf", title: "Synthetic", format: "pdf", page: 4)
        let cache = root.appendingPathComponent("pdf-cache")
        let session = ChatBookSearchSession(book: record, sourceURL: url, cacheDirectory: cache)
        let chapter = try await session.retrieve(ChatSearchRequest(scope: "chapter", query: "", mode: "overview"))
        try require(Set(chapter.sources.compactMap(\.page)) == Set(3...7), "Nested outline became chapter or whole chapter was incomplete")
        let capped = try await session.retrieve(ChatSearchRequest(scope: "book", query: "", mode: "overview"))
        try require(Set(capped.sources.compactMap(\.page)) == Set(0...4), "Cached current-chapter future pages leaked into book search")
        let intro = try await session.retrieve(ChatSearchRequest(scope: "book", query: "summarize introduction", mode: "overview"))
        try require(Set(intro.sources.compactMap(\.page)) == Set(0...2), "Earlier entire introduction section not found")
        // A changed source at the same path must not reuse old extracted text.
        try createPDF(url, texts: (0..<10).map { "REPLACED different marker page \($0 + 1) and a longer new file" }, outline: [(0, "Introduction"), (3, "Chapter 1 Reliability"), (8, "Chapter 2 Secret")])
        let replaced = try await session.retrieve(ChatSearchRequest(scope: "book", query: "REPLACED"))
        try require(!replaced.sources.isEmpty && replaced.sources.allSatisfy { $0.text.contains("REPLACED") }, "Source identity cache was stale after replacing book")
    }

    static func headingTests(_ root: URL) async throws {
        let url = root.appendingPathComponent("headings.pdf")
        let texts = ["Contents\nIntroduction .......... 3\nChapter 1 .......... 5\nChapter 2 .......... 9\nAppendix .......... 12",
                     "Title information", "Introduction\nEarlier start UNIQUEINTRO", "Introduction body UNIQUEEND",
                     "Chapter 1 Reliability\nCurrent heading", "Body cache CURRENT", "Body cache LATERINCHAPTER",
                     "Chapter 2 Secret\nFORBIDDEN"]
        try createPDF(url, texts: texts, outline: [])
        let session = ChatBookSearchSession(book: BookRecord(id: "headings", title: "Synthetic", format: "pdf", page: 5), sourceURL: url, cacheDirectory: root.appendingPathComponent("head-cache"))
        let chapter = try await session.retrieve(ChatSearchRequest(scope: "chapter", query: "", mode: "overview"))
        try require(Set(chapter.sources.compactMap(\.page)) == Set(4...6), "Heading fallback failed to find whole current chapter or crossed next chapter")
        let intro = try await session.retrieve(ChatSearchRequest(scope: "book", query: "summarize introduction", mode: "overview"))
        try require(Set(intro.sources.compactMap(\.page)) == Set(2...3), "Printed contents page mistaken for actual introduction start")
        let unknownURL = root.appendingPathComponent("unknown.pdf")
        try createPDF(unknownURL, texts: ["Body before", "Current unmarked text", "Undetected future chapter"], outline: [])
        let unknown = ChatBookSearchSession(book: BookRecord(id: "unknown", title: "Synthetic", format: "pdf", page: 1), sourceURL: unknownURL, cacheDirectory: root.appendingPathComponent("unknown-cache"))
        let fallback = try await unknown.retrieve(ChatSearchRequest(scope: "chapter", query: "", mode: "overview"))
        try require(fallback.sources.allSatisfy { $0.page == 1 } && fallback.note.contains("не удалось"), "Unknown chapter boundaries guessed an entire book")
    }

    static func cancellationTest(_ root: URL) async throws {
        let session = ChatBookSearchSession(book: BookRecord(id: "cancel", title: "Synthetic", format: "pdf"), sourceURL: root.appendingPathComponent("never-open.pdf"), cacheDirectory: root.appendingPathComponent("cancel-cache"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.retrieve(ChatSearchRequest(scope: "book", query: "anything"))
        }
        do { _ = try await task.value; throw Failure.check("Cancelled request completed") } catch is CancellationError { }
    }
}
