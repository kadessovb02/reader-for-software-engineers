import AppKit
import Foundation
#if TEST_MODULE
@testable import ListReaderCore
#endif

/// Deterministic integration checks for the chat's app-owned search loop.
/// Build with all Sources except AppMain.swift. Uses synthetic material and a
/// mocked model transport; never accesses the user's library or ChatGPT account.
@main struct ChatAssistantSmoke {
    enum Failure: Error, CustomStringConvertible {
        case check(String)
        var description: String { switch self { case .check(let message): return message } }
    }

    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.check(message) }
    }

    @MainActor static func main() async {
        do {
            try await defaultPage()
            try await historyIsNotEvidence()
            try await chapterThenBook()
            try await invalidScopeStaysLocal()
            try await duplicateSearchStops()
            try await searchBudget()
            try await malformedResponse()
            try await alreadyCancelled()
            try await retrievalCancellation()
            print("PASS chat default context, chapter/book escalation, bounded search, structured responses and cancellation")
        } catch {
            fputs("FAIL \(error)\n", stderr)
            exit(1)
        }
    }

    static let context = ReadingContext(book: "Synthetic cache manual", author: "Smoke fixture",
        chapter: "Chapter 2 Cache", location: "Страница 5 из 12", overview: "Synthetic learning material.",
        visibleText: "A cache keeps previous results. Current page marker: VISIBLE_PAGE_FIVE.", selection: "")

    static func object(_ payload: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw Failure.check("Model payload is not a JSON object")
        }
        return value
    }

    @MainActor static func defaultPage() async throws {
        var calls = 0
        let answer = try await ChatAssistant.answer(context: context, history: [], question: "Объясни этот фрагмент",
            retrieve: { _ in throw Failure.check("Page-local question unnecessarily searched the library") }, perform: { instructions, payload in
                calls += 1
                let data = try object(payload)
                let book = data["book_context"] as? [String: Any]
                try require(book?["visible_page_text"] as? String == context.visibleText, "Default request lost current visible page")
                try require(data["reader_question"] as? String == "Объясни этот фрагмент", "Reader question changed")
                try require(data["search_policy"] != nil, "Model did not receive the app-owned search policy")
                try require(!instructions.isEmpty, "Missing trusted chat instructions")
                try require(!payload.contains("FUTURE_PAGE_TWELVE"), "Default request included unavailable book text")
                return #"{"action":"answer","text":"Кэш сохраняет результат, чтобы использовать его повторно."}"#
            })
        try require(calls == 1, "A page-local answer unnecessarily started another model request")
        try require(answer == "Кэш сохраняет результат, чтобы использовать его повторно.", "Protocol envelope leaked into the displayed answer")
        print("PASS current page answers directly with no library retrieval")
    }

    @MainActor static func malformedResponse() async throws {
        var calls = 0
        do {
            let answer = try await ChatAssistant.answer(context: context, history: [], question: "Что здесь важно?",
                retrieve: nil, perform: { _, _ in
                    calls += 1
                    if calls == 1 { return #"{"action":"search","scope":"../../private","query":"cache"}"# }
                    return #"{"action":"answer","text":"Важна повторная работа с уже вычисленным результатом."}"#
                })
            try require(answer == "Важна повторная работа с уже вычисленным результатом.", "Malformed protocol was shown as a reader answer")
        } catch is Failure { throw Failure.check("Malformed protocol escaped into the UI") }
        catch is CancellationError { throw Failure.check("Malformed protocol became cancellation") }
        catch { /* A clean protocol error is also acceptable. */ }
        try require((1...7).contains(calls), "Malformed protocol caused an unbounded model loop")
        print("PASS malformed actions are rejected or repaired without exposing protocol JSON")
    }

    @MainActor static func historyIsNotEvidence() async throws {
        let history = [
            ChatTurn(role: "user", text: "Мы раньше обсуждали следующую главу."),
            ChatTurn(role: "assistant", text: "FUTURE_PAGE_TWELVE: a made-up claim from a later reading position.")
        ]
        _ = try await ChatAssistant.answer(context: context, history: history, question: "А почему так?",
            retrieve: nil, perform: { instructions, payload in
                let data = try object(payload)
                let policy = data["search_policy"] as? [String: Any]
                let book = data["book_context"] as? [String: Any]
                try require((data["recent_conversation"] as? [[String: String]])?.count == 2, "Follow-up lost conversational history")
                try require(policy?["book_search_is_limited_to_captured_reading_position"] as? Bool == true,
                            "Follow-up can widen the book reading boundary")
                try require(!(book?["visible_page_text"] as? String ?? "").contains("FUTURE_PAGE_TWELVE"),
                            "Prior model claims were promoted into current source material")
                try require(instructions.contains("история") && instructions.contains("доказательств") && instructions.contains("вернулся назад"),
                            "History has no trusted instruction preventing future facts from becoming source evidence")
                return #"{"action":"answer","text":"По текущему фрагменту кэш позволяет повторно использовать результат."}"#
            })
        print("PASS follow-up history stays conversational data under the captured reading boundary")
    }

    static func source(_ id: String, page: Int, text: String) -> ChatBookSource {
        ChatBookSource(id: id, location: "Страница \(page + 1) PDF", title: "Введение",
                       text: text, page: page, chapter: nil)
    }

    @MainActor static func chapterThenBook() async throws {
        var calls = 0
        var scopes: [String] = []
        var states: [String] = []
        let introduction = "INTRODUCTION_AT_PAGE_TWO: The author studies dependable data systems and explains the tradeoffs between their designs."
        let answer = try await ChatAssistant.answer(context: context, history: [], question: "Перескажи введение",
            retrieve: { request in
                scopes.append(request.scope)
                if scopes.count == 1 {
                    try require(request.scope == "chapter", "Model bypassed the current chapter with its first book directive")
                    return ChatSearchResult(scope: "chapter", note: "Введение в текущей главе не найдено.", sources: [])
                }
                try require(request.scope == "book" && request.mode == "overview", "Insufficient chapter search did not escalate to a book overview")
                try require(request.section == "Введение", "Section title was lost during escalation")
                return ChatSearchResult(scope: "book", note: "Покрытие введения: страницы PDF 2–3. Будущие страницы не включены.", sources: [
                    source("p2-b1", page: 1, text: introduction),
                    source("p3-b1", page: 2, text: "The ending compares reliability, scalability and maintainability.")
                ])
            }, progress: { states.append($0) }, perform: { _, payload in
                calls += 1
                let data = try object(payload)
                let results = data["search_results"] as? [[String: Any]] ?? []
                let policy = data["search_policy"] as? [String: Any]
                if calls == 1 {
                    try require(results.isEmpty && policy?["first_scope"] as? String == "current_page", "Default source was not the current page")
                    return #"{"action":"search","scope":"book","query":"введение","mode":"overview","section":"Введение"}"#
                }
                if calls == 2 {
                    try require(results.count == 1 && results.first?["scope"] as? String == "chapter", "Chapter result was not supplied before escalation")
                    try require(policy?["chapter_searched"] as? Bool == true, "Chapter search was not recorded in policy")
                    return #"{"action":"search","scope":"book","query":"введение","mode":"overview","section":"Введение"}"#
                }
                try require(results.count == 2, "Book retrieval results were lost")
                let sources = results.last?["sources"] as? [[String: Any]] ?? []
                try require(sources.count == 2 && sources.first?["text"] as? String == introduction,
                            "Source excerpts were not grounded in locally retrieved text")
                try require(sources.first?["page_index"] as? Int == 1 && sources.first?["location"] as? String == "Страница 2 PDF",
                            "Sources lost their actual PDF page labels")
                try require((results.last?["payload_excerpt_note"] as? String ?? "").contains("без дополнительного сокращения"),
                            "Complete short section was incorrectly labelled as truncated")
                try require(!(payload.contains("FUTURE_PAGE_TWELVE")), "Book search added unavailable future material")
                return #"{"action":"answer","text":"Во введении автор описывает надёжность, масштабируемость и удобство сопровождения систем (Введение, страницы 2–3 PDF)."}"#
            })
        try require(scopes == ["chapter", "book"] && calls == 3, "Question did not follow page → chapter → book flow")
        try require(answer.contains("страницы 2–3 PDF") && !answer.contains("\"action\""), "Final answer lost readable source locations")
        try require(states.contains(where: { $0.contains("главе") }) && states.contains(where: { $0.contains("книге") }),
                    "Local retrieval progress was not reported")
        print("PASS first book request searches chapter, then expands to the read book and retains source labels")
    }

    @MainActor static func duplicateSearchStops() async throws {
        var calls = 0
        var retrievals = 0
        var rejected = false
        do {
            _ = try await ChatAssistant.answer(context: context, history: [], question: "Найди фрагмент про кэш",
                retrieve: { request in
                    retrievals += 1
                    return ChatSearchResult(scope: request.scope, note: "Текст про кэш не найден.", sources: [])
                }, perform: { _, _ in
                    calls += 1
                    return #"{"action":"search","scope":"chapter","query":"кэш","mode":"search"}"#
                })
        } catch { rejected = true }
        try require(rejected, "Model that never answers returned a reader-visible search envelope")
        try require(retrievals == 1 && calls <= 7, "Repeated identical searches were not bounded")
        print("PASS duplicate search requests cannot repeat local work or loop indefinitely")
    }

    @MainActor static func invalidScopeStaysLocal() async throws {
        var calls = 0
        var retrievals = 0
        let answer = try await ChatAssistant.answer(context: context, history: [], question: "Объясни термин",
            retrieve: { request in
                retrievals += 1
                try require(request.scope == "chapter", "Unexpected scope escaped into a filesystem or broader lookup")
                try require(request.mode == "search", "Unexpected mode escaped into a different operation")
                return ChatSearchResult(scope: request.scope, note: "Термин не найден.", sources: [])
            }, perform: { _, _ in
                calls += 1
                if calls == 1 {
                    return #"{"action":"search","scope":"../../Documents","query":"literal search words","mode":"shell"}"#
                }
                return #"{"action":"answer","text":"В этой области книги термин не найден."}"#
            })
        try require(calls == 2 && retrievals == 1 && answer.contains("не найден"), "Invalid model scope was not safely normalized")
        print("PASS unexpected scope and mode remain a bounded local chapter search")
    }

    @MainActor static func searchBudget() async throws {
        var calls = 0
        var retrievals = 0
        let answer = try await ChatAssistant.answer(context: context, history: [], question: "Найди нужное понятие",
            retrieve: { request in
                retrievals += 1
                let excerpts = (0..<25).map { index in
                    source("result\(retrievals)-b\(index + 1)", page: index % 5,
                           text: "Result \(retrievals), excerpt \(index). " + String(repeating: "synthetic material ", count: 72))
                }
                return ChatSearchResult(scope: request.scope, note: "Все выбранные фрагменты переданы.", sources: excerpts)
            }, perform: { _, payload in
                calls += 1
                let data = try object(payload)
                let policy = data["search_policy"] as? [String: Any]
                let results = data["search_results"] as? [[String: Any]] ?? []
                let characters = results.reduce(0) { total, result in
                    total + ((result["sources"] as? [[String: Any]]) ?? []).reduce(0) { $0 + (($1["text"] as? String)?.count ?? 0) }
                }
                try require(characters <= 96_000, "Accumulated book context exceeded the bounded payload budget")
                if calls <= 4 {
                    try require(policy?["search_available"] as? Bool == true, "Search was disabled before its fixed budget")
                    return "{\"action\":\"search\",\"scope\":\"book\",\"query\":\"уникальный запрос \(calls)\",\"mode\":\"search\"}"
                }
                try require(policy?["search_available"] as? Bool == false && policy?["remaining_searches"] as? Int == 0,
                            "Exhausted search budget was not enforced for the final answer")
                try require(results.allSatisfy { ($0["payload_excerpt_note"] as? String ?? "").contains("Часть фрагментов сокращена") },
                            "Cumulative context clipping was not disclosed to the model")
                return #"{"action":"answer","text":"В доступной части книги это понятие не найдено."}"#
            })
        try require(retrievals == 4 && calls == 5, "Search exceeded its four-lookup budget")
        try require(answer.contains("не найдено"), "Search exhaustion lost the final reader answer")
        print("PASS four distinct local searches are followed by a forced final answer")
    }

    @MainActor static func alreadyCancelled() async throws {
        var performs = 0
        var retrievals = 0
        let task = Task { @MainActor in
            try await ChatAssistant.answer(context: context, history: [], question: "Найди пример",
                retrieve: { _ in
                    retrievals += 1
                    throw Failure.check("Cancelled question started retrieval")
                }, perform: { _, _ in
                    performs += 1
                    return #"{"action":"answer","text":"Этот ответ не должен отправляться."}"#
                })
        }
        task.cancel()
        do { _ = try await task.value; throw Failure.check("Already cancelled request returned an answer") }
        catch is CancellationError { }
        try require(performs == 0 && retrievals == 0, "Already cancelled request still contacted model or search")
        print("PASS cancellation before work prevents model and search calls")
    }

    @MainActor static func retrievalCancellation() async throws {
        var calls = 0
        var retrievals = 0
        do {
            _ = try await ChatAssistant.answer(context: context, history: [], question: "Перескажи введение",
                retrieve: { _ in
                    retrievals += 1
                    throw CancellationError()
                }, perform: { _, _ in
                    calls += 1
                    return #"{"action":"search","scope":"chapter","query":"введение","mode":"overview","section":"Введение"}"#
                })
            throw Failure.check("Cancelled retrieval produced a final answer")
        } catch is CancellationError { }
        try require(calls == 1 && retrievals == 1, "Cancelled retrieval continued the model/search loop")
        print("PASS cancellation during local retrieval stops all later model calls")
    }
}
