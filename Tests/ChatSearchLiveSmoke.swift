import AppKit
import Foundation
#if TEST_MODULE
@testable import ListReaderCore
#endif

/// Live CLI request using only a tiny synthetic book in a disposable library.
@main struct ChatSearchLiveSmoke {
    enum Failure: Error { case check(String) }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await run()
                print("PASS live chat searches chapter then earlier introduction and answers from synthetic sources")
                exit(0)
            } catch {
                fputs("FAIL \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ListChatLive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let introductionTitle = CommandLine.arguments.contains("--preface") ? "Предисловие" : "Введение"
        let introduction = """
        \(introductionTitle)
        Эта учебная книга описывает вымышленный проект «Сапфир»: обработку показаний датчиков в библиотечных хранилищах. Цель проекта — замечать опасные для бумажных книг изменения влажности и быстро предупреждать хранителя.

        Первое выбранное ограничение — задержка обработки одного показания не более 7 миллисекунд. Это условие измеряется от поступления показания до проверки порога влажности. Мы сознательно используем простую проверку вместо тяжёлого аналитического запроса.

        Второе выбранное ограничение — исходные показания хранятся только 24 часа. Затем остаются лишь сводные значения. Так мы ограничиваем объём хранилища, сохраняя достаточно данных для расследования недавних сбоев.

        Введение заканчивается напоминанием: оба ограничения — осознанные решения именно проекта «Сапфир», а не универсальные правила для всех систем. Дальше читатель изучит способы сохранить эти свойства при изменении нагрузки.
        """
        let current = "Глава 1. Кэширование\n\nКэш сохраняет ранее вычисленные результаты и позволяет использовать их повторно. В этой главе рассматривается только устройство кэша."
        let book = ImportedBook(title: "Синтетический проект Сапфир", author: "Тест приложения", chapters: [
            ImportedChapter(title: introductionTitle, html: "", text: introduction, basePath: nil),
            ImportedChapter(title: "Глава 1. Кэширование", html: "", text: current, basePath: nil),
            ImportedChapter(title: "Глава 2. Будущее", html: "", text: "НЕОЖИДАННЫЙ_БУДУЩИЙ_СЕКРЕТ: позже все ограничения отменены и время хранения увеличено до 999 лет.", basePath: nil)
        ])
        let store = ReaderStore(root: root)
        store.books = [BookRecord(id: "synthetic", title: book.title, author: book.author, format: "guide", chapter: 1, progress: 0.5)]
        store.selectedID = "synthetic"; store.content = book; store.visibleText = current; store.currentHeading = "Кэширование"
        try FileManager.default.createDirectory(at: store.folder("synthetic"), withIntermediateDirectories: true)
        try JSONEncoder().encode(book).write(to: store.folder("synthetic").appendingPathComponent("content.json"))
        let search = try await store.makeChatSearchSession()
        let service = CodexService()
        await service.refreshStatus()
        guard service.isConnected else { throw Failure.check("ChatGPT is not connected") }
        var phases: [String] = []
        let report: (String) -> Void = { phase in
                if phases.last != phase { print("STATUS \(phase)"); fflush(stdout) }
                phases.append(phase)
        }
        let question = "Кратко перескажи всё введение этой книги: цель проекта и два выбранных ограничения. Опирайся именно на текст введения."
        let answer: String
        if CommandLine.arguments.contains("--trace") {
            answer = try await ChatAssistant.answer(context: search.context, history: [], question: question,
                retrieve: { try await search.retrieve($0) }, progress: report,
                perform: { instructions, payload in
                    let raw = try await service.performPractice(instructions: instructions, payload: payload)
                    print("SYNTHETIC_TRACE \(raw)"); fflush(stdout)
                    return raw
                })
        } else {
            answer = try await service.ask(context: search.context, history: [], question: question, search: search, progress: report)
        }
        guard phases.contains("Ищу в текущей главе…"), phases.contains("Ищу в книге до текущего места…") else {
            throw Failure.check("Expected adaptive chapter then book search")
        }
        guard answer.contains("7"), answer.contains("24"), answer.localizedCaseInsensitiveContains("сапфир"),
              !answer.contains("999"), !answer.contains("НЕОЖИДАННЫЙ_БУДУЩИЙ"),
              !answer.contains("доступна только текущая страница") else { throw Failure.check("Answer lost introduction facts or exposed a future source") }
        if introductionTitle == "Предисловие", !answer.localizedCaseInsensitiveContains("предислов") {
            throw Failure.check("Answer did not identify the actual preface title")
        }
        print("ANSWER \(answer)")
        guard !service.isBusy else { throw Failure.check("Chat operation left service busy") }
    }
}
