import AppKit
import SwiftUI
#if TEST_MODULE
@testable import ListReaderCore
#endif

/// Compile with the production Sources, excluding AppMain.swift. Creates an
/// ordinary background window and exercises all three production split views.
@main struct PracticeSplitSmoke {
    enum Failure: Error { case check(String) }

    @MainActor final class FixtureState: ObservableObject {
        @Published var code = "print('saved draft')"
        @Published var taskTitle = "Задание"
    }

    struct Fixture: View {
        @ObservedObject var state: FixtureState
        let prefix: String
        var body: some View {
            PracticeResizableSplit(axis: .horizontal, identifier: prefix + ".columns", fraction: 0.28,
                                   minimumFirst: 220, minimumSecond: 470) {
                Text(state.taskTitle).frame(maxWidth: .infinity, maxHeight: .infinity)
            } second: {
                PracticeResizableSplit(axis: .vertical, identifier: prefix + ".workspace", fraction: 0.78,
                                       minimumFirst: 260, minimumSecond: 110) {
                    PracticeResizableSplit(axis: .vertical, identifier: prefix + ".code-output", fraction: 0.82,
                                           minimumFirst: 110, minimumSecond: 55) {
                        PracticeCodeEditor(text: $state.code, editable: true, background: .textBackgroundColor, foreground: .textColor)
                    } second: {
                        Text("Результат запуска").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } second: {
                    Text("Подсказки и разбор").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await run()
                print("ALL PRACTICE SPLIT CHECKS PASSED")
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ text: String) throws {
        if !condition() { throw Failure.check(text) }
    }

    @MainActor static func pause() async throws { try await Task.sleep(nanoseconds: 150_000_000) }

    @MainActor static func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    @MainActor static func run() async throws {
        let prefix = "smoke." + UUID().uuidString
        let identifiers = [prefix + ".columns", prefix + ".workspace", prefix + ".code-output"]
        defer {
            for identifier in identifiers { UserDefaults.standard.removeObject(forKey: PracticeNativeSplitView.defaultsKey(identifier)) }
        }
        let state = FixtureState()
        let host = NSHostingView(rootView: Fixture(state: state, prefix: prefix))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 860, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer { window.close() }
        try await pause()
        host.layoutSubtreeIfNeeded()
        try await pause()
        let splits = descendants(host, of: PracticeNativeSplitView.self)
        func split(_ suffix: String) throws -> PracticeNativeSplitView {
            guard let value = splits.first(where: { $0.splitIdentifier == prefix + suffix }) else { throw Failure.check("Missing split " + suffix) }
            return value
        }
        let columns = try split(".columns")
        let workspace = try split(".workspace")
        let output = try split(".code-output")
        guard let editor = descendants(host, of: NSTextView.self).first else { throw Failure.check("Missing production code editor") }
        try require(columns.subviews.count == 2 && workspace.subviews.count == 2 && output.subviews.count == 2, "Split panes missing")
        try require(abs(columns.subviews[0].frame.width / (columns.bounds.width - 8) - 0.28) < 0.02, "Initial width fraction was equalized")
        try require(abs(workspace.subviews[0].frame.height / (workspace.bounds.height - 8) - 0.78) < 0.02, "Initial height fraction was equalized")
        try require(output.subviews[0].frame.height > 350, "Editor starts unnecessarily small at 860×640: \(output.subviews[0].frame)")
        print("PASS nested initial fractions reserve most space for the production code editor")

        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("\nprint('undo survives')", replacementRange: editor.selectedRange())
        let editedCode = editor.string
        let selection = editor.selectedRange()
        let undoManager = editor.undoManager
        try require(editedCode.contains("undo survives"), "Could not type into production editor")
        try require(undoManager?.canUndo == true, "Editor did not record undo")

        let originalWidth = editor.bounds.width
        columns.setPosition(220, ofDividerAt: 0)
        try await pause()
        try require(editor.bounds.width > originalWidth + 10, "Dragging the column boundary did not enlarge editor width")
        workspace.setPosition(workspace.bounds.height - 8 - 110, ofDividerAt: 0)
        try await pause()
        let beforeOutput = editor.bounds.height
        output.setPosition(output.bounds.height - 8 - 55, ofDividerAt: 0)
        try await pause()
        try require(editor.bounds.height > beforeOutput + 10, "Dragging result boundary did not enlarge editor height")
        let largeHeight = editor.bounds.height
        workspace.setPosition(310, ofDividerAt: 0)
        try await pause()
        try require(editor.bounds.height < largeHeight - 100, "Dragging coaching boundary did not change editor height")
        try require(descendants(host, of: NSTextView.self).first === editor, "A divider move replaced the code editor")
        try require(editor.string == editedCode && editor.selectedRange() == selection, "A divider move lost code or selection")
        try require(editor.undoManager === undoManager && undoManager?.canUndo == true, "A divider move lost undo history")
        print("PASS width and both height boundaries resize without replacing the editor, draft, selection, or undo")

        state.taskTitle = "Задание после обновления интерфейса"
        try await pause()
        try require(descendants(host, of: NSTextView.self).first === editor, "A SwiftUI update replaced the editor")
        try require(editor.undoManager === undoManager && undoManager?.canUndo == true, "A SwiftUI update lost undo history")
        let saved = columns.dividerFraction
        try require(abs((UserDefaults.standard.object(forKey: PracticeNativeSplitView.defaultsKey(prefix + ".columns")) as? Double ?? -1) - Double(saved)) < 0.001, "Divider position was not saved")
        window.setContentSize(NSSize(width: 700, height: 440))
        try await pause()
        try require(abs(columns.dividerFraction - saved) < 0.001, "Minimum-size clamping overwrote the preferred split ratio")
        window.setContentSize(NSSize(width: 1100, height: 740))
        try await pause()
        try require(abs(columns.dividerFraction - saved) < 0.001, "Window resize changed the saved split ratio")
        try require(abs(columns.subviews[0].frame.width / (columns.bounds.width - 8) - saved) < 0.01, "Window resize did not preserve the split ratio")
        print("PASS content updates and window resize preserve divider ratio and editor undo")

        let reopened = NSHostingView(rootView: Fixture(state: state, prefix: prefix))
        window.contentView = reopened
        try await pause()
        reopened.layoutSubtreeIfNeeded()
        try await pause()
        guard let restored = descendants(reopened, of: PracticeNativeSplitView.self).first(where: { $0.splitIdentifier == prefix + ".columns" }) else { throw Failure.check("Missing reopened split") }
        try require(abs(restored.dividerFraction - saved) < 0.001, "Reopened workspace lost persisted split ratio")
        try require(abs(restored.subviews[0].frame.width / (restored.bounds.width - 8) - saved) < 0.01, "Reopened pane geometry did not use persisted fraction")
        print("PASS reopening restores persisted divider geometry")
    }
}
