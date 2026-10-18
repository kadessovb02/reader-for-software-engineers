import AppKit
import PDFKit
#if TEST_MODULE
@testable import ListReaderCore
#endif

/// Compile with production Sources except AppMain.swift. This test creates no
/// windows and uses only temporary library roots; it never opens a user's files.
@main struct LibraryManagementSmoke {
    enum Failure: Error { case check(String) }

    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.check(message) }
    }

    @MainActor static func main() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("list-library-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let firstRun = ReaderStore(root: scratch.appendingPathComponent("first-run"))
        try require(firstRun.books.isEmpty && firstRun.book == nil && firstRun.selectedID.isEmpty, "First run should have a clean, empty library")

        let root = scratch.appendingPathComponent("library", isDirectory: true)
        let seed = ReaderStore(root: root)
        seed.books = [
            BookRecord(id: "A", title: "First", format: "missing", lastRead: Date(timeIntervalSince1970: 1)),
            BookRecord(id: "B", title: "Reading", format: "missing", chapter: 2, progress: 0.42, page: 9, pageOffset: 214, positions: ["2": 0.42]),
            BookRecord(id: "C", title: "Third", format: "missing", lastRead: Date(timeIntervalSince1970: 9_999_999)),
            BookRecord(id: "D", title: "Fourth", format: "missing")
        ]
        seed.selectedID = "B"
        seed.save()
        let originalJSON = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let json = try JSONSerialization.jsonObject(with: originalJSON) as? [String: Any]
        let oldRecords = json?["books"] as? [[String: Any]]
        try require(oldRecords?.allSatisfy { $0["archived"] == nil } == true, "Migration fixture unexpectedly includes archive flags")

        let store = ReaderStore(root: root)
        try require(store.activeBooks.map(\.id) == ["A", "B", "C", "D"], "Old library order or default archive state changed")
        store.moveBook("B", to: 2)
        store.moveBook("D", by: -1)
        try require(store.activeBooks.map(\.id) == ["A", "C", "D", "B"], "Reorder did not persist explicit section order")
        try require(store.selectedID == "B" && store.book?.page == 9 && store.book?.pageOffset == 214 && store.book?.positions["2"] == 0.42, "Reorder altered selected reading position")
        let reordered = ReaderStore(root: root)
        try require(reordered.books.map(\.id) == ["A", "C", "D", "B"] && reordered.selectedID == "B", "Order or selected book lost after restart")
        print("PASS old library migration, explicit order, and selected reading position")

        store.setArchived(true, for: "C")
        store.moveBook("B", to: 0)
        try require(store.activeBooks.map(\.id) == ["B", "A", "D"] && store.archivedBooks.map(\.id) == ["C"], "Reordering active books changed archived section")
        store.setArchived(true, for: "B")
        try require(store.selectedID == "A", "Archiving selected book did not select the next active book")
        try require(store.books.first(where: { $0.id == "B" })?.pageOffset == 214, "Archive lost PDF reading position")
        store.setArchived(false, for: "B")
        try require(store.activeBooks.map(\.id) == ["B", "A", "D"], "Restoring archive changed its library position")
        store.setArchived(true, for: "A")
        store.setArchived(true, for: "D")
        store.setArchived(true, for: "B")
        try require(store.activeBooks.isEmpty && store.book?.id == "B" && store.book?.isArchived == true, "All-archived library lost reading fallback")
        let archived = ReaderStore(root: root)
        try require(archived.archivedBooks.count == 4 && archived.activeBooks.isEmpty, "Archive flags did not survive restart")
        print("PASS archive, restore, next-book selection, and all-archived fallback")

        // Missing source folders exercise record/selection removal without adding
        // disposable test items to the user's macOS Trash.
        for id in store.books.map(\.id).filter({ $0 != store.selectedID }) {
            try require(store.deleteBook(id), "Unselected record could not be removed")
        }
        store.content = ImportedBook(title: "Disposable", author: "", chapters: [])
        store.pdfDocument = PDFDocument()
        store.visibleText = "stale"; store.selection = "stale"; store.currentHeading = "stale"
        store.searchVisible = true; store.contentsVisible = true; store.pendingPracticeSearch = "stale"
        store.captureContext = {}; store.onScroll = { _ in }; store.onSearch = { _, _ in }
        store.focusedPDFPage = { 9 }; store.onReadingKey = { _ in }; store.onRevealPracticePDF = { _, _ in }
        try require(store.deleteBook(store.selectedID), "Final record could not be removed")
        try require(store.books.isEmpty && store.selectedID.isEmpty && store.book == nil, "Final deletion retained selected book")
        try require(store.content == nil && store.pdfDocument == nil && store.visibleText.isEmpty && store.selection.isEmpty && store.currentHeading.isEmpty, "Final deletion retained reader content")
        try require(store.captureContext == nil && store.onScroll == nil && store.onSearch == nil && store.focusedPDFPage == nil && store.onReadingKey == nil && store.onRevealPracticePDF == nil, "Final deletion retained reader callbacks")
        try require(!store.searchVisible && !store.contentsVisible && store.pendingPracticeSearch == nil, "Final deletion retained auxiliary reader state")
        let empty = ReaderStore(root: root)
        await empty.start()
        try require(empty.books.isEmpty && empty.book == nil && empty.selectedID.isEmpty && !empty.isLoading, "Saved empty library resurrected the first-run placeholder")
        print("PASS empty library persistence and reader content/callback cleanup")

        try await Task.sleep(nanoseconds: 450_000_000)
        print("PASS all library management smoke checks")
    }
}
