import Foundation

struct ImportedChapter: Codable {
    var title: String
    var html: String
    var text: String
    var basePath: String?
}

struct ImportedBook: Codable {
    var title: String
    var author: String
    var chapters: [ImportedChapter]
}

/// Synchronous, UI-independent import. Call from a background task.
enum BookImporter {
    enum ImportError: LocalizedError {
        case unsupported(String), invalid(String), tooLarge, command(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): return "Формат .\(ext) пока не поддерживается."
            case .invalid(let reason): return "Не удалось прочитать книгу: \(reason)"
            case .tooLarge: return "Книга превышает допустимый размер для безопасного импорта."
            case .command(let reason): return "Ошибка импорта: \(reason)"
            }
        }
    }

    static func load(url: URL, cacheDirectory: URL) throws -> ImportedBook {
        let ext = url.pathExtension.lowercased()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        switch ext {
        case "epub": return try loadEPUB(url, cacheDirectory: cacheDirectory)
        case "fb2": return try loadFB2(url, cacheDirectory: cacheDirectory)
        case "txt", "text":
            return plainBook(try readText(url, limit: 32 * 1_024 * 1_024), title: filename(url), markdown: false)
        case "md", "markdown":
            return plainBook(try readText(url, limit: 32 * 1_024 * 1_024), title: filename(url), markdown: true)
        case "html", "htm", "xhtml":
            let source = try readText(url, limit: 16 * 1_024 * 1_024)
            let html = sanitizeHTML(source)
            let title = heading(in: source) ?? htmlTitle(source) ?? filename(url)
            return ImportedBook(title: title, author: "", chapters: [ImportedChapter(title: title, html: html, text: htmlToText(html), basePath: url.deletingLastPathComponent().path)])
        case "rtf", "rtfd", "docx", "doc", "odt":
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize, size > 64 * 1_024 * 1_024 { throw ImportError.tooLarge }
            let data = try run("/usr/bin/textutil", arguments: ["-convert", "txt", "-stdout", url.path], outputLimit: 32 * 1_024 * 1_024)
            guard let text = String(data: data, encoding: .utf8) else { throw ImportError.invalid("неизвестная кодировка текста") }
            return plainBook(text, title: filename(url), markdown: false)
        default: throw ImportError.unsupported(ext.isEmpty ? "неизвестный" : ext)
        }
    }

    private static func loadEPUB(_ url: URL, cacheDirectory: URL) throws -> ImportedBook {
        let entries = try validateZIP(url)
        let root = cacheDirectory.appendingPathComponent("epub-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try extractZIP(url, entries: entries, to: root)
            // Defense in depth: an extracted resource may never resolve through a symbolic link.
            if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                for case let item as URL in walker {
                    if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                        throw ImportError.invalid("архив содержит символическую ссылку")
                    }
                }
            }
            let containerURL = root.appendingPathComponent("META-INF/container.xml")
            let container = ContainerParser()
            try parseXML(try readData(containerURL, limit: 1_024 * 1_024), delegate: container)
            guard let packagePath = container.packagePath else { throw ImportError.invalid("не найдено описание EPUB") }
            let packageURL = try resource(packagePath, relativeTo: root, root: root)
            let package = PackageParser()
            try parseXML(try readData(packageURL, limit: 4 * 1_024 * 1_024), delegate: package)
            let packageDirectory = packageURL.deletingLastPathComponent()
            var toc: [String: String] = [:]
            if let ncx = package.manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }),
               let ncxURL = try? resource(ncx.href, relativeTo: packageDirectory, root: root),
               let data = try? readData(ncxURL, limit: 4 * 1_024 * 1_024) {
                let parser = NavigationParser()
                if (try? parseXML(data, delegate: parser)) != nil {
                    for (href, title) in parser.entries {
                        if let destination = try? resource(href, relativeTo: ncxURL.deletingLastPathComponent(), root: root) {
                            toc[destination.path] = title
                        }
                    }
                }
            }
            var chapters: [ImportedChapter] = []
            var contentBytes = 0
            guard package.spine.count <= 3_000 else { throw ImportError.tooLarge }
            for id in package.spine {
                guard let item = package.manifest[id],
                      ["application/xhtml+xml", "text/html", ""].contains(item.mediaType) else { continue }
                let chapterURL = try resource(item.href, relativeTo: packageDirectory, root: root)
                let source = try readText(chapterURL, limit: 8 * 1_024 * 1_024)
                contentBytes += source.utf8.count
                if contentBytes > 64 * 1_024 * 1_024 { throw ImportError.tooLarge }
                let html = sanitizeHTML(source)
                let text = htmlToText(html)
                // Image-only pages (covers, maps, diagrams) are still readable content.
                guard !text.isEmpty || html.range(of: "<(img|svg)\\b", options: .regularExpression) != nil else { continue }
                let title = toc[chapterURL.path] ?? heading(in: source) ?? htmlTitle(source) ?? "Раздел \(chapters.count + 1)"
                chapters.append(ImportedChapter(title: title, html: html, text: text, basePath: chapterURL.deletingLastPathComponent().path))
            }
            guard !chapters.isEmpty else { throw ImportError.invalid("в EPUB нет доступных разделов") }
            return ImportedBook(title: clean(package.title).isEmpty ? filename(url) : clean(package.title), author: clean(package.author), chapters: chapters)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private static func loadFB2(_ url: URL, cacheDirectory: URL) throws -> ImportedBook {
        let data = try readData(url, limit: 64 * 1_024 * 1_024)
        let parser = FictionBookParser()
        try parseXML(data, delegate: parser)
        let root = cacheDirectory.appendingPathComponent("fb2-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var imageNames: [String: String] = [:]
        for (index, binary) in parser.binaries.enumerated() {
            let supported = ["image/png": "png", "image/jpeg": "jpg", "image/jpg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/bmp": "bmp"]
            guard let ext = supported[binary.mime.lowercased()],
                  let bytes = Data(base64Encoded: binary.encoded, options: .ignoreUnknownCharacters), bytes.count <= 16 * 1_024 * 1_024 else { continue }
            let name = "image-\(index).\(ext)"
            try bytes.write(to: root.appendingPathComponent(name), options: .atomic)
            imageNames[binary.id] = name
        }
        var chapters: [ImportedChapter] = []
        func appendSection(_ section: FB2Section) {
            var buffer = ""
            func flush() {
                guard !buffer.isEmpty else { return }
                var html = buffer
                for (id, name) in imageNames { html = html.replacingOccurrences(of: "fb2-image:" + escape(id), with: name) }
                let text = htmlToText(html)
                let title = clean(section.title).isEmpty ? "Раздел \(chapters.count + 1)" : clean(section.title)
                if !text.isEmpty && (text != title || !section.hasChildren) || html.contains("<img ") {
                    chapters.append(ImportedChapter(title: title, html: html, text: text, basePath: root.path))
                }
                buffer = ""
            }
            for part in section.parts {
                switch part {
                case .html(let fragment): buffer += fragment
                case .section(let child): flush(); appendSection(child)
                }
            }
            flush()
        }
        appendSection(parser.root)
        guard !chapters.isEmpty else { throw ImportError.invalid("в FB2 нет текста") }
        return ImportedBook(title: clean(parser.title).isEmpty ? filename(url) : clean(parser.title), author: clean(parser.authorParts.joined(separator: " ")), chapters: chapters)
    }

    private static func plainBook(_ source: String, title: String, markdown: Bool) -> ImportedBook {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var chapters: [ImportedChapter] = []
        var currentTitle = title
        var buffer: [String] = []
        var characters = 0
        var fenced = false
        func flush() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let html = markdown ? markdownHTML(text) : text.components(separatedBy: "\n\n").map { "<p>" + escape($0).replacingOccurrences(of: "\n", with: "<br>") + "</p>" }.joined(separator: "\n")
                chapters.append(ImportedChapter(title: currentTitle, html: html, text: markdown ? htmlToText(html) : text, basePath: nil))
            }
            buffer = []; characters = 0
        }
        for line in lines {
            if markdown && line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHeading = !fenced && (markdown ? trimmed.range(of: "^#{1,2}\\s+\\S", options: .regularExpression) != nil : trimmed.range(of: "(?i)^(глава|часть|chapter|part)\\s+[\\p{L}\\p{N}IVXLC]+(?:[.:\\s].*)?$", options: .regularExpression) != nil && trimmed.count < 140)
            if isHeading {
                flush()
                currentTitle = markdown ? trimmed.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression) : trimmed
            }
            if characters > 45_000 && trimmed.isEmpty && !fenced {
                flush()
                currentTitle = "\(currentTitle) · продолжение"
            }
            buffer.append(line); characters += line.count + 1
        }
        flush()
        if chapters.isEmpty { chapters = [ImportedChapter(title: title, html: "<p></p>", text: "", basePath: nil)] }
        return ImportedBook(title: title, author: "", chapters: chapters)
    }

    // A deliberately small Markdown renderer: readable headings, lists and code; raw HTML stays inert.
    private static func markdownHTML(_ text: String) -> String {
        var output = "", paragraph: [String] = [], code: [String] = [], inCode = false
        func inline(_ value: String) -> String {
            var result = escape(value)
            result = replacing(result, pattern: "`([^`]+)`", template: "<code>$1</code>")
            result = replacing(result, pattern: "\\*\\*([^*]+)\\*\\*", template: "<strong>$1</strong>")
            result = replacing(result, pattern: "\\*([^*]+)\\*", template: "<em>$1</em>")
            return result
        }
        func flush() { if !paragraph.isEmpty { output += "<p>" + inline(paragraph.joined(separator: " ")) + "</p>\n"; paragraph = [] } }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                if inCode { output += "<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>\n"; code = [] }
                inCode.toggle(); continue
            }
            if inCode { code.append(line); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            if let range = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                flush(); let level = min(6, line[range].filter { $0 == "#" }.count)
                output += "<h\(level)>" + inline(String(line[range.upperBound...])) + "</h\(level)>\n"
            } else if line.range(of: "^\\s*[-*+]\\s+", options: .regularExpression) != nil {
                flush(); output += "<p>• " + inline(line.replacingOccurrences(of: "^\\s*[-*+]\\s+", with: "", options: .regularExpression)) + "</p>\n"
            } else if line.hasPrefix("> ") { flush(); output += "<blockquote>" + inline(String(line.dropFirst(2))) + "</blockquote>\n" }
            else { paragraph.append(line) }
        }
        flush()
        if !code.isEmpty { output += "<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>" }
        return output
    }

    static func sanitizeHTML(_ source: String) -> String {
        var html = source
        for tag in ["script", "iframe", "object", "embed", "applet", "form", "noscript", "head"] {
            html = replacing(html, pattern: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", template: "")
        }
        html = replacing(html, pattern: "(?is)<(?:script|iframe|object|embed|applet|input|button|textarea|select|meta|link|base)\\b[^>]*?/?>", template: "")
        html = replacing(html, pattern: "(?is)<!DOCTYPE[^>]*(?:\\[[\\s\\S]*?\\]\\s*)?>|<\\?xml[^>]*\\?>|<!--.*?-->", template: "")
        html = replacing(html, pattern: "(?is)</?(?:html|body)\\b[^>]*>", template: "")
        // Preserve inline SVG diagram styling, while removing the book's page/paragraph styling.
        html = replacing(html, pattern: "(?is)<style\\b[^>]*>.*?</style\\s*>", template: "")
        html = replacing(html, pattern: "(?is)\\s+on[a-z0-9_-]+\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)", template: "")
        if let tags = try? NSRegularExpression(pattern: "(?is)<(?:p|div|section|article|span|h[1-6]|table|td|tr|font)\\b[^>]*>") {
            for match in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
                guard let range = Range(match.range, in: html) else { continue }
                let tag = String(html[range])
                html.replaceSubrange(range, with: replacing(tag, pattern: "(?is)\\s+(?:style|bgcolor|color|face|size)\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)", template: ""))
            }
        }
        html = replacing(html, pattern: "(?is)\\s+(?:href|src|xlink:href)\\s*=\\s*(?:\"\\s*(?:javascript|vbscript|file):[^\"]*\"|'\\s*(?:javascript|vbscript|file):[^']*'|(?:javascript|vbscript|file):[^\\s>]+)", template: "")
        return html.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func htmlToText(_ html: String) -> String {
        var text = replacing(html, pattern: "(?is)<(?:script|style)\\b[^>]*>.*?</(?:script|style)\\s*>", template: "")
        text = replacing(text, pattern: "(?is)<br\\s*/?>|</(?:p|div|section|article|h[1-6]|li|tr|blockquote|pre)\\s*>", template: "\n")
        text = replacing(text, pattern: "(?s)<[^>]+>", template: "")
        text = decodeEntities(text).replacingOccurrences(of: "\u{00A0}", with: " ")
        text = replacing(text, pattern: "[\\t ]+", template: " ")
        text = replacing(text, pattern: " *\\n *", template: "\n")
        return replacing(text, pattern: "\\n{3,}", template: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func heading(in html: String) -> String? {
        capture(html, pattern: "(?is)<h[1-3]\\b[^>]*>(.*?)</h[1-3]\\s*>").map(htmlToText).flatMap { $0.isEmpty ? nil : $0 }
    }
    private static func htmlTitle(_ html: String) -> String? {
        capture(html, pattern: "(?is)<title\\b[^>]*>(.*?)</title\\s*>").map(htmlToText).flatMap { $0.isEmpty ? nil : $0 }
    }
    private static func capture(_ value: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern), let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
    fileprivate static func clean(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    fileprivate static func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
    private static func filename(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }
    private static func replacing(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
    private static func decodeEntities(_ source: String) -> String {
        let named: [String: String] = ["amp":"&", "lt":"<", "gt":">", "quot":"\"", "apos":"'", "nbsp":" ", "ndash":"–", "mdash":"—", "hellip":"…", "laquo":"«", "raquo":"»", "lsquo":"‘", "rsquo":"’", "ldquo":"“", "rdquo":"”", "bull":"•", "middot":"·", "copy":"©", "reg":"®", "trade":"™", "times":"×", "divide":"÷", "minus":"−", "le":"≤", "ge":"≥", "ne":"≠", "rarr":"→", "larr":"←", "harr":"↔", "thinsp":" ", "ensp":" ", "emsp":" ", "shy":"", "eacute":"é", "ouml":"ö", "uuml":"ü", "auml":"ä", "szlig":"ß"]
        guard let regex = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]+);") else { return source }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: source), let fullRange = Range(match.range, in: result) else { continue }
            let token = String(source[tokenRange]); var decoded = named[token]
            if token.hasPrefix("#x"), let number = UInt32(token.dropFirst(2), radix: 16), let scalar = UnicodeScalar(number) { decoded = String(scalar) }
            else if token.hasPrefix("#"), let number = UInt32(token.dropFirst()), let scalar = UnicodeScalar(number) { decoded = String(scalar) }
            if let decoded { result.replaceSubrange(fullRange, with: decoded) }
        }
        return result
    }
    private static func readData(_ url: URL, limit: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw ImportError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= limit else { throw ImportError.tooLarge }
        return data
    }
    private static func readText(_ url: URL, limit: Int) throws -> String {
        let data = try readData(url, limit: limit)
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]), let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .utf8) { return text.replacingOccurrences(of: "\u{FEFF}", with: "") }
        if let declared = String(data: data.prefix(300), encoding: .ascii), declared.localizedCaseInsensitiveContains("windows-1251"), let text = String(data: data, encoding: .windowsCP1251) { return text }
        for encoding in [String.Encoding.windowsCP1251, .windowsCP1252, .isoLatin1] { if let text = String(data: data, encoding: encoding) { return text } }
        throw ImportError.invalid("неизвестная кодировка текста")
    }
    private static func resource(_ href: String, relativeTo directory: URL, root: URL) throws -> URL {
        let path = href.components(separatedBy: "#")[0].components(separatedBy: "?")[0].removingPercentEncoding ?? href
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0") else { throw ImportError.invalid("недопустимый путь ресурса") }
        let result = directory.appendingPathComponent(path).standardizedFileURL
        guard result.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw ImportError.invalid("ресурс находится за пределами книги") }
        return result
    }
    private static func parseXML(_ data: Data, delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: data)
        parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse() else { throw ImportError.invalid(parser.parserError?.localizedDescription ?? "повреждён XML") }
    }
    private static func run(_ executable: String, arguments: [String], outputLimit: Int) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        var output = Data()
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                output.append(chunk)
                if output.count > outputLimit { process.terminate(); throw ImportError.tooLarge }
            }
        } catch { if process.isRunning { process.terminate() }; process.waitUntilExit(); throw error }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: output.prefix(1_000), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "код \(process.terminationStatus)"
            throw ImportError.command(message)
        }
        return output
    }

    /// Inspect the ZIP central directory before invoking the system decompressor.
    /// This prevents path traversal, symlink extraction and disproportionate archive expansion.
    private struct ZIPEntry { var name: String; var size: Int }

    private static func validateZIP(_ url: URL) throws -> [ZIPEntry] {
        let data = try readData(url, limit: 256 * 1_024 * 1_024)
        func u16(_ offset: Int) throws -> UInt16 {
            guard offset >= 0, offset + 2 <= data.count else { throw ImportError.invalid("повреждён ZIP") }
            return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> UInt32 { UInt32(try u16(offset)) | UInt32(try u16(offset + 2)) << 16 }
        guard data.count >= 22 else { throw ImportError.invalid("повреждён ZIP") }
        var end: Int?
        for position in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try u32(position) == 0x06054b50, position + 22 + Int(try u16(position + 20)) == data.count { end = position; break }
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0 else { throw ImportError.invalid("многотомные ZIP не поддерживаются") }
        let count = Int(try u16(end + 10)), centralSize = Int(try u32(end + 12)), centralStart = Int(try u32(end + 16))
        guard count > 0, count < 8_000, count != 65_535, try u16(end + 8) == count,
              centralStart + centralSize <= end else { throw ImportError.invalid("недопустимая структура ZIP") }
        var cursor = centralStart, expanded: UInt64 = 0, names = Set<String>(), entries: [ZIPEntry] = []
        for _ in 0..<count {
            guard try u32(cursor) == 0x02014b50 else { throw ImportError.invalid("повреждён каталог ZIP") }
            let flags = try u16(cursor + 8), compression = try u16(cursor + 10)
            let size = try u32(cursor + 24), nameLength = Int(try u16(cursor + 28)), extraLength = Int(try u16(cursor + 30)), commentLength = Int(try u16(cursor + 32))
            let attributes = try u32(cursor + 38), local = Int(try u32(cursor + 42))
            let nameStart = cursor + 46, next = nameStart + nameLength + extraLength + commentLength
            guard next <= centralStart + centralSize, nameLength > 0, size != UInt32.max,
                  flags & 0x41 == 0, [0, 8].contains(compression), [0, 0x4000, 0x8000].contains((attributes >> 16) & 0xF000),
                  let name = String(data: data[nameStart..<(nameStart + nameLength)], encoding: .utf8) else { throw ImportError.invalid("небезопасный или неподдерживаемый ZIP") }
            // Info-ZIP may prefer the Unicode Path extra field over the central name.
            // Accept it only when it describes exactly the filename already inspected.
            var extraCursor = nameStart + nameLength
            let extraEnd = extraCursor + extraLength
            while extraCursor + 4 <= extraEnd {
                let kind = try u16(extraCursor), length = Int(try u16(extraCursor + 2))
                let payload = extraCursor + 4
                guard payload + length <= extraEnd else { throw ImportError.invalid("повреждён ZIP extra field") }
                if kind == 0x7075 {
                    guard length >= 5, data[payload] == 1,
                          let unicodeName = String(data: data[(payload + 5)..<(payload + length)], encoding: .utf8), unicodeName == name else {
                        throw ImportError.invalid("несовпадающее Unicode-имя файла ZIP")
                    }
                }
                extraCursor = payload + length
            }
            guard extraCursor == extraEnd else { throw ImportError.invalid("повреждён ZIP extra field") }
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !parts.contains(where: { $0 == ".." || $0 == "." }), !name.contains("//") else { throw ImportError.invalid("небезопасное имя файла в ZIP") }
            let canonical = name.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard names.insert(canonical).inserted else { throw ImportError.invalid("повторяющиеся пути в ZIP") }
            guard try u32(local) == 0x04034b50 else { throw ImportError.invalid("повреждён заголовок ZIP") }
            let localNameLength = Int(try u16(local + 26)), localExtraLength = Int(try u16(local + 28))
            guard local + 30 + localNameLength + localExtraLength <= centralStart,
                  try u16(local + 6) == flags, try u16(local + 8) == compression,
                  localNameLength == nameLength,
                  data[(local + 30)..<(local + 30 + localNameLength)] == data[nameStart..<(nameStart + nameLength)] else { throw ImportError.invalid("несовпадающие имена файлов ZIP") }
            expanded += UInt64(size)
            guard size <= 128 * 1_024 * 1_024, expanded <= 512 * 1_024 * 1_024 else { throw ImportError.tooLarge }
            entries.append(ZIPEntry(name: name, size: Int(size)))
            cursor = next
        }
        guard cursor == centralStart + centralSize else { throw ImportError.invalid("повреждён каталог ZIP") }
        return entries
    }

    /// `unzip -p` emits members in central-directory order. Only this importer writes paths,
    /// and each stream is limited to its inspected size, even if ZIP metadata is dishonest.
    private static func extractZIP(_ archive: URL, entries: [ZIPEntry], to root: URL) throws {
        let files = entries.filter { !$0.name.hasSuffix("/") }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", "-qq", archive.path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        var index = 0, written = 0
        var handle: FileHandle?
        func advance() throws {
            try handle?.close(); handle = nil
            while index < files.count {
                let target = root.appendingPathComponent(files[index].name)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw ImportError.invalid("не удалось создать файл EPUB") }
                if files[index].size == 0 { index += 1; continue }
                handle = try FileHandle(forWritingTo: target); written = 0; break
            }
        }
        try advance()
        try process.run()
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                var offset = 0
                while offset < chunk.count {
                    guard index < files.count, let output = handle else { throw ImportError.invalid("размер ZIP не совпадает с каталогом") }
                    let amount = min(chunk.count - offset, files[index].size - written)
                    try output.write(contentsOf: chunk.subdata(in: offset..<(offset + amount)))
                    written += amount; offset += amount
                    if written == files[index].size { index += 1; try advance() }
                }
            }
            try handle?.close(); handle = nil
            process.waitUntilExit()
            guard process.terminationStatus == 0, index == files.count else { throw ImportError.invalid("повреждённый или неполный архив EPUB") }
        } catch {
            try? handle?.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
    }
}

private func localName(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

private final class ContainerParser: NSObject, XMLParserDelegate {
    var packagePath: String?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if localName(name) == "rootfile", packagePath == nil { packagePath = attributes["full-path"] }
    }
}
private struct ManifestItem { var href: String; var mediaType: String }
private final class PackageParser: NSObject, XMLParserDelegate {
    var title = "", author = "", manifest: [String: ManifestItem] = [:], spine: [String] = []
    private var capture: String?, depth = 0, metadataDepth = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        switch localName(name) {
        case "metadata": metadataDepth = depth
        case "title" where metadataDepth > 0: if title.isEmpty { capture = "title" }
        case "creator" where metadataDepth > 0: if author.isEmpty { capture = "author" }
        case "item": if let id = attributes["id"], let href = attributes["href"] { manifest[id] = ManifestItem(href: href, mediaType: attributes["media-type"] ?? "") }
        case "itemref": if attributes["linear"] != "no", let id = attributes["idref"] { spine.append(id) }
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if capture == "title" { title += string }; if capture == "author" { author += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if ["title", "creator"].contains(localName(name)) { capture = nil }
        if depth == metadataDepth { metadataDepth = 0 }
        depth -= 1
    }
}
private final class NavigationParser: NSObject, XMLParserDelegate {
    var entries: [(String, String)] = []
    private struct Point { var label = ""; var source = "" }
    private var points: [Point] = [], readingText = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch localName(name) {
        case "navPoint": points.append(Point())
        case "text": readingText = true
        case "content": if !points.isEmpty { points[points.count - 1].source = attributes["src"] ?? "" }
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if readingText && !points.isEmpty { points[points.count - 1].label += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if localName(name) == "text" { readingText = false }
        if localName(name) == "navPoint", let point = points.popLast(), !point.source.isEmpty { entries.append((point.source, BookImporter.clean(point.label))) }
    }
}
private final class FB2Section {
    enum Part { case html(String), section(FB2Section) }
    var title = "", parts: [Part] = []
    var hasChildren: Bool { parts.contains { if case .section = $0 { return true }; return false } }
    func append(_ html: String) {
        if let last = parts.last, case .html(let value) = last { parts[parts.count - 1] = .html(value + html) }
        else { parts.append(.html(html)) }
    }
}
private final class FictionBookParser: NSObject, XMLParserDelegate {
    struct Binary { var id: String; var mime: String; var encoded: String }
    var title = "", authorParts: [String] = [], binaries: [Binary] = [], root = FB2Section()
    private var sections: [FB2Section] = [], bodyDepth = 0, titleDepth = 0, authorDepth = 0, bookTitleDepth = 0, depth = 0
    private var producedBytes = 0, sectionCount = 0
    private var authorComponent = "", readingAuthor = false, currentBinary: Binary?, closing: [String?] = []
    private var current: FB2Section { sections.last ?? root }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1; closing.append(nil)
        let tag = localName(name)
        if tag == "binary" { currentBinary = Binary(id: attributes["id"] ?? "", mime: attributes["content-type"] ?? "", encoded: ""); return }
        if tag == "body" { bodyDepth = depth; return }
        if bodyDepth == 0 {
            if tag == "book-title" { bookTitleDepth = depth }
            if tag == "author" && authorParts.isEmpty { authorDepth = depth }
            if authorDepth > 0 && ["first-name", "middle-name", "last-name", "nickname"].contains(tag) { readingAuthor = true; authorComponent = "" }
            return
        }
        if tag == "section" {
            sectionCount += 1
            guard sectionCount <= 3_000 else { parser.abortParsing(); return }
            let section = FB2Section(); current.parts.append(.section(section)); sections.append(section); return
        }
        if tag == "title" { titleDepth = depth; current.append("<h2>"); closing[closing.count - 1] = "</h2>"; return }
        if tag == "image" {
            if let href = attributes.first(where: { localName($0.key) == "href" })?.value {
                current.append("<img src=\"fb2-image:" + BookImporter.escape(href.hasPrefix("#") ? String(href.dropFirst()) : href) + "\" alt=\"\">")
            }
            return
        }
        if tag == "empty-line" { current.append("<br>"); return }
        var mapped: String?
        switch tag {
        case "p", "v": mapped = titleDepth > 0 ? nil : "p"
        case "subtitle": mapped = "h3"
        case "strong": mapped = "strong"
        case "emphasis": mapped = "em"
        case "strikethrough": mapped = "s"
        case "sup", "sub", "code", "table", "tr", "th", "td": mapped = tag
        case "cite", "epigraph": mapped = "blockquote"
        case "poem", "stanza": mapped = "div"
        default: break
        }
        if let mapped { current.append("<" + mapped + ">"); closing[closing.count - 1] = "</" + mapped + ">" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        producedBytes += string.utf8.count
        guard producedBytes <= 96 * 1_024 * 1_024 else { parser.abortParsing(); return }
        if currentBinary != nil { currentBinary!.encoded += string; return }
        if bookTitleDepth > 0 { title += string }
        if readingAuthor { authorComponent += string }
        if bodyDepth > 0 {
            current.append(BookImporter.escape(string))
            if titleDepth > 0 { current.title += string }
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let tag = localName(name)
        if let close = closing.popLast() ?? nil, bodyDepth > 0 { current.append(close) }
        if tag == "section", bodyDepth > 0, !sections.isEmpty { sections.removeLast() }
        if tag == "binary", let binary = currentBinary { binaries.append(binary); currentBinary = nil }
        if titleDepth == depth { titleDepth = 0 }
        if bodyDepth == depth { bodyDepth = 0 }
        if bookTitleDepth == depth { bookTitleDepth = 0 }
        if readingAuthor && ["first-name", "middle-name", "last-name", "nickname"].contains(tag) {
            let component = BookImporter.clean(authorComponent); if !component.isEmpty { authorParts.append(component) }; readingAuthor = false
        }
        if authorDepth == depth { authorDepth = 0 }
        depth -= 1
    }
}
