import AppKit
import Foundation
#if TEST_MODULE
@testable import ListReaderCore
#endif

/// Real ChatGPT/Codex request; synthetic text only, no library access.
/// Compile with CodexService, PracticeModels, PracticeCoach and PracticeSources + its model dependencies.
@main struct PracticeCoachSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await run()
                print("PASS practice coach live generation, hint and review grounded in synthetic material")
                exit(0)
            } catch {
                fputs("FAIL \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    enum Failure: Error { case check(String) }
    @MainActor static func require(_ value: Bool, _ description: String) throws {
        guard value else { throw Failure.check(description) }
    }

    @MainActor static func run() async throws {
        let service = CodexService()
        await service.refreshStatus()
        try require(service.isConnected, "Codex ChatGPT login unavailable")
        let material = PracticeMaterial(bookID: "synthetic-coach-smoke", bookTitle: "Учебный синтетический фрагмент",
            author: "Smoke fixture", unitTitle: "Счётчики событий", scope: .page,
            scopeNote: "Один синтетический абзац, не пользовательская книга.", sources: [
                PracticeSource(id: "smoke:p1", location: "Страница 1", title: "Счётчики событий", text: """
                Счётчик событий хранит количество появлений каждого значения. Для подсчёта нужно пройти по значениям один раз и увеличивать соответствующий счётчик. Когда значение встречается впервые, его счётчик начинается с нуля, после чего увеличивается на единицу. Порядок входных событий не меняет итоговые количества. Например, последовательность «чай, кофе, чай» даёт два появления чая и одно появление кофе. Удобно хранить счётчики в словаре, где ключ — значение события, а значение — целое число. Пустая последовательность должна давать пустой словарь.
                """, page: 0, chapter: nil)
            ])
        let coach = PracticeCoach(service: service)
        let exercise = try await coach.generate(material: material, language: .python)
        try require(!exercise.sourceIDs.isEmpty && exercise.sourceIDs.allSatisfy { $0 == "smoke:p1" }, "Unknown exercise source")
        try require(!exercise.checks.isEmpty && !exercise.title.isEmpty, "Exercise incomplete")
        print("PASS generated one Python exercise: \(exercise.title)")
        let hint = try await coach.hint(material: material, language: .python, exercise: exercise,
                                        code: exercise.starterCode, level: 1, question: "Как выбрать структуру данных?")
        try require(!hint.citations.isEmpty, "Hint missing locally verified citation")
        print("PASS hint: \(hint.citations.count) verified citation(s)")
        let review = try await coach.review(material: material, language: .python, exercise: exercise,
                                           code: "def counts(events):\n    return {}\n", output: "")
        try require(!review.citations.isEmpty, "Review missing locally verified citation")
        try require(review.verdict != "correct", "Incorrect count implementation approved")
        print("PASS review rejects empty implementation: \(review.verdict ?? "nil")")

        let forged = PracticeCitation(sourceID: "smoke:p1", quote: "Этой выдуманной цитаты никогда не было в синтетическом учебном материале.")
        try require(PracticeEvidence.validated([forged], in: material).isEmpty, "Invented citation accepted")
        let unknown = PracticeCitation(sourceID: "unknown", quote: String(material.sources[0].text.prefix(90)))
        try require(PracticeEvidence.validated([unknown], in: material).isEmpty, "Unknown source accepted")
        print("PASS invented quotation and unknown source rejected")
    }
}
