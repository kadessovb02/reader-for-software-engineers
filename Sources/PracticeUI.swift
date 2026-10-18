import SwiftUI
import AppKit

struct PracticeWorkspaceView: View {
    @ObservedObject var model: PracticeWorkspaceModel
    @ObservedObject var store: ReaderStore
    @ObservedObject var ai: CodexService
    @ObservedObject var runner: PracticeRunner
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notebook = model.notebook {
                PracticeResizableSplit(axis: .horizontal, identifier: "practice.columns", fraction: 0.28, minimumFirst: 220, minimumSecond: 470) {
                    taskPane(notebook).frame(maxWidth: .infinity, maxHeight: .infinity)
                } second: {
                    PracticeResizableSplit(axis: .vertical, identifier: "practice.workspace", fraction: 0.78, minimumFirst: 260, minimumSecond: 110) {
                        editorPane(notebook).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } second: {
                        coachingPane(notebook).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                Spacer()
                if let error = model.error { Text(error).font(.system(size: 13)).foregroundStyle(.secondary).padding(35) }
                else { ProgressView("Готовим материал для практики…").font(.system(size: 12)) }
                Spacer()
            }
            statusBar
        }
        .background(store.theme.background).foregroundStyle(store.theme.ink).tint(leafAccent).preferredColorScheme(store.theme == .dark ? .dark : .light)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text("Практика").font(.system(size: 23, weight: .medium, design: .serif))
                Text(model.notebook?.material.bookTitle ?? store.book?.title ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !ai.isConnected { Button("Войти в ChatGPT") { Task { await ai.login() } }.font(.system(size: 11)).disabled(model.isBusy || ai.isBusy) }
                if model.isBusy { Button("Остановить") { model.cancel() }.font(.system(size: 11)).buttonStyle(.bordered) }
            }
            HStack(spacing: 16) {
                Picker("Материал", selection: $model.scope) { ForEach(PracticeScope.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(width: 240).disabled(model.isBusy)
                Picker("Формат", selection: $model.language) { ForEach(PracticeLanguage.allCases) { Text($0.title).tag($0) } }.frame(width: 230).disabled(model.isBusy)
                Spacer()
                if model.history.count > 1 {
                    Menu {
                        ForEach(model.history) { note in Button(note.exercise?.title ?? "Черновик") { model.selectNotebook(note.id) } }
                    } label: { Label("Задания · \(model.history.count)", systemImage: "clock.arrow.circlepath") }.menuStyle(.borderlessButton).fixedSize().disabled(model.isBusy)
                }
            }.font(.system(size: 12))
        }.padding(.horizontal, 24).padding(.bottom, 17).padding(.top, 38)
        .onChange(of: model.scope) { model.loadMaterial() }
        .onChange(of: model.language) { model.loadMaterial() }
    }
    private func taskPane(_ notebook: PracticeNotebook) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ПО ПРОЧИТАННОМУ").font(.system(size: 9, weight: .medium)).tracking(1.3).foregroundStyle(.secondary)
                    Text(notebook.material.unitTitle).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    if !notebook.material.scopeNote.isEmpty { Text(notebook.material.scopeNote).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Divider()
                if let exercise = notebook.exercise {
                    Text(exercise.title).font(.system(size: 21, weight: .regular, design: .serif)).fixedSize(horizontal: false, vertical: true)
                    Text(exercise.goal).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                    Text(.init(exercise.instructions)).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    if !exercise.checks.isEmpty {
                        Text("Критерии решения").font(.system(size: 12, weight: .medium)).padding(.top, 4)
                        ForEach(Array(exercise.checks.enumerated()), id: \.offset) { index, check in
                            HStack(alignment: .top, spacing: 7) { Text("\(index + 1).").foregroundStyle(.secondary); Text(check).fixedSize(horizontal: false, vertical: true) }.font(.system(size: 11)).lineSpacing(3)
                        }
                    }
                    Divider()
                    Text("Опора в книге").font(.system(size: 11, weight: .medium))
                    ForEach(exercise.sourceIDs, id: \.self) { id in
                        if let source = notebook.material.sources.first(where: { $0.id == id }) {
                            Button { model.showSource(id) } label: { Label(source.location, systemImage: "book").font(.system(size: 11)).multilineTextAlignment(.leading) }.buttonStyle(.plain).foregroundStyle(leafAccent)
                        }
                    }
                    Button("Другое задание") { model.generate() }.buttonStyle(.bordered).controlSize(.small).disabled(model.isBusy || ai.isBusy || !ai.isConnected)
                    Text("Текущее решение останется в списке заданий.").font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "pencil.and.outline").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(leafAccent).padding(.top, 12)
                    Text("Проверим на практике").font(.system(size: 23, weight: .regular, design: .serif))
                    Text("ИИ предложит небольшое задание по выбранному месту. Сначала попробуйте сами, затем попросите подсказку или разбор.").font(.system(size: 13)).lineSpacing(4).foregroundStyle(.secondary)
                    Button("Создать задание") { model.generate() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isBusy || ai.isBusy || !ai.isConnected)
                    if !ai.isConnected {
                        Button("Подключить ChatGPT") { Task { await ai.login() } }.font(.system(size: 11)).disabled(ai.isBusy)
                        Text(ai.status).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }.padding(23).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func editorPane(_ notebook: PracticeNotebook) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(notebook.language.isExecutable ? "Ваш код" : "Ваше решение").font(.system(size: 12, weight: .medium))
                Spacer()
                if notebook.language.isExecutable {
                    Button { model.run() } label: { Label("Запустить", systemImage: "play.fill") }.buttonStyle(.bordered).controlSize(.small).disabled(model.isBusy || runner.isRunning || notebook.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button("Проверить решение") { model.review() }.buttonStyle(.borderedProminent).controlSize(.small).disabled(model.isBusy || ai.isBusy || !ai.isConnected || notebook.exercise == nil)
            }.padding(.horizontal, 18).padding(.vertical, 12)
            Divider().opacity(0.5)
            if notebook.language.isExecutable {
                PracticeResizableSplit(axis: .vertical, identifier: "practice.code-output", fraction: 0.82, minimumFirst: 110, minimumSecond: 55) {
                    codeEditor(notebook)
                } second: {
                    consolePane(notebook)
                }
            } else { codeEditor(notebook) }
        }
    }
    private func codeEditor(_ notebook: PracticeNotebook) -> some View {
        PracticeCodeEditor(text: Binding(get: { model.notebook?.code ?? "" }, set: { model.setCode($0) }), editable: !model.isBusy, background: store.theme.nsBackground, foreground: store.theme == .dark ? NSColor(calibratedWhite: 0.85, alpha: 1) : .textColor).id(notebook.id).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func consolePane(_ notebook: PracticeNotebook) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("РЕЗУЛЬТАТ ЗАПУСКА").font(.system(size: 8, weight: .medium)).tracking(1); Spacer(); Text("Изолированная среда · без сети").font(.system(size: 9)) }.foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(notebook.output.isEmpty ? "Вывод программы появится здесь." : notebook.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(.quaternary.opacity(0.12))
    }
    private func coachingPane(_ notebook: PracticeNotebook) -> some View {
        VStack(spacing: 0) {
            HStack { Text("Подсказки и разбор").font(.system(size: 12, weight: .medium)); Spacer(); Button { model.askHint() } label: { Label(notebook.hintLevel == 0 ? "Подсказка" : "Ещё подсказка", systemImage: "lightbulb") }.buttonStyle(.bordered).controlSize(.small).disabled(model.isBusy || ai.isBusy || !ai.isConnected || notebook.exercise == nil) }.padding(.horizontal, 18).padding(.vertical, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if notebook.feedback.isEmpty { Text("Подсказки идут постепенно: идея, следующий шаг, затем набросок. Каждый разбор содержит проверенный фрагмент книги.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).padding(.vertical, 6) }
                        ForEach(notebook.feedback) { feedback in feedbackCard(feedback, notebook: notebook) }
                        Color.clear.frame(height: 1).id("end")
                    }.padding(.horizontal, 19).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: notebook.feedback.count) { proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack(alignment: .bottom, spacing: 9) {
                TextField("Что именно непонятно?", text: $model.question, axis: .vertical).font(.system(size: 12)).lineLimit(1...3).textFieldStyle(.plain).onSubmit { model.askHint() }.disabled(model.isBusy)
                Button { model.askHint() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }.buttonStyle(.plain).foregroundStyle(leafAccent).disabled(model.isBusy || ai.isBusy || !ai.isConnected || notebook.exercise == nil)
            }.padding(12).background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 16).padding(.bottom, 13)
        }
    }
    private func feedbackCard(_ feedback: PracticeFeedback, notebook: PracticeNotebook) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            if feedback.verdict != nil { Text("РАЗБОР ИИ").font(.system(size: 8, weight: .medium)).tracking(1.1).foregroundStyle(.secondary) }
            Text(.init(feedback.message)).font(.system(size: 12)).lineSpacing(4).textSelection(.enabled)
            ForEach(feedback.citations) { citation in
                VStack(alignment: .leading, spacing: 9) {
                    Text(citation.quote).font(.system(size: 12, design: .serif)).lineSpacing(3).textSelection(.enabled)
                    Button { model.showCitation(citation) } label: {
                        HStack { Image(systemName: "book"); Text(notebook.material.sources.first(where: { $0.id == citation.sourceID })?.location ?? "Фрагмент книги"); Spacer(); Text("Открыть в книге"); Image(systemName: "arrow.up.right") }.font(.system(size: 10))
                    }.buttonStyle(.plain).foregroundStyle(leafAccent)
                }.padding(12).background(leafAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            }
            Divider().opacity(0.5)
        }
    }
    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
            HStack(spacing: 8) {
                if model.isBusy { ProgressView().controlSize(.mini) }
                Text(model.phase ?? "Черновики сохраняются на этом Mac").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if !runner.isReady && model.language.isExecutable { Button("Проверить среду") { Task { await runner.refresh() } }.buttonStyle(.plain).font(.system(size: 10)).disabled(model.isBusy) }
                if runner.isRunning || (model.isBusy && model.phase?.contains("Запускаем") == true) { Text(runner.status).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
            }
        }.padding(.horizontal, 20).padding(.vertical, 10).background(.regularMaterial)
    }
}

struct PracticeCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool
    var background: NSColor
    var foreground: NSColor
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let editor = NSTextView(frame: .zero)
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.isContinuousSpellCheckingEnabled = false; editor.isGrammarCheckingEnabled = false; editor.allowsUndo = true
        editor.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular); editor.textContainerInset = NSSize(width: 15, height: 14)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = true; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = false; editor.textContainer?.containerSize = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text; editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Редактор решения")
        scroll.documentView = editor; updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text { let selection = editor.selectedRange(); editor.string = text; editor.undoManager?.removeAllActions(); editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0)) }
        editor.isEditable = editable; editor.backgroundColor = background; editor.textColor = foreground; editor.insertionPointColor = foreground; scroll.backgroundColor = background
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PracticeCodeEditor
        init(parent: PracticeCodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let editor = notification.object as? NSTextView { parent.text = editor.string } }
    }
}
