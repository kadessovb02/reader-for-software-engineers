import SwiftUI

@MainActor final class ReaderChat: ObservableObject {
    @Published var conversations: [String: [ChatTurn]] = [:]
    @Published var draft = ""
    @Published var error: String?
    @Published var pendingBook: String?
    @Published var sentContext = ""
    @Published var searchStatus = ""
    let store: ReaderStore
    let service: CodexService
    private var request: Task<Void, Never>?
    private var requestID: UUID?
    private let file: URL
    init(store: ReaderStore, service: CodexService) {
        self.store = store; self.service = service; file = store.root.appendingPathComponent("conversations.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: [ChatTurn]].self, from: data) { conversations = saved }
    }
    var messages: [ChatTurn] { conversations[store.selectedID] ?? [] }
    func persist() { if let data = try? JSONEncoder().encode(conversations) { try? data.write(to: file, options: .atomic) } }
    func clear() { guard !service.isBusy, pendingBook == nil else { return }; conversations[store.selectedID] = []; error = nil; sentContext = ""; persist() }
    func send(_ suggestion: String? = nil) {
        let question = (suggestion ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !service.isBusy, pendingBook == nil else { return }
        let bookID = store.selectedID
        let token = UUID(); requestID = token
        draft = ""; error = nil; pendingBook = bookID
        searchStatus = "Читаю текущую страницу…"
        request = Task {
            defer {
                if requestID == token { pendingBook = nil; searchStatus = ""; request = nil; requestID = nil }
            }
            do {
                guard !Task.isCancelled, store.selectedID == bookID else { return }
                let search = try await store.makeChatSearchSession()
                try Task.checkCancellation()
                guard store.selectedID == bookID, requestID == token else { return }
                let context = search.context
                sentContext = context.location
                let history = conversations[bookID] ?? []
                conversations[bookID, default: []].append(ChatTurn(role: "user", text: question)); persist()
                let answer = try await service.ask(context: context, history: history, question: question, search: search,
                    progress: { [weak self] message in
                        guard self?.requestID == token else { return }
                        self?.searchStatus = message
                    })
                if !Task.isCancelled, requestID == token { conversations[bookID, default: []].append(ChatTurn(role: "assistant", text: answer)); persist() }
            } catch is CancellationError {
                // Cancellation is an explicit action, not a failed answer.
            } catch {
                if requestID == token { self.error = error.localizedDescription; draft = question }
            }
        }
    }
    func cancel() { request?.cancel(); service.cancel() }
}

struct ChatPanelView: View {
    @ObservedObject var chat: ReaderChat
    @ObservedObject var store: ReaderStore
    @ObservedObject var ai: CodexService
    @FocusState var inputFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle").foregroundStyle(leafAccent)
                VStack(alignment: .leading, spacing: 3) { Text("Помощник по книге").font(.system(size: 13, weight: .medium)); Text(store.book?.title ?? "Лист").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(); Button { chat.clear() } label: { Image(systemName: "square.and.pencil").font(.system(size: 13)) }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(ai.isBusy || chat.pendingBook != nil).help("Начать новый разговор")
            }.padding(.horizontal, 18).padding(.top, 36).padding(.bottom, 16)
            Divider().opacity(0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if chat.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Разберёмся\nв этом месте.").font(.system(size: 27, weight: .regular, design: .serif)).lineSpacing(3)
                                Text("Начнём с текущей страницы. Если нужно, помощник найдёт текст в главе и в книге до вашего места чтения.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                                if !ai.isConnected {
                                    Button("Войти через ChatGPT") { Task { await ai.login() } }.buttonStyle(.borderedProminent).controlSize(.small).disabled(ai.isBusy)
                                    Text(ai.status).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                                } else {
                                    ForEach(["Объясни этот фрагмент проще", "Что здесь важно запомнить?", "Приведи практический пример"], id: \.self) { prompt in
                                        Button { chat.send(prompt) } label: { HStack { Text(prompt).font(.system(size: 11)); Spacer(); Image(systemName: "arrow.up.left").font(.system(size: 9)) }.padding(11).background(leafAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain).disabled(ai.isBusy || chat.pendingBook != nil)
                                    }
                                }
                            }.padding(.top, 17)
                        }
                        ForEach(chat.messages) { message in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(message.role == "user" ? "ВЫ" : "ПОМОЩНИК").font(.system(size: 8, weight: .medium)).tracking(1).foregroundStyle(.secondary)
                                Text(.init(message.text)).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(message.role == "user" ? 12 : 0).background(message.role == "user" ? leafAccent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10)).id(message.id)
                        }
                        if chat.pendingBook == store.selectedID {
                            HStack(spacing: 9) { ProgressView().controlSize(.mini); Text(chat.searchStatus).font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Button("Отменить") { chat.cancel() }.font(.system(size: 10)).buttonStyle(.plain) }
                        }
                        if let error = chat.error { Text(error).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7)) }
                        Color.clear.frame(height: 1).id("end")
                    }.padding(19)
                }
                .onChange(of: chat.messages.count) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: chat.pendingBook) { proxy.scrollTo("end", anchor: .bottom) }
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 5) { Image(systemName: store.selection.isEmpty ? "doc.text" : "text.quote"); Text(store.selection.isEmpty ? store.chapterTitle : "Выделенный фрагмент · \(store.selection.count) знаков").lineLimit(1); Spacer() }.font(.system(size: 9)).foregroundStyle(.secondary)
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Спросить об этом месте…", text: $chat.draft, axis: .vertical).font(.system(size: 12)).lineLimit(1...5).textFieldStyle(.plain).focused($inputFocused).onSubmit { chat.send() }
                    Button { chat.send() } label: { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).frame(width: 27, height: 27).background(leafAccent, in: Circle()) }.buttonStyle(.plain).disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ai.isBusy || chat.pendingBook != nil).help("Отправить вопрос")
                }.padding(11).background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(.quaternary))
                Text("Контекст отправляется только вместе с вопросом").font(.system(size: 8)).foregroundStyle(.tertiary)
            }.padding(15).background(.regularMaterial)
        }
        .background(store.theme.background).foregroundStyle(store.theme.ink).tint(leafAccent).preferredColorScheme(store.theme == .dark ? .dark : .light)
        .task { await ai.refreshStatus(); inputFocused = true }
    }
}
