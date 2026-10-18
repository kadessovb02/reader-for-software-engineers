import Foundation

enum PracticeLanguage: String, Codable, CaseIterable, Identifiable {
    case python, javascript, sql, reasoning
    var id: String { rawValue }
    var title: String { switch self { case .python: return "Python"; case .javascript: return "JavaScript"; case .sql: return "SQL · SQLite"; case .reasoning: return "Ответ словами" } }
    var isExecutable: Bool { self != .reasoning }
    var starter: String { switch self { case .python: return "# Напишите решение здесь\n"; case .javascript: return "// Напишите решение здесь\n"; case .sql: return "-- Напишите SQL здесь\n"; case .reasoning: return "Моё решение:\n" } }
}

enum PracticeScope: String, Codable, CaseIterable, Identifiable {
    case page, chapter
    var id: String { rawValue }
    var title: String { self == .page ? "Текущее место" : "Глава" }
}

struct PracticeSource: Codable, Identifiable {
    var id: String
    var location: String
    var title: String
    var text: String
    var page: Int?
    var chapter: Int?
}

struct PracticeMaterial: Codable {
    var bookID: String
    var bookTitle: String
    var author: String
    var unitTitle: String
    var scope: PracticeScope
    var scopeNote: String
    var sources: [PracticeSource]
    var key: String { bookID + ":" + scope.rawValue + ":" + (sources.first?.id ?? "empty") }
}

struct PracticeExercise: Codable, Identifiable {
    var id: String = UUID().uuidString
    var title: String
    var goal: String
    var instructions: String
    var starterCode: String
    var checks: [String]
    var sourceIDs: [String]
}

struct PracticeCitation: Codable, Identifiable {
    var sourceID: String
    var quote: String
    var id: String { sourceID + ":" + quote }
}

struct PracticeFeedback: Codable, Identifiable {
    var id: String = UUID().uuidString
    var message: String
    var citations: [PracticeCitation]
    var verdict: String?
}

struct PracticeNotebook: Codable, Identifiable {
    var id: String
    var material: PracticeMaterial
    var language: PracticeLanguage
    var exercise: PracticeExercise?
    var code: String
    var output: String = ""
    var feedback: [PracticeFeedback] = []
    var hintLevel: Int = 0
    var updatedAt: Date = Date()
}

struct PracticeRunResult {
    var output: String
    var exitCode: Int32
    var timedOut: Bool
}
