import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct BookRecord: Codable, Identifiable {
    var id: String = UUID().uuidString
    var title: String
    var author: String = ""
    var format: String
    var isSample: Bool = false
    var chapter: Int = 0
    var progress: Double = 0
    var page: Int = 0
    var pageOffset: Double = 0
    var overview: String = ""
    var lastRead: Date = Date()
    var positions: [String: Double] = [:]
    // Optional so libraries saved before archiving was available still decode.
    var archived: Bool? = nil
    var isArchived: Bool { archived == true }
}

struct LibraryState: Codable {
    var books: [BookRecord]
    var selectedID: String
}

enum PaperTheme: String, CaseIterable, Codable {
    case paper, light, dark
    var title: String { switch self { case .paper: return "Бумажный"; case .light: return "Светлая"; case .dark: return "Ночная" } }
    var background: Color { Color(nsColor: nsBackground) }
    var pageColor: Color { Color(nsColor: nsPageColor) }
    var nsBackground: NSColor {
        switch self {
        case .paper: return NSColor(calibratedRed: 228.0 / 255, green: 221.0 / 255, blue: 207.0 / 255, alpha: 1)
        case .light: return NSColor(calibratedWhite: 0.995, alpha: 1)
        case .dark: return NSColor(calibratedRed: 0.102, green: 0.114, blue: 0.110, alpha: 1)
        }
    }
    var nsPageColor: NSColor {
        switch self {
        case .paper: return NSColor(calibratedRed: 246.0 / 255, green: 238.0 / 255, blue: 219.0 / 255, alpha: 1)
        case .light: return .white
        case .dark: return nsBackground
        }
    }
    var ink: Color {
        switch self {
        case .paper: return Color(red: 52.0 / 255, green: 46.0 / 255, blue: 38.0 / 255)
        case .light: return Color(red: 0.19, green: 0.22, blue: 0.20)
        case .dark: return Color(red: 0.85, green: 0.86, blue: 0.82)
        }
    }
    var cssBackground: String { self == .paper ? "#e4ddcf" : self == .dark ? "#1a1d1c" : "#fefefe" }
    var cssPage: String { self == .paper ? "#f6eedb" : self == .dark ? "#1a1d1c" : "#ffffff" }
    var cssInk: String { self == .paper ? "#342e26" : self == .dark ? "#daddd2" : "#303831" }
}

@MainActor final class ReaderStore: ObservableObject {
    @Published var books: [BookRecord] = []
    @Published var selectedID = ""
    @Published var content: ImportedBook?
    @Published var pdfDocument: PDFDocument?
    @Published var isLoading = false
    @Published var error: String?
    @Published var libraryVisible = false
    @Published var contentsVisible = false
    @Published var settingsVisible = false
    @Published var focus = false
    @Published var compact = false
    @Published var visibleText = ""
    @Published var selection = ""
    @Published var currentHeading = ""
    @Published var renderToken = UUID()
    @Published var searchQuery = ""
    @Published var searchVisible = false
    @Published var theme: PaperTheme { didSet { UserDefaults.standard.set(theme.rawValue, forKey: "paperTheme") } }
    @Published var fontSize: Double { didSet { UserDefaults.standard.set(fontSize, forKey: "readerFontSize") } }
    @Published var serif: Bool { didSet { UserDefaults.standard.set(serif, forKey: "readerSerif") } }
    @Published var lineHeight: Double { didSet { UserDefaults.standard.set(lineHeight, forKey: "readerLineHeight") } }
    let root: URL
    private var saveTask: Task<Void, Never>?
    private var loadID = UUID()
    var onToggleChat: (() -> Void)?
    var onToggleCompact: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onToggleFocus: (() -> Void)?
    var onInspectPage: (() -> Void)?
    var onTogglePractice: (() -> Void)?
    var pendingPracticeSearch: String?
    var onRevealPracticePDF: ((Int, String) -> Void)?
    var focusedPDFPage: (() -> Int?)?
    var onHide: (() -> Void)?
    var captureContext: (() async -> Void)?
    var onSearch: ((String, Bool) -> Void)?
    var onScroll: ((Double) -> Void)?
    var onReadingKey: ((ReaderKeyAction) -> Void)?

    init(root: URL? = nil) {
        let profilePath = ProcessInfo.processInfo.environment["READER_DATA_DIR"]
            ?? Bundle.main.object(forInfoDictionaryKey: "ReaderDataDirectory") as? String
        let profile = profilePath.flatMap { value -> URL? in
            guard !value.isEmpty, value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        self.root = root ?? profile ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReaderForEngineers", isDirectory: true)
        theme = PaperTheme(rawValue: UserDefaults.standard.string(forKey: "paperTheme") ?? "paper") ?? .paper
        fontSize = UserDefaults.standard.object(forKey: "readerFontSize") as? Double ?? 21
        serif = UserDefaults.standard.object(forKey: "readerSerif") as? Bool ?? true
        lineHeight = UserDefaults.standard.object(forKey: "readerLineHeight") as? Double ?? 1.7
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        let savedLibrary = self.root.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: savedLibrary), let state = try? JSONDecoder().decode(LibraryState.self, from: data) {
            books = state.books; selectedID = state.selectedID
        } else if !FileManager.default.fileExists(atPath: savedLibrary.path) {
            books = []; selectedID = ""
        } else {
            error = "Не удалось прочитать библиотеку. Сохранённые файлы книг остались на этом Mac."
        }
        if !books.contains(where: { $0.id == selectedID }) { selectedID = activeBooks.first?.id ?? books.first?.id ?? "" }
    }

    var book: BookRecord? { books.first { $0.id == selectedID } }
    var activeBooks: [BookRecord] { books.filter { !$0.isArchived } }
    var archivedBooks: [BookRecord] { books.filter(\.isArchived) }
    var chapter: ImportedChapter? {
        guard let content, let index = book?.chapter, content.chapters.indices.contains(index) else { return nil }
        return content.chapters[index]
    }
    var chapterTitle: String { currentHeading.isEmpty ? (chapter?.title ?? (pdfDocument != nil ? "Страница \((book?.page ?? 0) + 1)" : "")) : currentHeading }
    var totalProgress: Double {
        guard let book else { return 0 }
        if let pdf = pdfDocument { return Double(book.page) / Double(max(1, pdf.pageCount)) }
        return (Double(book.chapter) + book.progress) / Double(max(1, content?.chapters.count ?? 1))
    }
    func folder(_ id: String) -> URL { root.appendingPathComponent("Books/\(id)", isDirectory: true) }
    func source(_ record: BookRecord) -> URL { folder(record.id).appendingPathComponent("book.\(record.format)") }

    func start() async {
        await loadSelected()
    }

    func updateBook(_ update: (inout BookRecord) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == selectedID }) else { return }
        update(&books[index]); scheduleSave()
    }
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(nanoseconds: 350_000_000); guard !Task.isCancelled else { return }; save() }
    }
    func save() {
        guard let data = try? JSONEncoder().encode(LibraryState(books: books, selectedID: selectedID)) else { return }
        do { try data.write(to: root.appendingPathComponent("library.json"), options: .atomic) }
        catch { self.error = "Не удалось сохранить место чтения: \(error.localizedDescription)" }
    }
    func select(_ id: String) {
        guard books.contains(where: { $0.id == id }) else { return }
        if selectedID == id { libraryVisible = false; return }
        selectedID = id; clearReadingContent(); libraryVisible = false; contentsVisible = false; save()
        Task { await loadSelected() }
    }
    /// Reorder within the active or archived section without touching any reading position.
    func moveBook(_ id: String, to destination: Int) {
        guard let record = books.first(where: { $0.id == id }) else { return }
        let slots = books.indices.filter { books[$0].isArchived == record.isArchived }
        var section = slots.map { books[$0] }
        guard let source = section.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, destination), section.count - 1)
        guard source != target else { return }
        section.insert(section.remove(at: source), at: target)
        for (index, item) in zip(slots, section) { books[index] = item }
        save()
    }
    func moveBook(_ id: String, by offset: Int) {
        guard let record = books.first(where: { $0.id == id }) else { return }
        let section = books.filter { $0.isArchived == record.isArchived }
        guard let index = section.firstIndex(where: { $0.id == id }) else { return }
        moveBook(id, to: index + offset)
    }
    func setArchived(_ archived: Bool, for id: String) {
        guard let index = books.firstIndex(where: { $0.id == id }), books[index].isArchived != archived else { return }
        books[index].archived = archived
        if archived, selectedID == id, let next = nextBook(after: index, activeOnly: true) {
            selectedID = next.id; clearReadingContent()
            Task { await loadSelected() }
        }
        save()
    }
    /// Only the imported library copy is moved to Trash; the original import URL is never stored or removed.
    @discardableResult func deleteBook(_ id: String) -> Bool {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return false }
        let directory = folder(id).standardizedFileURL
        let booksDirectory = root.appendingPathComponent("Books", isDirectory: true).standardizedFileURL
        guard directory.deletingLastPathComponent() == booksDirectory else {
            error = "Не удалось удалить книгу: неверная папка библиотеки."; return false
        }
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
            }
        } catch {
            self.error = "Не удалось переместить книгу в Корзину. \(error.localizedDescription)"; return false
        }
        let wasSelected = selectedID == id
        let next = nextBook(after: index, activeOnly: true) ?? nextBook(after: index, activeOnly: false)
        books.remove(at: index)
        if wasSelected {
            selectedID = next?.id ?? ""; clearReadingContent()
            if !selectedID.isEmpty { Task { await loadSelected() } }
        }
        save()
        return true
    }
    private func nextBook(after index: Int, activeOnly: Bool) -> BookRecord? {
        let following = Array(books.dropFirst(index + 1)) + Array(books.prefix(index))
        return following.first { !activeOnly || !$0.isArchived }
    }
    private func clearReadingContent() {
        loadID = UUID(); isLoading = false
        content = nil; pdfDocument = nil; visibleText = ""; selection = ""; currentHeading = ""; searchQuery = ""
        searchVisible = false; contentsVisible = false; pendingPracticeSearch = nil
        captureContext = nil; onSearch = nil; onScroll = nil; focusedPDFPage = nil; onReadingKey = nil; onRevealPracticePDF = nil
        renderToken = UUID()
    }
    func loadSelected() async {
        clearReadingContent()
        let request = UUID(); loadID = request
        guard let book, book.format != "missing" else { isLoading = false; return }
        isLoading = true
        do {
            if book.format == "pdf" {
                let url = source(book)
                let document = await Task.detached(priority: .userInitiated) { PDFDocument(url: url) }.value
                guard loadID == request else { return }
                guard let document, document.pageCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
                pdfDocument = document
            } else {
                let cache = folder(book.id).appendingPathComponent("content.json")
                let url = source(book); let dir = folder(book.id)
                let loaded = try await Task.detached(priority: .userInitiated) {
                    if let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode(ImportedBook.self, from: data) { return cached }
                    let parsed = try BookImporter.load(url: url, cacheDirectory: dir)
                    try JSONEncoder().encode(parsed).write(to: cache, options: .atomic)
                    return parsed
                }.value
                guard loadID == request else { return }
                content = loaded
                updateBook { $0.chapter = min($0.chapter, max(0, loaded.chapters.count - 1)) }
            }
            renderToken = UUID()
            updateBook { $0.lastRead = Date() }
        } catch {
            guard loadID == request else { return }
            self.error = "Не удалось открыть книгу. \(error.localizedDescription)"
        }
        if loadID == request { isLoading = false }
    }
    func openPanel(replacingDefault: Bool = false) {
        let panel = NSOpenPanel(); panel.title = replacingDefault ? "Выберите книгу Мартина Клеппмана" : "Добавить книгу"
        panel.allowedContentTypes = ["pdf", "epub", "fb2", "txt", "md", "html", "htm", "rtf", "docx"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = !replacingDefault; panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                for url in urls { await self?.importBook(url, replacingDefault: replacingDefault) }
            }
        }
    }
    func importBook(_ url: URL, replacingDefault: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        let ext = url.pathExtension.lowercased()
        guard ["pdf", "epub", "fb2", "txt", "md", "html", "htm", "rtf", "docx"].contains(ext) else {
            isLoading = false; error = "Этот формат пока не поддерживается. Откройте PDF, EPUB, FB2, TXT, Markdown, HTML, RTF или DOCX."; return
        }
        let id = UUID().uuidString; let destination = folder(id); let file = destination.appendingPathComponent("book.\(ext)")
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let allowed = url.startAccessingSecurityScopedResource(); defer { if allowed { url.stopAccessingSecurityScopedResource() } }
            let sourceURL = url
            try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: sourceURL, to: file) }.value
            var record = BookRecord(id: id, title: url.deletingPathExtension().lastPathComponent, format: ext)
            if ext == "pdf" {
                guard let pdf = PDFDocument(url: file), pdf.pageCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
                record.title = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? record.title
                record.author = pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String ?? ""
            } else {
                var loaded = try await Task.detached(priority: .userInitiated) { try BookImporter.load(url: file, cacheDirectory: destination) }.value
                if loaded.title == file.deletingPathExtension().lastPathComponent { loaded.title = url.deletingPathExtension().lastPathComponent }
                record.title = loaded.title; record.author = loaded.author
                try JSONEncoder().encode(loaded).write(to: destination.appendingPathComponent("content.json"), options: .atomic)
            }
            if replacingDefault {
                record.title = "Высоконагруженные приложения"; record.author = "Мартин Клеппман"
                record.overview = books.first(where: { $0.id == "kleppmann" })?.overview ?? ""
                books.removeAll { $0.id == "kleppmann" && $0.format == "missing" }
            }
            books.append(record); selectedID = id; libraryVisible = false; save()
            isLoading = false; await loadSelected()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            isLoading = false; self.error = "Не удалось добавить книгу. \(error.localizedDescription)"
        }
    }
    func showGuide() async {
        if books.contains(where: { $0.id == "guide" }) { select("guide"); return }
        let guide = ImportedBook(title: "Несколько спокойных страниц", author: "Лист · руководство", chapters: [
            ImportedChapter(title: "01 · Просто читайте", html: "<p class='eyebrow'>ДОБРО ПОЖАЛОВАТЬ В ЛИСТ</p><h1>Несколько<br>спокойных страниц</h1><p class='lead'>Книга, ваше внимание<br>и немного свободного пространства.</p><hr><h2>Продолжайте с того же места</h2><p>Закройте окно, переключитесь на работу или завершите приложение. Лист сохранит книгу, главу и место чтения. При следующем открытии вы вернётесь сюда.</p><p>Добавьте свою книгу через кнопку библиотеки в левом верхнем углу или просто перетащите файл в окно. Поддерживаются PDF, EPUB, FB2, TXT, Markdown, HTML, RTF и DOCX без DRM.</p><h2>У каждого режима своё место</h2><p>Обычное окно удобно для повседневного чтения. Полноэкранный режим убирает всё лишнее. Нажмите кнопку с маленьким окном, чтобы получить компактную читалку поверх других программ.</p><p>В режиме фокуса панели исчезнут. Чтобы вернуть их, подведите указатель к верхнему краю или нажмите ⌘⇧F.</p><h2>Чат появляется по вашему желанию</h2><p>Нажмите ⌘J. Небольшое окно помощника откроется рядом с книгой. Выделите непонятный абзац и задайте вопрос: помощник получит выделение, видимый текст, название книги и главу.</p><p>Вход выполняется через установленный Codex и ваш аккаунт ChatGPT. Пока вы не отправили вопрос, текст книги никуда не передаётся.</p><h2>Небольшой эксперимент</h2><p>Представьте библиотеку, в которой у каждой книги есть собственная закладка. Хранить одну закладку на всю библиотеку было бы неудобно: открывая другую книгу, вы теряли бы место в предыдущей. Поэтому Лист сохраняет позицию отдельно для каждой книги и каждой главы.</p><p>Выделите этот абзац и попросите помощника объяснить аналогию с базой данных. Или перейдите к следующей главе с помощью стрелки внизу.</p>", text: "Руководство Лист. Сохранение места, форматы, режимы чтения и чат по текущему тексту.", basePath: nil),
            ImportedChapter(title: "02 · Под рукой", html: "<p class='eyebrow'>УПРАВЛЕНИЕ</p><h1>Всё под рукой</h1><p class='lead'>Несколько сочетаний,<br>которые быстро запомнятся.</p><h2>Открыть и скрыть</h2><p><strong>⌃⌥Пробел</strong> — показать или скрыть читалку из любой программы. Приложение остаётся запущенным после закрытия окна, чтобы горячая клавиша работала.</p><p><strong>⌘J</strong> — открыть или закрыть чат. <strong>Esc</strong> — закрыть вспомогательную панель или выйти из режима фокуса. <strong>⌘W</strong> — скрыть читалку.</p><h2>Читать по-своему</h2><p><strong>⌘⇧M</strong> — компактное окно поверх других программ. <strong>⌃⌘F</strong> — полный экран. <strong>⌘⇧F</strong> — режим фокуса.</p><p><strong>⌘O</strong> — добавить книгу. <strong>⌘L</strong> — библиотека. <strong>⌘F</strong> — поиск по текущей главе или PDF.</p><p><strong>← / →</strong> — предыдущая или следующая страница PDF; в текстовой книге — экран текста. <strong>↑ / ↓</strong> — прокрутка вверх или вниз.</p><p>Размер текста, шрифт и цвет бумаги доступны через кнопку Aa. Выберите <strong>Aa → Бумажный</strong>, чтобы смягчить белый фон самого PDF и видеть границы страниц. Исходная вёрстка сохранится; масштаб можно изменить жестом трекпада.</p><h2>Порядок в библиотеке</h2><p>В меню <strong>…</strong> у книги доступны команды «Выше» и «Ниже» для изменения порядка, архивирование и удаление. Архив скрывает книгу из основного списка; откройте «Архив» и выберите «Вернуть из архива», чтобы вернуть её вместе с сохранённым местом чтения.</p><p>При удалении копия книги и её данные из библиотеки перемещаются в Корзину macOS. Исходный файл, который вы добавляли, остаётся на месте.</p><h2>Ваш контекст</h2><p>В настройках можно добавить краткое описание книги. Оно будет передаваться помощнику вместе с текущей главой и видимым фрагментом, чтобы не объяснять всё заново.</p><p>История чата хранится отдельно для каждой книги на этом Mac. В новом вопросе используется несколько последних сообщений. Можно начать новый разговор кнопкой очистки в окне чата.</p>", text: "Горячие клавиши и настройки читалки.", basePath: nil)
        ])
        do {
            try FileManager.default.createDirectory(at: folder("guide"), withIntermediateDirectories: true)
            try JSONEncoder().encode(guide).write(to: folder("guide").appendingPathComponent("content.json"), options: .atomic)
            books.append(BookRecord(id: "guide", title: guide.title, author: guide.author, format: "guide")); select("guide")
        } catch { self.error = error.localizedDescription }
    }
    func goChapter(_ index: Int) {
        guard let content, content.chapters.indices.contains(index) else { return }
        updateBook { $0.chapter = index; $0.progress = $0.positions[String(index)] ?? 0 }
        currentHeading = ""; visibleText = ""; selection = ""; searchQuery = ""; contentsVisible = false; renderToken = UUID(); save()
    }
    func readingProgress(_ value: Double) {
        updateBook { $0.progress = min(1, max(0, value)); $0.positions[String($0.chapter)] = $0.progress }
    }
    func readingContext() -> ReadingContext {
        let pageText: String
        if let pdf = pdfDocument, let page = book?.page { pageText = pdf.page(at: page)?.string ?? "" }
        else { pageText = visibleText }
        return ReadingContext(book: book?.title ?? "", author: book?.author ?? "", chapter: chapterTitle,
                       location: pdfDocument != nil ? "Страница \((book?.page ?? 0) + 1) из \(pdfDocument?.pageCount ?? 0)" : "Глава \((book?.chapter ?? 0) + 1) из \(content?.chapters.count ?? 0), \(Int((book?.progress ?? 0) * 100))% главы",
                       overview: book?.overview ?? "", visibleText: pageText, selection: selection)
    }
}
