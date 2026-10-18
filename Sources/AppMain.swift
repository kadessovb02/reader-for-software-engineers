import AppKit
import SwiftUI
import PDFKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = ReaderStore()
    let ai = CodexService()
    lazy var chat = ReaderChat(store: store, service: ai)
    var window: NSWindow!
    var panel: NSPanel?
    var inspector: PageInspectorController?
    var practice: PracticeWindowController?
    var hotkey: GlobalHotKey?
    var keyboardMonitor: Any?
    var normalFrame = NSRect(x: 0, y: 0, width: 980, height: 780)
    var pendingCompact = false
    var pendingFiles: [String] = []
    var readyToImport = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: normalFrame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Лист"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 360, height: 420)
        window.backgroundColor = store.theme.nsBackground; window.delegate = self
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        window.contentView = NSHostingView(rootView: ReaderRootView(store: store, ai: ai).ignoresSafeArea())
        if !window.setFrameUsingName("ListReaderNormalFrame") { window.center() }
        normalFrame = window.frame
        store.onToggleChat = { [weak self] in self?.toggleChat() }
        store.onToggleCompact = { [weak self] in self?.toggleCompact() }
        store.onToggleFullScreen = { [weak self] in self?.window.toggleFullScreen(nil) }
        store.onToggleFocus = { [weak self] in self?.focusMode() }
        store.onInspectPage = { [weak self] in self?.inspectPage() }
        store.onTogglePractice = { [weak self] in self?.togglePractice() }
        store.onHide = { [weak self] in self?.hide() }
        buildMenus()
        hotkey = GlobalHotKey { [weak self] in self?.toggleVisibility() }
        if hotkey?.registrationSucceeded != true { store.error = "Горячая клавиша ⌃⌥Пробел занята другой программой. Читалку можно открыть из Dock." }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if let action = ReaderKeyboard.action(for: event, in: self.window,
                                                  searchVisible: self.store.searchVisible),
               let navigate = self.store.onReadingKey {
                navigate(action)
                return nil
            }
            if event.keyCode == 53 {
                if self.practice?.window?.isKeyWindow == true { self.practice?.model.cancel(); self.practice?.window?.orderOut(nil); self.window.makeKeyAndOrderFront(nil); return nil }
                if self.inspector?.window?.isKeyWindow == true { self.inspector?.close(); self.window.makeKey(); return nil }
                if self.panel?.isKeyWindow == true { self.panel?.orderOut(nil); return nil }
                if self.store.searchVisible { self.store.searchVisible = false; return nil }
                if self.store.contentsVisible { self.store.contentsVisible = false; return nil }
                if self.store.libraryVisible { self.store.libraryVisible = false; return nil }
                if self.store.focus { self.store.focus = false; self.updateTrafficLights(); return nil }
            }
            return event
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        Task {
            await store.start()
            readyToImport = true
            let files = pendingFiles; pendingFiles.removeAll()
            for file in files { await store.importBook(URL(fileURLWithPath: file)) }
            await ai.refreshStatus()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { practice?.model.cancel(); store.save(); chat.persist(); ai.cancel(); if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) } }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await store.captureContext?(); store.save(); chat.persist(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard readyToImport else { pendingFiles.append(contentsOf: filenames); sender.reply(toOpenOrPrint: .success); return }
        show(); Task { for file in filenames { await store.importBook(URL(fileURLWithPath: file)) }; sender.reply(toOpenOrPrint: .success) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if sender === window { hide() } else { sender.orderOut(nil) }; return false }
    func windowDidResize(_ notification: Notification) { if !store.compact && !window.styleMask.contains(.fullScreen) { normalFrame = window.frame } }
    func windowDidMove(_ notification: Notification) { if !store.compact && !window.styleMask.contains(.fullScreen) { normalFrame = window.frame } }
    func windowDidExitFullScreen(_ notification: Notification) { if pendingCompact { pendingCompact = false; toggleCompact() }; updateTrafficLights() }
    func windowDidEnterFullScreen(_ notification: Notification) { updateTrafficLights() }
    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func hide() {
        Task { await store.captureContext?(); store.save() }
        if !store.compact && !window.styleMask.contains(.fullScreen) { window.saveFrame(usingName: "ListReaderNormalFrame") }
        practice?.model.cancel(); practice?.window?.orderOut(nil); inspector?.close(); panel?.orderOut(nil); window.orderOut(nil)
    }
    func toggleVisibility() { if NSApp.isActive && window.isVisible { hide() } else { show() } }
    @objc func toggleChat() {
        if let panel, panel.isVisible { panel.orderOut(nil); window.makeKey(); return }
        if panel == nil {
            let view = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 530), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            view.title = "Помощник · Лист"; view.titleVisibility = .hidden; view.titlebarAppearsTransparent = true
            view.isFloatingPanel = true; view.hidesOnDeactivate = false; view.isReleasedWhenClosed = false
            view.minSize = NSSize(width: 340, height: 390); view.maxSize = NSSize(width: 540, height: 800)
            view.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications]
            view.contentView = NSHostingView(rootView: ChatPanelView(chat: chat, store: store, ai: ai).ignoresSafeArea()); view.delegate = self
            view.standardWindowButton(.zoomButton)?.isHidden = true
            panel = view
        }
        guard let panel else { return }
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let main = window.frame
        var x = main.maxX - panel.frame.width - 20
        if main.maxX + panel.frame.width + 16 < screen.maxX { x = main.maxX + 12 }
        x = max(screen.minX + 10, min(x, screen.maxX - panel.frame.width - 10))
        let y = max(screen.minY + 12, min(main.maxY - panel.frame.height - 65, screen.maxY - panel.frame.height - 12))
        panel.setFrameOrigin(NSPoint(x: x, y: y)); panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
        Task { await store.captureContext?(); await ai.refreshStatus() }
    }
    @objc func toggleCompact() {
        if window.styleMask.contains(.fullScreen) { pendingCompact = true; window.toggleFullScreen(nil); return }
        store.compact.toggle()
        panel?.orderOut(nil)
        if store.compact {
            store.libraryVisible = false; store.contentsVisible = false; store.searchVisible = false
            normalFrame = window.frame
            window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications]
            let visible = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
            window.setFrame(NSRect(x: visible.maxX - 415, y: max(visible.minY + 20, visible.maxY - 650), width: 390, height: min(600, visible.height - 40)), display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else {
            window.level = .normal; window.collectionBehavior = [.managed, .fullScreenPrimary]
            window.setFrame(normalFrame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        updateTrafficLights()
    }
    func updateTrafficLights() { for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(type)?.isHidden = store.focus }; if store.compact { window.standardWindowButton(.zoomButton)?.isHidden = true } }
    @objc func openBook() { store.openPanel() }
    @objc func togglePractice() {
        if practice?.window?.isKeyWindow == true { practice?.model.cancel(); practice?.window?.orderOut(nil); window.makeKeyAndOrderFront(nil); return }
        if practice == nil {
            let controller = PracticeWindowController(store: store, service: ai)
            controller.model.reveal = { [weak self] source, bookID in
                guard let self else { return }
                Task {
                    if self.store.selectedID != bookID {
                        self.store.save(); self.store.selectedID = bookID
                        await self.store.loadSelected()
                    }
                    self.show()
                    await self.store.revealPracticeSource(source)
                }
            }
            practice = controller
        }
        inspector?.close()
        practice?.present(relativeTo: window)
    }
    @objc func inspectPage() {
        guard let view = findPDF(window.contentView), let document = view.document,
              let page = view.page(for: NSPoint(x: view.bounds.midX, y: view.bounds.midY), nearest: true) ?? view.currentPage else { return }
        inspector?.close()
        let controller = PageInspectorController(sourcePage: page, pageNumber: document.index(for: page) + 1, bookTitle: store.book?.title ?? "Книга")
        inspector = controller
        controller.present(relativeTo: window)
    }
    @objc func showLibrary() { store.libraryVisible.toggle() }
    @objc func focusMode() { store.focus.toggle(); updateTrafficLights() }
    @objc func fullScreen() { if store.compact { toggleCompact() }; window.toggleFullScreen(nil) }
    @objc func settings() { store.libraryVisible = true; store.settingsVisible = true }
    @objc func find() { show(); store.searchVisible = true }
    @objc func closeWindow() { if practice?.window?.isKeyWindow == true { practice?.model.cancel(); practice?.window?.orderOut(nil) } else if inspector?.window?.isKeyWindow == true { inspector?.close() } else if panel?.isKeyWindow == true { panel?.orderOut(nil) } else { hide() } }
    @objc func zoomIn() { if let pdf = findPDF(NSApp.keyWindow?.contentView ?? window.contentView) { pdf.zoomIn(nil) } else { store.fontSize = min(32, store.fontSize + 1) } }
    @objc func zoomOut() { if let pdf = findPDF(NSApp.keyWindow?.contentView ?? window.contentView) { pdf.zoomOut(nil) } else { store.fontSize = max(15, store.fontSize - 1) } }
    func findPDF(_ view: NSView?) -> PDFView? { if let pdf = view as? PDFView { return pdf }; for child in view?.subviews ?? [] { if let pdf = findPDF(child) { return pdf } }; return nil }
    func buildMenus() {
        let bar = NSMenu(); NSApp.mainMenu = bar
        let appItem = NSMenuItem(); bar.addItem(appItem); let appMenu = NSMenu(title: "Лист"); appItem.submenu = appMenu
        add(appMenu, "О программе Лист", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", target: NSApp)
        appMenu.addItem(.separator()); add(appMenu, "Настройки…", #selector(settings), ",")
        appMenu.addItem(.separator()); add(appMenu, "Скрыть Лист", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(appMenu, "Завершить Лист", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = menu("Файл", bar: bar); add(file, "Добавить книгу…", #selector(openBook), "o"); add(file, "Библиотека", #selector(showLibrary), "l"); file.addItem(.separator()); add(file, "Закрыть окно", #selector(closeWindow), "w")
        let edit = menu("Правка", bar: bar)
        add(edit, "Отменить", Selector(("undo:")), "z", target: nil); add(edit, "Повторить", Selector(("redo:")), "z", modifiers: [.command, .shift], target: nil)
        edit.addItem(.separator()); add(edit, "Вырезать", #selector(NSText.cut(_:)), "x", target: nil); add(edit, "Скопировать", #selector(NSText.copy(_:)), "c", target: nil); add(edit, "Вставить", #selector(NSText.paste(_:)), "v", target: nil); add(edit, "Выделить всё", #selector(NSText.selectAll(_:)), "a", target: nil)
        edit.addItem(.separator()); add(edit, "Найти…", #selector(find), "f")
        let view = menu("Вид", bar: bar)
        add(view, "Развернуть схему…", #selector(inspectPage), "r", modifiers: [.command, .shift])
        add(view, "Практика по прочитанному…", #selector(togglePractice), "p", modifiers: [.command, .shift])
        add(view, "Чат по текущей странице", #selector(toggleChat), "j"); add(view, "Компактное окно", #selector(toggleCompact), "m", modifiers: [.command, .shift]); add(view, "Режим фокуса", #selector(focusMode), "f", modifiers: [.command, .shift]); add(view, "Полный экран", #selector(fullScreen), "f", modifiers: [.command, .control])
        view.addItem(.separator()); add(view, "Увеличить", #selector(zoomIn), "+"); add(view, "Уменьшить", #selector(zoomOut), "-")
        let windowMenu = menu("Окно", bar: bar); NSApp.windowsMenu = windowMenu
        add(windowMenu, "Свернуть", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil)
    }
    func menu(_ name: String, bar: NSMenu) -> NSMenu { let item = NSMenuItem(); let menu = NSMenu(title: name); item.submenu = menu; bar.addItem(item); return menu }
    func add(_ menu: NSMenu, _ name: String, _ action: Selector, _ key: String, modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
        let item = NSMenuItem(title: name, action: action, keyEquivalent: key); item.keyEquivalentModifierMask = modifiers
        item.target = target ?? (action.description.contains("copy:") || action.description.contains("cut:") || action.description.contains("paste:") || action.description.contains("selectAll:") || action.description.contains("undo:") || action.description.contains("redo:") || action.description.contains("performMiniaturize:") ? nil : self)
        menu.addItem(item)
    }
}

@main struct ListReaderMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
