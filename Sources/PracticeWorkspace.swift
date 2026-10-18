import AppKit
import SwiftUI

@MainActor final class PracticeWorkspaceModel: ObservableObject {
    @Published var scope: PracticeScope = .chapter
    @Published var language: PracticeLanguage = .python
    @Published var notebook: PracticeNotebook?
    @Published var notebooks: [PracticeNotebook] = []
    @Published var phase: String?
    @Published var error: String?
    @Published var question = ""
    let store: ReaderStore
    let service: CodexService
    let runner = PracticeRunner()
    lazy var coach = PracticeCoach(service: service)
    private let file: URL
    private var operation: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var ownsAIRequest = false
    var reveal: ((PracticeSource, String) -> Void)?

    init(store: ReaderStore, service: CodexService) {
        self.store = store; self.service = service
        file = store.root.appendingPathComponent("practice.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([PracticeNotebook].self, from: data) { notebooks = saved }
    }
    var isBusy: Bool { phase != nil }
    var history: [PracticeNotebook] {
        guard let notebook else { return [] }
        return notebooks.filter { $0.material.key == notebook.material.key && $0.language == notebook.language }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func keepCurrent() {
        guard var current = notebook else { return }
        current.updatedAt = Date(); notebook = current
        if let i = notebooks.firstIndex(where: { $0.id == current.id }) { notebooks[i] = current } else { notebooks.append(current) }
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(nanoseconds: 350_000_000); guard !Task.isCancelled else { return }; persist() }
    }
    func persist() {
        if let data = try? JSONEncoder().encode(notebooks) {
            do { try data.write(to: file, options: .atomic) }
            catch { self.error = "Не удалось сохранить практику: \(error.localizedDescription)" }
        }
    }
    func setCode(_ code: String) { notebook?.code = String(code.prefix(100_000)); keepCurrent() }
    func selectNotebook(_ id: String) { guard !isBusy, let saved = notebooks.first(where: { $0.id == id }) else { return }; keepCurrent(); notebook = saved; error = nil }
    func loadMaterial() {
        guard !isBusy else { return }
        keepCurrent(); error = nil; phase = "Готовим фрагменты книги…"
        operation = Task {
            defer { phase = nil }
            do {
                let material = try await store.practiceMaterial(scope: scope)
                try Task.checkCancellation()
                notebook = notebooks.filter { $0.material.key == material.key && $0.language == language }.max(by: { $0.updatedAt < $1.updatedAt }) ?? PracticeNotebook(id: UUID().uuidString, material: material, language: language, code: language.starter)
                keepCurrent()
                await service.refreshStatus(); await runner.refresh()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func generate() {
        guard !isBusy, !service.isBusy, let current = notebook else { return }
        if current.exercise != nil {
            keepCurrent()
            notebook = PracticeNotebook(id: UUID().uuidString, material: current.material, language: current.language, code: current.language.starter)
        }
        guard let current = notebook else { return }
        phase = "ИИ готовит задание по прочитанному…"; error = nil; ownsAIRequest = true
        operation = Task {
            defer { phase = nil; ownsAIRequest = false }
            do {
                let exercise = try await coach.generate(material: current.material, language: current.language)
                try Task.checkCancellation()
                notebook?.exercise = exercise; notebook?.code = exercise.starterCode.isEmpty ? current.language.starter : exercise.starterCode
                notebook?.output = ""; notebook?.feedback = []; notebook?.hintLevel = 0; keepCurrent()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func run() {
        guard !isBusy, let current = notebook, current.language.isExecutable else { return }
        phase = "Запускаем в отдельной среде…"; error = nil
        operation = Task {
            defer { phase = nil }
            do {
                let result = try await runner.run(code: current.code, language: current.language)
                try Task.checkCancellation()
                notebook?.output = result.output + (result.timedOut ? "\n\nВыполнение остановлено по лимиту времени." : "\n\nКод завершения: \(result.exitCode)")
                keepCurrent()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func askHint() {
        guard !isBusy, !service.isBusy, let current = notebook, let exercise = current.exercise else { return }
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        question = ""; phase = "Ищем подсказку в книге…"; error = nil; ownsAIRequest = true
        operation = Task {
            defer { phase = nil; ownsAIRequest = false }
            do {
                let feedback = try await coach.hint(material: current.material, language: current.language, exercise: exercise, code: current.code, level: current.hintLevel + 1, question: prompt.isEmpty ? nil : prompt)
                try Task.checkCancellation()
                notebook?.feedback.append(feedback); notebook?.hintLevel += 1; keepCurrent()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func review() {
        guard !isBusy, !service.isBusy, let current = notebook, let exercise = current.exercise else { return }
        phase = current.language.isExecutable ? "Запускаем решение перед разбором…" : "ИИ разбирает решение…"; error = nil
        operation = Task {
            defer { phase = nil; ownsAIRequest = false }
            do {
                var output = "Ответ словами, без запуска кода."
                if current.language.isExecutable {
                    let result = try await runner.run(code: current.code, language: current.language)
                    output = result.output + "\nКод завершения: \(result.exitCode)." + (result.timedOut ? " Лимит времени превышен." : "")
                    notebook?.output = output; keepCurrent()
                }
                try Task.checkCancellation()
                phase = "ИИ разбирает решение и сверяет с книгой…"; ownsAIRequest = true
                let feedback = try await coach.review(material: current.material, language: current.language, exercise: exercise, code: current.code, output: output)
                try Task.checkCancellation()
                notebook?.feedback.append(feedback); keepCurrent()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func showCitation(_ citation: PracticeCitation) {
        guard let current = notebook, var source = current.material.sources.first(where: { $0.id == citation.sourceID }) else { return }
        source.text = citation.quote; reveal?(source, current.material.bookID)
    }
    func showSource(_ id: String) {
        guard let current = notebook, let source = current.material.sources.first(where: { $0.id == id }) else { return }
        reveal?(source, current.material.bookID)
    }
    func cancel() { operation?.cancel(); if ownsAIRequest { service.cancel() }; runner.cancel(); ownsAIRequest = false; keepCurrent(); persist() }
}

@MainActor final class PracticeWindowController: NSWindowController, NSWindowDelegate {
    let model: PracticeWorkspaceModel
    init(store: ReaderStore, service: CodexService) {
        model = PracticeWorkspaceModel(store: store, service: service)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Практика · Лист"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 860, height: 640); window.isReleasedWhenClosed = false; window.delegate = self
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: PracticeWorkspaceView(model: model, store: store, ai: service, runner: model.runner).ignoresSafeArea())
    }
    required init?(coder: NSCoder) { nil }
    func present(relativeTo parent: NSWindow?) {
        guard let window else { return }
        let available = parent?.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let width = min(1080, available.width - 40), height = min(800, available.height - 40)
        window.setFrame(NSRect(x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height), display: true)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        model.loadMaterial()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.cancel(); sender.orderOut(nil); return false }
    func windowWillClose(_ notification: Notification) { model.cancel() }
}
