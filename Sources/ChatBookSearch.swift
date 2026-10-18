import Foundation
import PDFKit
import CryptoKit

/// Plain excerpts from one captured book. PDF page and imported chapter indexes are zero based.
struct ChatBookSource: Codable, Sendable, Identifiable {
    var id: String
    var location: String
    var title: String
    var text: String
    var page: Int?
    var chapter: Int?
}

struct ChatSearchRequest: Codable, Sendable {
    var scope: String
    var query: String
    var mode: String? = nil
    var section: String? = nil
}

struct ChatSearchResult: Codable, Sendable {
    var scope: String
    var note: String
    var sources: [ChatBookSource]
}

enum ChatBookSearchError: LocalizedError {
    case noBook, changedBook, unreadableSource, invalidScope
    var errorDescription: String? {
        switch self {
        case .noBook: return "Сначала откройте книгу."
        case .changedBook: return "Открытая книга изменилась. Задайте вопрос ещё раз."
        case .unreadableSource: return "Не удалось прочитать текст этой книги. Для сканированных страниц нужен OCR."
        case .invalidScope: return "Поиск доступен в текущей главе или прочитанной части книги."
        }
    }
}

/// A question keeps its original book and reading limit even if the reader moves elsewhere.
/// Each job opens its own PDFDocument, outside both MainActor and the rendered PDFKit object.
actor ChatBookSearchSession {
    nonisolated let bookID: String
    nonisolated let context: ReadingContext
    private let snapshot: ChatBookSearchSnapshot

    init(book: BookRecord, sourceURL: URL, cacheDirectory: URL, content: ImportedBook? = nil, visibleText: String = "", context: ReadingContext? = nil) {
        bookID = book.id
        self.context = context ?? ReadingContext(book: book.title, author: book.author, chapter: "Глава \(book.chapter + 1)",
                                                location: book.format == "pdf" ? "Страница \(book.page + 1) PDF" : "Глава \(book.chapter + 1)",
                                                overview: book.overview, visibleText: visibleText, selection: "")
        snapshot = ChatBookSearchSnapshot(book: book, sourceURL: sourceURL, cacheDirectory: cacheDirectory,
                                          content: content, visibleText: visibleText)
    }

    func retrieve(_ request: ChatSearchRequest) async throws -> ChatSearchResult {
        try Task.checkCancellation()
        guard request.scope == "chapter" || request.scope == "book" else { throw ChatBookSearchError.invalidScope }
        let captured = snapshot
        let worker = Task.detached(priority: .userInitiated) {
            try ChatBookSearchWorker.retrieve(request, snapshot: captured)
        }
        return try await withTaskCancellationHandler(operation: {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        }, onCancel: { worker.cancel() })
    }
}

private struct ChatBookSearchSnapshot: @unchecked Sendable {
    // Value-only copies. ImportedBook is never mutated after capture.
    var book: BookRecord
    var sourceURL: URL
    var cacheDirectory: URL
    var content: ImportedBook?
    var visibleText: String
}

private struct ChatSearchBoundary: Codable {
    var page: Int
    var title: String
}

private struct ChatTextCache: Codable {
    var version = 1
    var identity: String
    var pages: [String: String] = [:]
}

private enum ChatBookSearchWorker {
    static let maximumCharacters = 40_000
    static let maximumSources = 32
    static let blockCharacters = 1_400

    static func retrieve(_ request: ChatSearchRequest, snapshot: ChatBookSearchSnapshot) throws -> ChatSearchResult {
        try Task.checkCancellation()
        let values = try? snapshot.sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        let signature = "v1|\(snapshot.sourceURL.standardizedFileURL.path)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.creationDate?.timeIntervalSince1970 ?? 0)"
        let identity = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        let cacheURL = snapshot.cacheDirectory.appendingPathComponent("\(identity).json")
        var cache = ChatTextCache(identity: identity)
        // An overlarge/old cache is merely ignored; the book remains the source of truth.
        if let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1_024 * 1_024,
           let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode(ChatTextCache.self, from: data),
           saved.version == 1, saved.identity == identity { cache = saved }
        let oldCount = cache.pages.count
        let material: (sources: [ChatBookSource], note: String)
        if snapshot.book.format == "pdf" {
            material = try pdfSources(snapshot: snapshot, request: request, cache: &cache)
        } else {
            material = try textSources(snapshot: snapshot, request: request)
        }
        try Task.checkCancellation()
        // Cache failure never prevents a response. Only extracted text is saved, not prompts,
        // conversation, credentials, or the currently displayed PDFDocument.
        if cache.pages.count != oldCount,
           let data = try? JSONEncoder().encode(cache), data.count <= 64 * 1_024 * 1_024 {
            try? FileManager.default.createDirectory(at: snapshot.cacheDirectory, withIntermediateDirectories: true)
            try Task.checkCancellation()
            try? data.write(to: cacheURL, options: .atomic)
        }
        return try select(material.sources, request: request, note: material.note)
    }

    private static func pdfSources(snapshot: ChatBookSearchSnapshot, request: ChatSearchRequest,
                                   cache: inout ChatTextCache) throws -> (sources: [ChatBookSource], note: String) {
        guard let document = PDFDocument(url: snapshot.sourceURL), document.pageCount > 0 else { throw ChatBookSearchError.unreadableSource }
        let current = min(max(0, snapshot.book.page), document.pageCount - 1)
        var boundaries = outlineBoundaries(document)
        var detected: [ChatSearchBoundary] = []
        // Only examine already reached pages for book-wide retrieval. For a whole-current-
        // chapter request, scan ahead just until the next heading if the outline has no end.
        // Text from a later chapter is never entered in the cache by this scan.
        var rawCurrentChapter: [Int: String] = [:]
        for page in 0...current {
            try Task.checkCancellation()
            let text = pageText(page, document: document, cache: &cache)
            if let heading = headingBoundary(text, page: page) { detected.append(heading) }
        }
        boundaries = mergedBoundaries(boundaries, detected)
        let previous = boundaries.last(where: { $0.page <= current })
        var next = boundaries.first(where: { $0.page > current })?.page
        if request.scope == "chapter", previous != nil, next == nil, current + 1 < document.pageCount {
            let previousKey = previous.map { headingKey($0.title) }
            for page in (current + 1)..<document.pageCount {
                try Task.checkCancellation()
                let text = cache.pages[String(page)] ?? document.page(at: page)?.string ?? ""
                if let heading = headingBoundary(text, page: page), headingKey(heading.title) != previousKey {
                    next = page
                    boundaries = mergedBoundaries(boundaries, [heading])
                    break
                }
                // Without a recognized start, guessing a chapter would expose unrelated
                // pages. Only inspect for the next boundary; do not save their body text.
                if previous != nil { rawCurrentChapter[page] = text }
            }
        }
        let range: Range<Int>
        let note: String
        if request.scope == "book" {
            range = 0..<(current + 1)
            note = "Поиск только в текущей книге до страницы PDF \(current + 1) включительно. Более поздние страницы исключены. Номера PDF могут отличаться от печатных."
        } else if let previous {
            range = previous.page..<(next ?? document.pageCount)
            note = "Текущая глава «\(previous.title)», страницы PDF \(range.lowerBound + 1)–\(range.upperBound). В пределах этой главы доступен весь текст, включая страницы после текущей."
        } else {
            range = current..<(current + 1)
            note = "Границы текущей главы не удалось надёжно определить. Проверена текущая страница PDF \(current + 1); для более широкого поиска используйте scope=book, где действует граница текущей страницы."
        }
        var result: [ChatBookSource] = []
        for page in range {
            try Task.checkCancellation()
            if let scanned = rawCurrentChapter[page] { cache.pages[String(page)] = scanned }
            let text = pageText(page, document: document, cache: &cache)
            let title = boundaries.last(where: { $0.page <= page })?.title ?? "Начало книги"
            result.append(contentsOf: try chunks(text).enumerated().map { offset, text in
                ChatBookSource(id: "p\(page + 1)-b\(offset + 1)", location: "Страница \(page + 1) PDF", title: title,
                               text: text, page: page, chapter: nil)
            })
        }
        return (result, note)
    }

    private static func pageText(_ index: Int, document: PDFDocument, cache: inout ChatTextCache) -> String {
        let key = String(index)
        if let saved = cache.pages[key] { return saved }
        let text = document.page(at: index)?.string ?? ""
        cache.pages[key] = text
        return text
    }

    private static func textSources(snapshot: ChatBookSearchSnapshot, request: ChatSearchRequest) throws -> (sources: [ChatBookSource], note: String) {
        let content: ImportedBook
        if let captured = snapshot.content { content = captured }
        else {
            let contentURL = snapshot.sourceURL.deletingLastPathComponent().appendingPathComponent("content.json")
            guard let data = try? Data(contentsOf: contentURL), let loaded = try? JSONDecoder().decode(ImportedBook.self, from: data) else {
                throw ChatBookSearchError.unreadableSource
            }
            content = loaded
        }
        guard !content.chapters.isEmpty else { throw ChatBookSearchError.unreadableSource }
        let current = min(max(0, snapshot.book.chapter), content.chapters.count - 1)
        let indexes = request.scope == "chapter" ? current...current : 0...current
        var sources: [ChatBookSource] = []
        var currentPrefixAvailable = true
        for index in indexes {
            try Task.checkCancellation()
            let chapter = content.chapters[index]
            var text = chapter.text
            if request.scope == "book", index == current {
                // A reflowable chapter has no fixed page. Anchor the end to an actual
                // visible excerpt rather than guessing from a scroll percentage.
                if let end = visibleEnd(snapshot.visibleText, in: text) {
                    text = (text as NSString).substring(to: end)
                } else { text = ""; currentPrefixAvailable = false }
            }
            sources.append(contentsOf: try chunks(text).enumerated().map { offset, text in
                ChatBookSource(id: "c\(index + 1)-b\(offset + 1)", location: "Глава \(index + 1) · \(chapter.title)",
                               title: chapter.title, text: text, page: nil, chapter: index)
            })
        }
        let note: String
        if request.scope == "chapter" {
            note = "Вся текущая глава «\(content.chapters[current].title)», включая текст после текущего места."
        } else {
            note = "Поиск в предыдущих главах и в текущей главе до конца текста, видимого при отправке вопроса. Последующие главы и непрочитанный конец текущей главы исключены."
                + (currentPrefixAvailable ? "" : " Текущее место не удалось сопоставить с исходным текстом, поэтому текущая глава исключена из этого поиска; предыдущие главы доступны.")
        }
        return (sources, note)
    }

    private static func visibleEnd(_ visible: String, in text: String) -> Int? {
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let range = PracticeEvidence.selectionRange(for: trimmed, in: text) { return NSMaxRange(range) }
        // DOM paragraphs can omit labels or duplicate list text. The last visible passage
        // still gives a conservative end; the first matching occurrence wins if repeated.
        let tail = String(trimmed.suffix(240))
        guard tail.count >= 24, let range = PracticeEvidence.selectionRange(for: tail, in: text) else { return nil }
        return NSMaxRange(range)
    }

    private static func outlineBoundaries(_ document: PDFDocument) -> [ChatSearchBoundary] {
        func recognized(_ title: String) -> Bool {
            title.range(of: "(?i)^\\s*(?:(?:глава|chapter)\\s+[0-9IVXLC]+\\b|[0-9]+[.)]?\\s+\\p{L}|введение\\b|предисловие\\b|заключение\\b|introduction\\b|preface\\b|foreword\\b|appendix\\b|приложение\\b)", options: .regularExpression) != nil
        }
        func nestedRecognized(_ node: PDFOutline) -> Bool {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                if recognized(child.label ?? "") || nestedRecognized(child) { return true }
            }
            return false
        }
        func walk(_ node: PDFOutline, depth: Int) -> [ChatSearchBoundary] {
            var result: [ChatSearchBoundary] = []
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let wrapper = title.range(of: "(?i)^\\s*(?:часть|part|contents|оглавление|содержание)\\b", options: .regularExpression) != nil
                let subsection = title.range(of: "^\\s*[0-9]+\\.[0-9]+", options: .regularExpression) != nil
                if !recognized(title), wrapper || nestedRecognized(child) || (depth == 0 && node.numberOfChildren == 1 && child.numberOfChildren > 0) {
                    result.append(contentsOf: walk(child, depth: depth + 1)); continue
                }
                guard !title.isEmpty, !subsection, let page = child.destination?.page else { continue }
                let number = document.index(for: page)
                guard number != NSNotFound, (0..<document.pageCount).contains(number) else { continue }
                result.append(ChatSearchBoundary(page: number, title: title))
                // Descendants of a chapter are subsections, never chapter boundaries.
            }
            return result
        }
        return document.outlineRoot.map { mergedBoundaries([], walk($0, depth: 0)) } ?? []
    }

    private static func headingBoundary(_ text: String, page: Int) -> ChatSearchBoundary? {
        let allLines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // A table of contents describes headings elsewhere; it is not a chapter start.
        let firstLines = allLines.prefix(12)
        if firstLines.contains(where: { $0.range(of: "(?i)^(?:содержание|оглавление|contents|table of contents)$", options: .regularExpression) != nil }) { return nil }
        let numberedEntries = allLines.prefix(40).filter { $0.range(of: "(?:\\.{2,}|…|\\s)[0-9]{1,4}\\s*$", options: .regularExpression) != nil }.count
        if numberedEntries >= 4 { return nil }
        let lines = firstLines.prefix(7)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count <= 180 else { continue }
            let pattern = "(?i)^(?:(?:глава|chapter)\\s+[0-9IVXLC]+(?:[. :—–-].*)?|введение|предисловие(?:\\s.*)?|заключение|introduction|preface(?:\\s.*)?|foreword(?:\\s.*)?)$"
            if line.range(of: pattern, options: .regularExpression) != nil {
                return ChatSearchBoundary(page: page, title: line)
            }
        }
        return nil
    }

    private static func headingKey(_ title: String) -> String {
        let lower = title.lowercased().replacingOccurrences(of: "ё", with: "е")
        if let range = lower.range(of: "^(?:глава|chapter)\\s+[0-9ivxlc]+\\b", options: .regularExpression) { return String(lower[range]) }
        return lower.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mergedBoundaries(_ primary: [ChatSearchBoundary], _ supplement: [ChatSearchBoundary]) -> [ChatSearchBoundary] {
        var result = primary
        var keys = Set(primary.map { headingKey($0.title) })
        var pages = Set(primary.map(\.page))
        for boundary in supplement.sorted(by: { $0.page < $1.page }) {
            if keys.contains(headingKey(boundary.title)) || pages.contains(boundary.page) { continue }
            result.append(boundary); keys.insert(headingKey(boundary.title)); pages.insert(boundary.page)
        }
        return result.sorted { $0.page < $1.page }
    }

    private static func chunks(_ text: String) throws -> [String] {
        var remaining = text[...]
        var result: [String] = []
        while !remaining.isEmpty {
            try Task.checkCancellation()
            let end = remaining.index(remaining.startIndex, offsetBy: blockCharacters, limitedBy: remaining.endIndex) ?? remaining.endIndex
            var cut = end
            if end != remaining.endIndex {
                let half = remaining.index(remaining.startIndex, offsetBy: blockCharacters / 2)
                let window = remaining[half..<end]
                if let paragraph = window.range(of: "\n\n", options: .backwards) { cut = paragraph.upperBound }
                else if let space = window.lastIndex(where: { $0.isWhitespace }) { cut = remaining.index(after: space) }
            }
            let block = remaining[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty { result.append(block) }
            remaining = remaining[cut...]
        }
        return result
    }

    private static func select(_ original: [ChatBookSource], request: ChatSearchRequest, note: String) throws -> ChatSearchResult {
        try Task.checkCancellation()
        let section = requestedSection(request)
        var candidates = original
        if let section {
            let tokens = words(section)
            candidates = candidates.filter { source in
                let title = words(source.title)
                return !tokens.isDisjoint(with: title)
            }
            if candidates.isEmpty {
                return ChatSearchResult(scope: request.scope, note: note + " Раздел «\(section)» в этой области не найден. При scope=chapter можно продолжить поиск с scope=book в прочитанной части книги.", sources: [])
            }
        }
        guard !candidates.isEmpty else {
            return ChatSearchResult(scope: request.scope, note: note + " Доступного извлекаемого текста нет; сканированные страницы без OCR не входят в поиск.", sources: [])
        }
        let lower = request.query.lowercased()
        let overview = request.mode?.lowercased() == "overview" || ["перескаж", "пересказ", "кратко", "резюм", "обзор", "итог", "summar", "overview"].contains(where: lower.contains)
        let query = words(request.query)
        var selected: [Int] = []
        var characters = 0
        if overview || query.isEmpty {
            // Round-robin across evenly spaced positions, then sort back into book order.
            // The final block is intentionally selected before inner blocks: a long
            // introduction cannot silently become a summary of just its first pages.
            for index in spread(candidates.count) {
                try Task.checkCancellation()
                if selected.count < maximumSources, characters + candidates[index].text.count <= maximumCharacters {
                    selected.append(index); characters += candidates[index].text.count
                }
            }
        } else {
            var ranked: [(Int, Double)] = []
            for (index, source) in candidates.enumerated() {
                try Task.checkCancellation()
                let text = words(source.text)
                let title = words(source.title)
                let matches = query.intersection(text).count
                let titleMatches = query.intersection(title).count
                guard matches > 0 || titleMatches > 0 else { continue }
                let score = Double(matches) * 3 + Double(titleMatches) * 2 + Double(matches) / Double(max(1, text.count))
                ranked.append((index, score))
            }
            // Equally relevant blocks are distributed, preventing a frequently repeated
            // keyword from making every returned excerpt come from the first few pages.
            let positions = spread(candidates.count)
            let tieOrder = Dictionary(uniqueKeysWithValues: positions.enumerated().map { ($0.element, $0.offset) })
            ranked.sort { abs($0.1 - $1.1) > 0.0001 ? $0.1 > $1.1 : tieOrder[$0.0, default: 0] < tieOrder[$1.0, default: 0] }
            for (index, _) in ranked {
                if selected.count < maximumSources, characters + candidates[index].text.count <= maximumCharacters {
                    selected.append(index); characters += candidates[index].text.count
                }
            }
        }
        let sources = selected.sorted().map { candidates[$0] }
        var resultNote = note
        if let section { resultNote += " Выбран раздел «\(section)»." }
        if sources.isEmpty { resultNote += " Совпадений по запросу не найдено. Попробуйте другие термины или более широкую разрешённую область." }
        else if sources.count < candidates.count {
            resultNote += overview
                ? " Для обзора переданы \(sources.count) из \(candidates.count) фрагментов, равномерно по началу, середине и концу раздела; это выборка, а не весь текст. Не утверждайте, что прочитали непереданные фрагменты."
                : " Переданы \(sources.count) наиболее подходящих фрагментов из \(candidates.count); при необходимости уточните запрос."
        } else { resultNote += " Весь текст выбранной области помещается в переданные фрагменты." }
        return ChatSearchResult(scope: request.scope, note: resultNote, sources: sources)
    }

    private static func requestedSection(_ request: ChatSearchRequest) -> String? {
        if let explicit = request.section?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty { return String(explicit.prefix(200)) }
        let lower = request.query.lowercased()
        if lower.contains("введени") { return "Введение" }
        if lower.contains("предислов") { return "Предисловие" }
        if lower.contains("introduction") { return "Introduction" }
        if lower.contains("preface") { return "Preface" }
        return nil
    }

    private static func spread(_ count: Int) -> [Int] {
        guard count > 1 else { return count == 1 ? [0] : [] }
        var result = [0, count - 1]
        var seen: Set<Int> = [0, count - 1]
        var intervals = [(0, count - 1)]
        var cursor = 0
        while cursor < intervals.count {
            let (left, right) = intervals[cursor]; cursor += 1
            let middle = (left + right) / 2
            if seen.insert(middle).inserted { result.append(middle) }
            if middle - left > 1 { intervals.append((left, middle)) }
            if right - middle > 1 { intervals.append((middle, right)) }
        }
        return result
    }

    private static func words(_ input: String) -> Set<String> {
        let normalized = input.lowercased().replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "(?<=\\p{L})[-‐]\\h*\\R\\h*(?=\\p{L})", with: "", options: .regularExpression)
        let tokens = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }
        let stop: Set<String> = ["как", "что", "это", "для", "или", "при", "его", "она", "они", "все", "всех", "этой", "этого", "текущей", "странице", "главе", "главы", "книге", "книги", "кратко", "расскажи", "перескажи", "пожалуйста", "про", "the", "and", "that", "this", "with", "from", "what", "how", "chapter", "book", "please", "summarize"]
        let suffixes = ["иями", "ями", "ами", "ого", "ему", "ому", "ыми", "ими", "ение", "ения", "ении", "ений", "ать", "ять", "ить", "ов", "ев", "ей", "ий", "ый", "ая", "яя", "ое", "ее", "ые", "ие", "ам", "ям", "ах", "ях", "ом", "ем", "ия", "ию", "ии", "ие", "ый", "ой", "а", "я", "ы", "и", "у", "ю", "е"]
        return Set(tokens.filter { !stop.contains($0) }.map { token in
            guard token.range(of: "[а-я]", options: .regularExpression) != nil else {
                return token.count > 5 && token.hasSuffix("s") ? String(token.dropLast()) : token
            }
            for suffix in suffixes where token.hasSuffix(suffix) && token.count - suffix.count >= 4 { return String(token.dropLast(suffix.count)) }
            return token
        })
    }
}

@MainActor extension ReaderStore {
    func makeChatSearchSession() async throws -> ChatBookSearchSession {
        await captureContext?()
        guard let captured = book, captured.format != "missing" else { throw ChatBookSearchError.noBook }
        let capturedContext = readingContext()
        let capturedContent = content
        let capturedVisibleText = visibleText
        let session = ChatBookSearchSession(book: captured, sourceURL: source(captured),
                                           cacheDirectory: folder(captured.id).appendingPathComponent("ChatSearch-v1", isDirectory: true),
                                           content: capturedContent, visibleText: capturedVisibleText, context: capturedContext)
        guard selectedID == captured.id else { throw ChatBookSearchError.changedBook }
        return session
    }
}
