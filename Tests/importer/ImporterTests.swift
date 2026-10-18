import Foundation

@main struct ImporterTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.removeItem(at: cache)
        defer { try? FileManager.default.removeItem(at: cache) }
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; count += 1
        }
        func load(_ name: String) throws -> ImportedBook { try BookImporter.load(url: root.appendingPathComponent(name), cacheDirectory: cache) }
        let epub = try load("sample.epub")
        check(epub.title == "Тестовая книга", "EPUB title")
        check(epub.author == "Автор", "EPUB author")
        check(epub.chapters.count == 2, "EPUB spine count")
        check(epub.chapters[0].title == "Из оглавления", "NCX chapter title")
        check(epub.chapters[0].text.contains("A & B → C"), "HTML entities")
        check(!epub.chapters[0].html.contains("script") && !epub.chapters[0].html.contains("onload") && !epub.chapters[0].html.contains("color:red"), "HTML sanitization")
        let image = URL(fileURLWithPath: epub.chapters[0].basePath!).appendingPathComponent("../images/diagram.png").standardizedFileURL
        check(FileManager.default.fileExists(atPath: image.path), "EPUB diagram base path")
        check(epub.chapters[1].html.contains("<svg>"), "EPUB inline SVG preserved")
        let fb2 = try load("sample.fb2")
        check(fb2.title == "Книга FB2" && fb2.author == "Иван Иванов", "FB2 metadata")
        check(fb2.chapters.count == 3, "FB2 nested sections split in reading order")
        check(fb2.chapters[1].text.contains("Привет, мир!"), "FB2 inline formatting")
        check(fb2.chapters[1].html.contains("image-0.png"), "FB2 image reference")
        check(FileManager.default.fileExists(atPath: URL(fileURLWithPath: fb2.chapters[1].basePath!).appendingPathComponent("image-0.png").path), "FB2 decoded diagram")
        let md = try load("sample.md")
        check(md.chapters.count == 2, "Markdown headings split")
        check(md.chapters[0].html.contains("<pre><code>let a = 1 &lt; 2\n# This is code"), "Markdown fenced code")
        check(md.chapters[0].html.contains("<strong>жирный</strong>"), "Markdown emphasis")
        let plain = try load("sample.txt")
        check(plain.chapters.count == 2, "Plain text chapters")
        let cyrillic = try load("cp1251.txt")
        check(cyrillic.chapters[0].text == "Привет, мир.", "Windows Cyrillic encoding")
        let utf16 = try load("utf16.txt")
        check(utf16.chapters[0].text == "Привет UTF16.", "UTF16 encoding")
        for name in ["sample.rtf", "sample.docx"] {
            let rich = try load(name)
            check(rich.chapters[0].text.contains("Основной заголовок") && rich.chapters[0].text.contains("Текст"), "Native textutil conversion: " + name)
        }
        let html = try load("sample.html")
        check(html.title == "Основной заголовок", "HTML heading")
        check(!html.chapters[0].html.contains("style=") && !html.chapters[0].html.contains("color=") && !html.chapters[0].html.contains("javascript:") && !html.chapters[0].html.contains("iframe"), "HTML unsafe and visual attributes removed")
        for name in ["traversal", "absolute", "backslash", "case-duplicate", "symlink", "unicode-traversal", "forged-size"] {
            do { _ = try load(name + ".epub"); fatalError("Accepted unsafe archive \(name)") } catch { count += 1 }
        }
        let roundtrip = try JSONDecoder().decode(ImportedBook.self, from: JSONEncoder().encode(epub))
        check(roundtrip.chapters[0].basePath == epub.chapters[0].basePath, "Model Codable round trip")
        print("PASS: \(count) importer checks")
    }
}
