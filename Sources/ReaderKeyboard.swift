import AppKit

enum ReaderKeyAction: Equatable {
    case previousPage, nextPage, scrollUp, scrollDown

    var direction: Int {
        self == .previousPage || self == .scrollUp ? -1 : 1
    }

    var movesPage: Bool { self == .previousPage || self == .nextPage }
}

enum ReaderKeyboard {
    @MainActor static func action(for event: NSEvent, in window: NSWindow,
                                 searchVisible: Bool) -> ReaderKeyAction? {
        guard event.type == .keyDown, event.window === window, !searchVisible,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              !(window.firstResponder is NSTextView),
              !(window.firstResponder is NSTextField) else { return nil }
        switch event.keyCode {
        case 123: return .previousPage
        case 124: return .nextPage
        case 125: return .scrollDown
        case 126: return .scrollUp
        default: return nil
        }
    }
}
