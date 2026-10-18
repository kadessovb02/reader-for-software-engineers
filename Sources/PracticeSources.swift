import Foundation
import PDFKit

enum PracticeSourceError: LocalizedError {
    case noBook, noText, changedBook, unreadablePDF
    var errorDescription: String? {
        switch self {
        case .noBook: return "Сначала откройте книгу."
        case .noText: return "В этом фрагменте нет извлекаемого текста. Откройте текстовую страницу: для сканов пока нужен OCR."
        case .changedBook: return "Книга изменилась, пока готовился материал. Откройте практику ещё раз."
        case .unreadablePDF: return "Не удалось прочитать PDF для практики. Попробуйте открыть книгу заново."
        }
    }
}

/// Only citations backed by the provided book text can reach the interface.
enum PracticeEvidence {
    /// Keeps UTF-16 positions while normalizing line breaks, so a verified quote
    /// can highlight the original PDF page without searching the entire book.
    static func selectionRange(for quote: String, in raw: String) -> NSRange? {
        let chars = Array(raw)
        var offsets = [Int](); var offset = 0
        for character in chars { offsets.append(offset); offset += String(character).utf16.count }
        offsets.append(offset)
        var result = ""; var positions: [(Int, Int)] = []; var i = 0
        while i < chars.count {
            let character = chars[i]
            if character == "\u{00AD}" { i += 1; continue }
            if (character == "-" || character == "‐"), i > 0, chars[i - 1].isLetter {
                var j = i + 1; var newline = false
                while j < chars.count && chars[j].isWhitespace { newline = newline || chars[j].isNewline; j += 1 }
                if newline, j < chars.count, chars[j].isLetter { i = j; continue }
            }
            let piece = character.isWhitespace ? " " : String(character).precomposedStringWithCanonicalMapping
            if piece == " ", result.last == " " { i += 1; continue }
            result += piece
            for _ in piece.utf16 { positions.append((offsets[i], offsets[i + 1])) }
            i += 1
        }
        let needle = normalized(quote)
        guard !needle.isEmpty else { return nil }
        let range = (result as NSString).range(of: needle, options: [.caseInsensitive])
        guard range.location != NSNotFound, range.length > 0, range.location + range.length <= positions.count else { return nil }
        let start = positions[range.location].0, end = positions[range.location + range.length - 1].1
        return NSRange(location: start, length: end - start)
    }

    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "(?<=\\p{L})[-‐]\\h*\\R\\h*(?=\\p{L})", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validated(_ citations: [PracticeCitation], in material: PracticeMaterial) -> [PracticeCitation] {
        var seen = Set<String>()
        return citations.prefix(8).compactMap { citation in
            let quote = normalized(citation.quote)
            guard citation.quote.count <= 600, (12...600).contains(quote.count),
                  let source = material.sources.first(where: { $0.id == citation.sourceID }) else { return nil }
            let original = normalized(source.text)
            guard let match = original.range(of: quote), seen.insert(citation.sourceID + ":" + quote).inserted else { return nil }
            return PracticeCitation(sourceID: source.id, quote: String(original[match]))
        }
    }
}

enum PracticeSourceBuilder {
    static let maximumSources = 24
    static let maximumCharacters = 30_000
    static let blockCharacters = 1_200

    /// Splits only at character boundaries; every resulting block is a literal excerpt.
    static func blocks(_ text: String) -> [String] {
        var rest = text[...]
        var result: [String] = []
        // One extra block records that clipping happened without allocating an entire
        // unusually large chapter in a second array.
        while !rest.isEmpty && result.count <= maximumSources {
            let end = rest.index(rest.startIndex, offsetBy: blockCharacters, limitedBy: rest.endIndex) ?? rest.endIndex
            var cut = end
            if end != rest.endIndex {
                let window = rest[rest.index(rest.startIndex, offsetBy: blockCharacters / 2)..<end]
                if let paragraph = window.range(of: "\n\n", options: .backwards) { cut = paragraph.upperBound }
                else if let whitespace = window.lastIndex(where: { $0.isWhitespace }) { cut = rest.index(after: whitespace) }
            }
            let block = rest[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty { result.append(block) }
            rest = rest[cut...]
        }
        return result
    }

    static func bounded(_ sources: [PracticeSource], note: String) -> (sources: [PracticeSource], note: String) {
        var kept: [PracticeSource] = []
        var characters = 0
        for source in sources {
            guard kept.count < maximumSources, characters + source.text.count <= maximumCharacters else { break }
            kept.append(source); characters += source.text.count
        }
        var resultNote = note
        if kept.count < sources.count {
            resultNote += " Для этого упражнения переданы первые \(kept.count) фрагмента раздела; остальной текст в материал не вошёл."
        }
        return (kept, resultNote)
    }

    static func textMaterial(book: BookRecord, chapter: ImportedChapter, scope: PracticeScope, visibleText: String, selection: String) throws -> PracticeMaterial {
        let isSelection = scope == .page && !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let text = scope == .chapter ? chapter.text : (isSelection ? selection : visibleText)
        let chunks = blocks(text)
        guard !chunks.isEmpty else { throw PracticeSourceError.noText }
        // A viewport is not a real page in a reflowable book. Its fingerprint also prevents
        // unrelated places within a chapter from sharing a saved practice notebook.
        let prefix = "c\(book.chapter + 1)" + (scope == .chapter ? "" : "-v\(fingerprint(text))")
        let location = "Глава \(book.chapter + 1)" + (scope == .chapter ? "" : (isSelection ? " · выделение" : " · текущее место"))
        let sources = chunks.enumerated().map { offset, text in
            PracticeSource(id: "\(prefix)-b\(offset + 1)", location: location, title: chapter.title, text: text, page: nil, chapter: book.chapter)
        }
        let note = scope == .chapter ? "Материал из текущей главы книги." : (isSelection ? "Материал только из выделенного фрагмента." : "Материал из текста, видимого в читалке; у этого формата нет фиксированных страниц.")
        let bounded = bounded(sources, note: note)
        return PracticeMaterial(bookID: book.id, bookTitle: book.title, author: book.author, unitTitle: chapter.title, scope: scope, scopeNote: bounded.note, sources: bounded.sources)
    }

    static func fingerprint(_ text: String) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { value ^= UInt64(byte); value = value &* 1_099_511_628_211 }
        return String(value, radix: 16)
    }

    private struct ChapterBoundary { var page: Int; var title: String }

    private static func chapterBoundaries(_ document: PDFDocument) -> [ChapterBoundary] {
        func walk(_ outline: PDFOutline?) -> [ChapterBoundary] {
            guard let outline else { return [] }
            var result: [ChapterBoundary] = []
            for index in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: index) else { continue }
                let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let pattern = "(?i)^\\s*(?:(?:глава|chapter)\\s+[0-9IVXLC]+(?:\\b|[.:])|[0-9]+[.)]?\\s+\\p{L})"
                if title.range(of: pattern, options: .regularExpression) != nil, let page = child.destination?.page {
                    let number = document.index(for: page)
                    if number != NSNotFound, number < document.pageCount { result.append(ChapterBoundary(page: number, title: title)) }
                    // A recognized chapter's descendants are sections, not chapter boundaries.
                } else { result.append(contentsOf: walk(child)) }
            }
            return result
        }
        return walk(document.outlineRoot).sorted { $0.page < $1.page }
    }

    /// Opens a separate PDFDocument in the worker, never the actively rendered PDF object.
    static func pdfMaterial(url: URL, book: BookRecord, scope: PracticeScope) throws -> PracticeMaterial {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw PracticeSourceError.unreadablePDF }
        let current = min(max(0, book.page), document.pageCount - 1)
        var pageRange = current..<(current + 1)
        var actualScope = PracticeScope.page
        var unitTitle = "Страница \(current + 1)"
        var note = "Материал из страницы \(current + 1) PDF. Номер PDF может отличаться от печатного номера."
        if scope == .chapter {
            if book.isSample, current >= 3, document.pageCount <= 20 {
                pageRange = 3..<document.pageCount
                actualScope = .chapter
                unitTitle = "Глава 1 · Ознакомительный фрагмент"
                note = "Доступная часть главы 1: страницы PDF 4–\(document.pageCount). Это ознакомительный фрагмент, а не полная глава."
            } else {
                let boundaries = chapterBoundaries(document)
                if let position = boundaries.lastIndex(where: { $0.page <= current }) {
                    let boundary = boundaries[position]
                    let next = boundaries.dropFirst(position + 1).first(where: { $0.page > boundary.page })?.page ?? document.pageCount
                    pageRange = boundary.page..<max(boundary.page + 1, next)
                    actualScope = .chapter
                    unitTitle = boundary.title
                    note = "Раздел по оглавлению PDF: страницы \(pageRange.lowerBound + 1)–\(pageRange.upperBound). Номер PDF может отличаться от печатного номера."
                } else {
                    note = "В PDF не удалось надёжно определить границы главы. Для практики используется только текущая страница \(current + 1)."
                }
            }
        }
        var sources: [PracticeSource] = []
        for index in pageRange {
            let chunks = blocks(document.page(at: index)?.string ?? "")
            sources.append(contentsOf: chunks.enumerated().map { offset, text in
                PracticeSource(id: "p\(index + 1)-b\(offset + 1)", location: "Страница \(index + 1) PDF", title: unitTitle, text: text, page: index, chapter: nil)
            })
            if sources.count > maximumSources { break }
        }
        guard !sources.isEmpty else { throw PracticeSourceError.noText }
        let bounded = bounded(sources, note: note)
        return PracticeMaterial(bookID: book.id, bookTitle: book.title, author: book.author, unitTitle: unitTitle, scope: actualScope, scopeNote: bounded.note, sources: bounded.sources)
    }

    static func searchFragment(_ text: String) -> String {
        // Searches should stay within one PDF line; phrases with reflow or hyphens can
        // otherwise fail even though the exact quotation passed evidence validation.
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let line = lines.max(by: { $0.count < $1.count }) ?? text
        let prefix = String(line.prefix(90))
        if let end = prefix.lastIndex(of: " "), prefix.count >= 40 { return String(prefix[..<end]) }
        return prefix
    }
}

@MainActor extension ReaderStore {
    func practiceMaterial(scope: PracticeScope) async throws -> PracticeMaterial {
        await captureContext?()
        guard var snapshot = book, snapshot.format != "missing" else { throw PracticeSourceError.noBook }
        if pdfDocument != nil {
            snapshot.page = focusedPDFPage?() ?? snapshot.page
            let url = source(snapshot)
            let result = try await Task.detached(priority: .userInitiated) { try PracticeSourceBuilder.pdfMaterial(url: url, book: snapshot, scope: scope) }.value
            guard selectedID == snapshot.id else { throw PracticeSourceError.changedBook }
            return result
        }
        guard let currentChapter = chapter else { throw PracticeSourceError.noText }
        let captured = readingContext()
        return try PracticeSourceBuilder.textMaterial(book: snapshot, chapter: currentChapter, scope: scope, visibleText: captured.visibleText, selection: captured.selection)
    }

    func revealPracticeSource(_ source: PracticeSource) async {
        let phrase = PracticeSourceBuilder.searchFragment(source.text)
        searchQuery = phrase
        if let page = source.page, let document = pdfDocument {
            guard (0..<document.pageCount).contains(page) else { return }
            updateBook { $0.page = page; $0.pageOffset = 0 }
            if let reveal = onRevealPracticePDF { reveal(page, phrase) }
            else {
                onScroll?(Double(page) / Double(document.pageCount))
                onSearch?(phrase, false)
            }
        } else if let index = source.chapter, content?.chapters.indices.contains(index) == true {
            if book?.chapter != index {
                pendingPracticeSearch = phrase
                goChapter(index)
            } else { onSearch?(phrase, false) }
        }
    }
}
